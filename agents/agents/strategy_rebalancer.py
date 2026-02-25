"""
agents/agents/strategy_rebalancer.py
──────────────────────────────────────
Strategy Rebalancer Agent — yield & leverage health optimiser.

Responsibilities
────────────────
  1. Every `interval` seconds, read the global BTC health factor from the router.
  2. Compute the system-recommended leverage cap from the health-to-leverage
     mapping defined in docs/04-autonomous-agents.md.
  3. Log a warning when the on-chain max_leverage deviates significantly from
     the recommended value (informational — leverage changes are user-initiated).
  4. Trigger on-chain yield accrual (`vault.trigger_yield_accrual()`) on a
     cadence aligned with the yield strategy APY accumulation rate.
  5. Refresh the Pragma oracle price when it becomes stale.
  6. Emit structured metrics for the operations dashboard.

Design rationale
─────────────────
The vault's per-user leverage is set by each user (or by the User Guardian for
liquidatable positions). This agent does **not** force-adjust user leverage.
Instead it:
  • Tracks whether the system health is diverging from its healthy band.
  • Ensures yield accrual fires regularly so share prices stay up-to-date.
  • Provides a clear audit trail so operators can react to system-level drift.

Required on-chain roles
───────────────────────
  ROLE_KEEPER on vault  → trigger_yield_accrual()
  ROLE_KEEPER on router → refresh_btc_price()
"""

from __future__ import annotations

import time
from typing import Optional

from agents.base import BaseAgent
from core.starknet_client import StarknetClient, RouterSnapshot
from config import AgentSettings
from core.logger import get_logger

log = get_logger(__name__)

# How often to trigger yield accrual (seconds).
# Should be ≤ the vault's minimum accrual period.
YIELD_ACCRUAL_INTERVAL = 3600        # 1 hour

# Minimum seconds between consecutive price-refresh calls.
PRICE_REFRESH_COOLDOWN = 180         # 3 minutes

# Health thresholds (×100 scale, matching router storage).
# These mirror the decision matrix in docs/04-autonomous-agents.md.
HEALTH_DELEVERAGE_THRESHOLD = 110    # 1.10 — recommend no leverage
HEALTH_REDUCE_THRESHOLD = 120        # 1.20 — recommend reducing leverage
HEALTH_MODERATE_THRESHOLD = 130      # 1.30 — moderate leverage OK
HEALTH_AGGRESSIVE_THRESHOLD = 150    # 1.50 — full leverage permitted


def recommended_leverage(health: int) -> float:
    """
    Map the BTC health factor (×100) to the recommended leverage multiple.

    Implements the piecewise function from docs/07-mathematical-models.md:

      H < 1.10  →  1.0x   (no leverage)
      H < 1.30  →  1.0 + 0.5 × (H – 1.10) / 0.20
      H < 1.50  →  1.1 + 0.4 × (H – 1.30) / 0.20
      H ≥ 1.50  →  min(1.5 + 0.5 × (H – 1.50), 2.0)
    """
    h = health / 100.0
    if h < 1.10:
        return 1.0
    elif h < 1.30:
        return 1.0 + 0.5 * (h - 1.10) / 0.20
    elif h < 1.50:
        return 1.1 + 0.4 * (h - 1.30) / 0.20
    else:
        return min(1.5 + 0.5 * (h - 1.50), 2.0)


def health_regime(health: int) -> str:
    """Human-readable health regime label."""
    if health < HEALTH_DELEVERAGE_THRESHOLD:
        return "CRITICAL"
    if health < HEALTH_REDUCE_THRESHOLD:
        return "LOW"
    if health < HEALTH_MODERATE_THRESHOLD:
        return "MODERATE"
    if health < HEALTH_AGGRESSIVE_THRESHOLD:
        return "GOOD"
    return "EXCELLENT"


class StrategyRebalancerAgent(BaseAgent):
    """
    Yield accrual trigger and health monitor.

    Parameters
    ----------
    settings:
        Shared configuration.
    client:
        Pre-connected StarknetClient signed with ROLE_KEEPER account.
    """

    def __init__(
        self,
        settings: AgentSettings,
        client: StarknetClient,
    ) -> None:
        super().__init__(
            name="StrategyRebalancer",
            settings=settings,
            interval=settings.rebalancer_interval,
        )
        self._client = client

        # Tracking state
        self._last_yield_accrual: float = 0.0
        self._last_price_refresh: float = 0.0
        self._yield_accruals: int = 0
        self._price_refreshes: int = 0

        # History for trend analysis
        self._health_history: list[int] = []   # last N health readings
        self._last_snapshot: Optional[RouterSnapshot] = None

    # ── Lifecycle ──────────────────────────────────────────────────────────────

    async def setup(self) -> None:
        await super().setup()
        # Read initial state to populate history
        try:
            snap = await self._client.get_router_snapshot()
            self._record_health(snap.btc_health)
            self._last_snapshot = snap
            self._log.info(
                "strategy_rebalancer.initial_state",
                btc_health=snap.btc_health,
                max_leverage=snap.max_leverage,
                regime=health_regime(snap.btc_health),
            )
        except Exception as exc:
            self._log.warning("strategy_rebalancer.initial_state_failed", error=str(exc))

    # ── Main tick ──────────────────────────────────────────────────────────────

    async def tick(self) -> None:
        """
        One rebalancing cycle:
          1. Read router + vault state.
          2. Log health regime and drift warnings.
          3. Trigger yield accrual if due.
          4. Refresh oracle price if stale.
        """
        # ── Step 1: read state ───────────────────────────────────────────────
        try:
            snapshot = await self._client.get_router_snapshot()
        except Exception as exc:
            self._log.error("strategy_rebalancer.router_fetch_failed", error=str(exc))
            return

        self._record_health(snapshot.btc_health)
        self._last_snapshot = snapshot
        rec_lev = recommended_leverage(snapshot.btc_health)
        on_chain_max_lev = snapshot.max_leverage / 100.0
        regime = health_regime(snapshot.btc_health)

        # ── Step 2: log health assessment ───────────────────────────────────
        self._log.info(
            "strategy_rebalancer.tick",
            btc_health=snapshot.btc_health,
            regime=regime,
            recommended_leverage=round(rec_lev, 2),
            on_chain_max_leverage=round(on_chain_max_lev, 2),
            is_safe_mode=snapshot.is_safe_mode,
            is_price_fresh=snapshot.is_price_fresh,
            health_trend=self._health_trend(),
        )

        # ── Step 3: warn on leverage drift ──────────────────────────────────
        lev_delta = abs(rec_lev - on_chain_max_lev)
        if lev_delta > self._cfg.leverage_rebalance_threshold and not snapshot.is_safe_mode:
            self._log.warning(
                "strategy_rebalancer.leverage_drift",
                recommended=round(rec_lev, 2),
                on_chain=round(on_chain_max_lev, 2),
                delta=round(lev_delta, 3),
                action=(
                    "The router's dynamic leverage cap will self-adjust "
                    "on the next is_operation_allowed() call. "
                    "No manual intervention required."
                ),
            )

        # ── Step 4: critical health warning ─────────────────────────────────
        if regime == "CRITICAL" and not snapshot.is_safe_mode:
            self._log.error(
                "strategy_rebalancer.critical_health",
                btc_health=snapshot.btc_health,
                recommendation=(
                    "Health is below safe-mode threshold. "
                    "RiskSentinel should trigger safe mode. "
                    "Consider manual intervention if sentinel is offline."
                ),
            )

        # ── Step 5: trigger yield accrual if due ────────────────────────────
        await self._maybe_trigger_yield_accrual(snapshot)

        # ── Step 6: refresh stale oracle ────────────────────────────────────
        await self._maybe_refresh_price(snapshot)

    # ── Sub-actions ────────────────────────────────────────────────────────────

    async def _maybe_trigger_yield_accrual(self, snapshot: RouterSnapshot) -> None:
        """Trigger yield accrual if enough time has passed since the last call."""
        now = time.monotonic()
        if now - self._last_yield_accrual < YIELD_ACCRUAL_INTERVAL:
            return

        if snapshot.is_safe_mode:
            self._log.debug("strategy_rebalancer.yield_skip_safe_mode")
            return

        try:
            tx_hash = await self._client.trigger_yield_accrual()
            self._last_yield_accrual = now
            self._yield_accruals += 1
            self._log.info(
                "strategy_rebalancer.yield_accrual_triggered",
                tx_hash=tx_hash,
                total_accruals=self._yield_accruals,
            )
        except Exception as exc:
            self._log.error("strategy_rebalancer.yield_accrual_failed", error=str(exc))

    async def _maybe_refresh_price(self, snapshot: RouterSnapshot) -> None:
        """Refresh the on-chain Pragma price if stale (and keeper not already on it)."""
        if snapshot.is_price_fresh:
            return

        now = time.monotonic()
        if now - self._last_price_refresh < PRICE_REFRESH_COOLDOWN:
            return

        try:
            tx_hash = await self._client.refresh_btc_price()
            self._last_price_refresh = now
            self._price_refreshes += 1
            self._log.info(
                "strategy_rebalancer.price_refreshed",
                tx_hash=tx_hash,
                total_refreshes=self._price_refreshes,
            )
        except Exception as exc:
            self._log.warning("strategy_rebalancer.price_refresh_failed", error=str(exc))

    # ── Internal helpers ───────────────────────────────────────────────────────

    def _record_health(self, health: int) -> None:
        self._health_history.append(health)
        # Keep only the last 12 readings (1 h at 5-min interval)
        if len(self._health_history) > 12:
            self._health_history.pop(0)

    def _health_trend(self) -> str:
        """Detect whether health is improving, deteriorating, or stable."""
        if len(self._health_history) < 3:
            return "unknown"
        recent = self._health_history[-3:]
        if recent[-1] > recent[0] + 2:
            return "improving"
        if recent[-1] < recent[0] - 2:
            return "deteriorating"
        return "stable"

    # ── Diagnostics ────────────────────────────────────────────────────────────

    def stats(self) -> dict:
        base = super().stats()
        base.update(
            {
                "yield_accruals": self._yield_accruals,
                "price_refreshes": self._price_refreshes,
                "health_trend": self._health_trend(),
                "last_health": (
                    self._last_snapshot.btc_health if self._last_snapshot else None
                ),
                "regime": (
                    health_regime(self._last_snapshot.btc_health)
                    if self._last_snapshot
                    else None
                ),
            }
        )
        return base
