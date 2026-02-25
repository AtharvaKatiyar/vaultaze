"""
agents/agents/user_guardian.py
────────────────────────────────
User Guardian Agent — liquidation bot and position health monitor.

Responsibilities
────────────────
  1. Maintain the set of users with active positions via `EventIndexer`.
  2. Every `interval` seconds, batch-check health factors for all active users.
  3. Immediately liquidate any position whose health factor ≤ 100 (1.00×).
  4. Log warnings for positions approaching the liquidation threshold
     (health ≤ GUARDIAN_WARN_HEALTH, default 130).
  5. Periodically re-sync the event indexer to catch new depositors.

Liquidation economics
──────────────────────
When `vault.liquidate(user)` is called successfully:
  • The caller (this agent's account) receives the user's BTC collateral
    **plus** the liquidation bonus (LIQUIDATION_BONUS_BPS defined in vault).
  • The user's debt is cleared.
  • This agent earns a net profit on each successful liquidation.

Required on-chain roles
───────────────────────
  ROLE_LIQUIDATOR on vault → liquidate(user)

Security properties
────────────────────
  • The vault contract verifies is_liquidatable(user) before transferring any
    funds.  If this agent attempts to liquidate a healthy position the
    transaction is rejected — no funds move.
  • A compromised guardian can only attempt (and fail) to liquidate healthy
    positions, wasting its own gas.
"""

from __future__ import annotations

import asyncio
import time
from typing import Optional, Set

from agents.base import BaseAgent
from core.event_indexer import EventIndexer
from core.starknet_client import StarknetClient, UserHealthSnapshot
from config import AgentSettings
from core.logger import get_logger

log = get_logger(__name__)

# Re-sync the event indexer every N ticks to catch new users
EVENT_RESYNC_TICKS = 20

# Maximum concurrent health checks (avoid overwhelming the RPC node)
MAX_CONCURRENT_HEALTH_CHECKS = 10

# Minimum seconds between liquidation attempts for the same user.
# The contract enforces correctness; this prevents a tight retry loop.
LIQUIDATION_RETRY_COOLDOWN = 60

# Minimum seconds between warning logs for the same user
WARNING_LOG_COOLDOWN = 300   # 5 minutes


class UserGuardianAgent(BaseAgent):
    """
    Scans all vault users and executes liquidations on unhealthy positions.

    Parameters
    ----------
    settings:
        Shared configuration.
    client:
        Pre-connected StarknetClient signed with ROLE_LIQUIDATOR account.
    indexer:
        Shared EventIndexer for user discovery.
    """

    def __init__(
        self,
        settings: AgentSettings,
        client: StarknetClient,
        indexer: EventIndexer,
    ) -> None:
        super().__init__(
            name="UserGuardian",
            settings=settings,
            interval=settings.guardian_interval,
        )
        self._client = client
        self._indexer = indexer

        # Per-user rate-limiting
        self._last_liquidation_attempt: dict[str, float] = {}
        self._last_warning_log: dict[str, float] = {}

        # Metrics
        self._liquidations_attempted: int = 0
        self._liquidations_succeeded: int = 0
        self._liquidations_rejected: int = 0
        self._warnings_issued: int = 0

        # Tick counter for re-sync scheduling
        self._tick_count: int = 0

    # ── Lifecycle ──────────────────────────────────────────────────────────────

    async def setup(self) -> None:
        await super().setup()
        # Full index from genesis to catch all existing positions
        try:
            await self._indexer.full_resync()
            self._log.info(
                "user_guardian.indexer_ready",
                total_users=self._indexer.user_count(),
                leveraged_users=len(self._indexer.get_leveraged_users()),
            )
        except Exception as exc:
            self._log.warning("user_guardian.indexer_full_resync_failed", error=str(exc))

    # ── Main tick ──────────────────────────────────────────────────────────────

    async def tick(self) -> None:
        """
        One guardian cycle:
          1. (Periodically) sync new events to discover new users.
          2. Batch-check health for all leveraged users.
          3. Liquidate unhealthy positions.
          4. Warn on near-liquidation positions.
        """
        self._tick_count += 1

        # ── Step 1: incremental event sync ──────────────────────────────────
        if self._tick_count % EVENT_RESYNC_TICKS == 0:
            try:
                await self._indexer.sync()
            except Exception as exc:
                self._log.warning("user_guardian.event_sync_failed", error=str(exc))

        # ── Step 2: fetch monitored users ────────────────────────────────────
        leveraged_users = self._indexer.get_leveraged_users()
        if not leveraged_users:
            self._log.debug("user_guardian.no_leveraged_users")
            return

        self._log.debug("user_guardian.scanning", user_count=len(leveraged_users))

        # ── Step 3: batch health checks (throttled concurrency) ─────────────
        snapshots = await self._batch_health_check(leveraged_users)

        # ── Step 4: act on snapshots ─────────────────────────────────────────
        liquidatable = []
        near_liquidation = []

        for snap in snapshots:
            if snap.is_liquidatable:
                liquidatable.append(snap)
            elif snap.health_factor <= self._cfg.guardian_warn_health:
                near_liquidation.append(snap)

        # Process liquidations sequentially (each is a chain tx)
        for snap in liquidatable:
            await self._liquidate(snap)

        # Warn on near-liquidation positions
        for snap in near_liquidation:
            self._warn_near_liquidation(snap)

        self._log.info(
            "user_guardian.scan_complete",
            scanned=len(snapshots),
            liquidatable=len(liquidatable),
            near_liquidation=len(near_liquidation),
        )

    # ── Health check batch ─────────────────────────────────────────────────────

    async def _batch_health_check(
        self, users: Set[str]
    ) -> list[UserHealthSnapshot]:
        """
        Fetch health snapshots for all users with bounded concurrency.
        Users whose positions have disappeared (health = MAX_INT, no debt)
        are automatically filtered out and removed from the indexer's set.
        """
        sem = asyncio.Semaphore(MAX_CONCURRENT_HEALTH_CHECKS)
        results: list[Optional[UserHealthSnapshot]] = []

        async def check_one(user: str) -> Optional[UserHealthSnapshot]:
            async with sem:
                try:
                    snap = await self._client.get_user_health_snapshot(user)
                    return snap
                except Exception as exc:
                    self._log.warning(
                        "user_guardian.health_check_failed",
                        user=user,
                        error=str(exc),
                    )
                    return None

        results = await asyncio.gather(*[check_one(u) for u in users])

        # Filter out None and users with no debt (health = MAX_INT means no leverage)
        no_debt_threshold = 2**128 - 1   # u128::MAX from Cairo
        valid: list[UserHealthSnapshot] = []
        for snap in results:
            if snap is None:
                continue
            if snap.health_factor >= no_debt_threshold:
                # User has no debt — remove from leveraged set to reduce future work
                self._indexer._users.get(snap.user, None) and setattr(
                    self._indexer._users[snap.user], "has_leverage", False
                )
                continue
            valid.append(snap)

        return valid

    # ── Liquidation ────────────────────────────────────────────────────────────

    async def _liquidate(self, snap: UserHealthSnapshot) -> None:
        """Attempt to liquidate an undercollateralised position."""
        now = time.monotonic()

        # Client-side rate limit
        last_attempt = self._last_liquidation_attempt.get(snap.user, 0.0)
        if now - last_attempt < LIQUIDATION_RETRY_COOLDOWN:
            self._log.debug(
                "user_guardian.liquidation_rate_limited",
                user=snap.user,
                cooldown_remaining=round(LIQUIDATION_RETRY_COOLDOWN - (now - last_attempt), 0),
            )
            return

        self._log.warning(
            "user_guardian.liquidation_attempt",
            user=snap.user,
            health_factor=snap.health_factor,
            liquidation_price=snap.liquidation_price,
        )
        self._last_liquidation_attempt[snap.user] = now
        self._liquidations_attempted += 1

        try:
            tx_hash = await self._client.liquidate(snap.user)
            self._liquidations_succeeded += 1
            self._log.info(
                "user_guardian.liquidation_succeeded",
                user=snap.user,
                tx_hash=tx_hash,
                health_factor=snap.health_factor,
            )
            # Mark the user as no longer leveraged in the indexer
            if snap.user in self._indexer._users:
                self._indexer._users[snap.user].has_leverage = False

        except Exception as exc:
            self._liquidations_rejected += 1
            self._log.warning(
                "user_guardian.liquidation_failed",
                user=snap.user,
                error=str(exc),
                note=(
                    "Router/vault may have rejected because position "
                    "health recovered before tx landed — this is safe."
                ),
            )

    # ── Near-liquidation warnings ──────────────────────────────────────────────

    def _warn_near_liquidation(self, snap: UserHealthSnapshot) -> None:
        """Log a structured warning for positions approaching liquidation."""
        now = time.monotonic()
        last_warn = self._last_warning_log.get(snap.user, 0.0)
        if now - last_warn < WARNING_LOG_COOLDOWN:
            return

        self._last_warning_log[snap.user] = now
        self._warnings_issued += 1
        self._log.warning(
            "user_guardian.near_liquidation",
            user=snap.user,
            health_factor=snap.health_factor,
            health_factor_pct=round(snap.health_factor / 100, 2),
            liquidation_price_usd=snap.liquidation_price,
            current_leverage=snap.current_leverage,
            recommendation=(
                "Position is within warning band. "
                "User should reduce leverage or add collateral."
            ),
        )

    # ── Diagnostics ────────────────────────────────────────────────────────────

    def stats(self) -> dict:
        base = super().stats()
        base.update(
            {
                "liquidations_attempted": self._liquidations_attempted,
                "liquidations_succeeded": self._liquidations_succeeded,
                "liquidations_rejected": self._liquidations_rejected,
                "warnings_issued": self._warnings_issued,
                "monitored_users": self._indexer.user_count(),
                "leveraged_users": len(self._indexer.get_leveraged_users()),
            }
        )
        return base
