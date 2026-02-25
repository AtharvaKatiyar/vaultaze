"""
agents/agents/risk_sentinel.py
────────────────────────────────
Risk Sentinel Agent — system-wide BTC safety monitoring.

Responsibilities
────────────────
  1. Fetch BTC/USD price from three exchanges every `interval` seconds.
  2. Detect a price drop > MAX_PRICE_DROP_PCT in the last hour.
  3. Detect annualised 24-h volatility > MAX_VOLATILITY_24H.
  4. Detect a stale Pragma oracle price and trigger a refresh.
  5. When either risk condition is met AND the router is not already in
     safe mode, call `router.enter_safe_mode()`.

Required on-chain roles
───────────────────────
  ROLE_GUARDIAN  → enter_safe_mode()
  ROLE_KEEPER    → refresh_btc_price()

Security note
─────────────
This agent holds no special privilege beyond what those roles grant.
The router contract validates all conditions independently before executing.
A compromised or malfunctioning sentinel can only propose — the router decides.
"""

from __future__ import annotations

import time
from typing import Optional

from agents.base import BaseAgent
from core.price_feed import PriceFeed
from core.starknet_client import StarknetClient, RouterSnapshot
from config import AgentSettings
from core.logger import get_logger

log = get_logger(__name__)

# Minimum seconds between consecutive safe-mode trigger attempts.
# The router enforces its own cooldown; this client-side guard reduces spam.
SAFE_MODE_CLIENT_COOLDOWN = 300   # 5 minutes

# Minimum seconds between price-refresh attempts.
PRICE_REFRESH_COOLDOWN = 120      # 2 minutes


class RiskSentinelAgent(BaseAgent):
    """
    Proactive system-wide safety monitor.

    Parameters
    ----------
    settings:
        Shared configuration.
    client:
        Pre-connected StarknetClient signed with ROLE_GUARDIAN + ROLE_KEEPER account.
    feed:
        Shared PriceFeed instance.
    """

    def __init__(
        self,
        settings: AgentSettings,
        client: StarknetClient,
        feed: PriceFeed,
    ) -> None:
        super().__init__(
            name="RiskSentinel",
            settings=settings,
            interval=settings.risk_sentinel_interval,
        )
        self._client = client
        self._feed = feed

        # Tracking state
        self._last_safe_mode_trigger: float = 0.0
        self._last_price_refresh: float = 0.0
        self._safe_mode_triggers: int = 0
        self._price_refreshes: int = 0

        # Snapshot of the most recent router state
        self._last_router_snapshot: Optional[RouterSnapshot] = None

    # ── Lifecycle ──────────────────────────────────────────────────────────────

    async def setup(self) -> None:
        await super().setup()
        await self._feed.start_session()
        # Warm up the price history with an initial fetch
        try:
            price = await self._feed.get_price()
            self._log.info("risk_sentinel.initial_price", price_usd=round(price, 2))
        except Exception as exc:
            self._log.warning("risk_sentinel.initial_price_failed", error=str(exc))

    async def teardown(self) -> None:
        await self._feed.close_session()
        await super().teardown()

    # ── Main tick ──────────────────────────────────────────────────────────────

    async def tick(self) -> None:
        """
        One monitoring cycle:
          1. Fetch current BTC price and update history.
          2. Read router state.
          3. Evaluate risk conditions.
          4. Act if necessary.
        """
        # ── Step 1: fetch price ──────────────────────────────────────────────
        try:
            current_price = await self._feed.get_price()
        except RuntimeError as exc:
            self._log.error("risk_sentinel.price_fetch_failed", error=str(exc))
            return  # Cannot evaluate risk without a price; skip this tick

        price_change_1h = await self._feed.get_price_change_1h()
        volatility_24h = await self._feed.get_volatility_24h()

        # ── Step 2: read router state ────────────────────────────────────────
        try:
            snapshot = await self._client.get_router_snapshot()
            self._last_router_snapshot = snapshot
        except Exception as exc:
            self._log.error("risk_sentinel.router_fetch_failed", error=str(exc))
            return

        self._log.info(
            "risk_sentinel.tick",
            price_usd=round(current_price, 2),
            price_change_1h_pct=round(price_change_1h, 2),
            volatility_24h=round(volatility_24h, 4),
            btc_health=snapshot.btc_health,
            is_safe_mode=snapshot.is_safe_mode,
            is_price_fresh=snapshot.is_price_fresh,
        )

        # ── Step 3 & 4: act on stale oracle ─────────────────────────────────
        await self._maybe_refresh_price(snapshot, current_price)

        # ── Step 5: act on risk conditions ──────────────────────────────────
        await self._maybe_enter_safe_mode(
            snapshot=snapshot,
            price_change_1h=price_change_1h,
            volatility_24h=volatility_24h,
        )

    # ── Decision logic ─────────────────────────────────────────────────────────

    async def _maybe_refresh_price(self, snapshot: RouterSnapshot, current_price: float) -> None:
        """Refresh the on-chain Pragma price if it is stale.

        On testnet, if an oracle keeper is configured, push the current off-chain
        price to the MockPragmaOracle first so the router does not reject the
        refresh with 'Pragma data too stale'.
        """
        if snapshot.is_price_fresh:
            return

        now = time.monotonic()
        if now - self._last_price_refresh < PRICE_REFRESH_COOLDOWN:
            return

        self._log.warning("risk_sentinel.price_stale_detected")

        # On testnet: push fresh price to the mock oracle before the router reads it.
        if self._client.has_oracle_keeper:
            try:
                oracle_tx = await self._client.set_oracle_mock_price(current_price)
                self._log.info(
                    "risk_sentinel.oracle_mock_price_set",
                    price_usd=round(current_price, 2),
                    tx_hash=oracle_tx,
                )
            except Exception as exc:
                self._log.warning("risk_sentinel.oracle_mock_price_failed", error=str(exc))
                return  # Don't call refresh_btc_price if oracle update failed

        try:
            tx_hash = await self._client.refresh_btc_price()
            self._last_price_refresh = now
            self._price_refreshes += 1
            self._log.info(
                "risk_sentinel.price_refreshed",
                tx_hash=tx_hash,
                total_refreshes=self._price_refreshes,
            )
        except Exception as exc:
            self._log.error("risk_sentinel.price_refresh_failed", error=str(exc))

    async def _maybe_enter_safe_mode(
        self,
        snapshot: RouterSnapshot,
        price_change_1h: float,
        volatility_24h: float,
    ) -> None:
        """Evaluate risk conditions and trigger safe mode when warranted."""
        if snapshot.is_safe_mode:
            self._log.debug("risk_sentinel.already_in_safe_mode")
            return

        now = time.monotonic()
        if now - self._last_safe_mode_trigger < SAFE_MODE_CLIENT_COOLDOWN:
            return

        trigger_reason = self._evaluate_risk(price_change_1h, volatility_24h, snapshot)
        if trigger_reason is None:
            return

        self._log.warning(
            "risk_sentinel.safe_mode_trigger",
            reason=trigger_reason,
            price_change_1h_pct=round(price_change_1h, 2),
            volatility_24h=round(volatility_24h, 4),
            btc_health=snapshot.btc_health,
        )
        try:
            tx_hash = await self._client.enter_safe_mode()
            self._last_safe_mode_trigger = now
            self._safe_mode_triggers += 1
            self._log.info(
                "risk_sentinel.safe_mode_entered",
                tx_hash=tx_hash,
                reason=trigger_reason,
                total_triggers=self._safe_mode_triggers,
            )
        except Exception as exc:
            # The router may reject if conditions are no longer met on-chain —
            # this is expected and safe.
            self._log.warning(
                "risk_sentinel.safe_mode_rejected",
                reason=trigger_reason,
                error=str(exc),
            )

    def _evaluate_risk(
        self,
        price_change_1h: float,
        volatility_24h: float,
        snapshot: RouterSnapshot,
    ) -> Optional[str]:
        """
        Return the reason string if any risk condition is met, else None.

        Conditions (per docs/04-autonomous-agents.md):
          1. Price drop > MAX_PRICE_DROP_PCT in last hour.
          2. Annualised 24-h volatility > MAX_VOLATILITY_24H.
          3. BTC health factor < safe_mode_threshold (router knows best,
             but we help accelerate the trigger).
        """
        # Condition 1: price drawdown (>= threshold, i.e., exactly at threshold triggers)
        if price_change_1h <= -self._cfg.max_price_drop_pct:
            return (
                f"price_drop: {abs(price_change_1h):.2f}% > "
                f"threshold {self._cfg.max_price_drop_pct:.1f}%"
            )

        # Condition 2: volatility spike
        if volatility_24h > self._cfg.max_volatility_24h:
            return (
                f"volatility_spike: {volatility_24h:.2%} > "
                f"threshold {self._cfg.max_volatility_24h:.0%}"
            )

        # Condition 3: on-chain health approaching critical
        # Router safe_mode_threshold is typically 110 (1.10).
        # We pre-empt at health ≤ 115 to give router a head start.
        if snapshot.btc_health <= 115:
            return f"btc_health_critical: {snapshot.btc_health} (×100)"

        return None

    # ── Diagnostics ────────────────────────────────────────────────────────────

    def stats(self) -> dict:
        base = super().stats()
        base.update(
            {
                "safe_mode_triggers": self._safe_mode_triggers,
                "price_refreshes": self._price_refreshes,
                "last_router_health": (
                    self._last_router_snapshot.btc_health
                    if self._last_router_snapshot
                    else None
                ),
                "last_safe_mode": (
                    "in_safe_mode"
                    if self._last_router_snapshot and self._last_router_snapshot.is_safe_mode
                    else "normal"
                ),
            }
        )
        return base
