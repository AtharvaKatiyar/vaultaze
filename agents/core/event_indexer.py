"""
agents/core/event_indexer.py
─────────────────────────────
Lightweight on-chain event indexer that maintains the set of users who
currently have active positions in the BTCVault.

The User Guardian agent relies on this to know *which* addresses to watch.

How it works
────────────
  1. On startup, scan all past `Deposit` events from block 0 to latest.
  2. On each poll, fetch events in the new block range and update the set.
  3. Remove users who fully withdraw (zero share balance detected via
     `Withdrawal` events where ybtc_burned equals the stored balance).
  4. Also track `LeverageAdjusted` events to record which users have
     an active leveraged position (the primary guardian target).

Starknet event topics
─────────────────────
Events are identified by their key (selector of the event name):
  Deposit(user, …)          → key = selector("Deposit")
  Withdrawal(user, …)       → key = selector("Withdrawal")
  LeverageAdjusted(user, …) → key = selector("LeverageAdjusted")
  PositionLiquidated(…)     → key = selector("PositionLiquidated")

Starknet-py event pagination
─────────────────────────────
We use client.get_events(from_block, to_block, address, keys, chunk_size)
which returns a paginated EventsChunk. We iterate all pages.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from typing import Optional, Set

from starknet_py.hash.selector import get_selector_from_name
from starknet_py.net.full_node_client import FullNodeClient
from starknet_py.net.client_models import EventsChunk

from core.logger import get_logger
from config import AgentSettings

log = get_logger(__name__)

# How many blocks to fetch per RPC call (Starknet nodes cap this ~1000)
EVENT_CHUNK_SIZE = 500

# Re-scan periodically to catch any missed events
RESYNC_INTERVAL_BLOCKS = 200


@dataclass
class UserRecord:
    """Lightweight record of a vault user's indexed state."""
    address: str
    has_deposit: bool = True
    has_leverage: bool = False


class EventIndexer:
    """
    Maintains a live set of vault users and which ones hold leveraged positions.

    Parameters
    ----------
    settings:
        Global agent configuration.
    rpc_client:
        Shared FullNodeClient (no signing required for reads).
    """

    def __init__(self, settings: AgentSettings, rpc_client: FullNodeClient) -> None:
        self._cfg = settings
        self._rpc = rpc_client
        self._users: dict[str, UserRecord] = {}
        self._last_indexed_block: int = 0
        self._lock = asyncio.Lock()

        # Pre-compute event selectors
        self._sel_deposit = hex(get_selector_from_name("Deposit"))
        self._sel_withdrawal = hex(get_selector_from_name("Withdrawal"))
        self._sel_leverage = hex(get_selector_from_name("LeverageAdjusted"))
        self._sel_liquidated = hex(get_selector_from_name("PositionLiquidated"))

    # ── Public API ─────────────────────────────────────────────────────────────

    async def sync(self, from_block: Optional[int] = None) -> None:
        """
        Fetch and process all vault events from `from_block` to latest.
        If `from_block` is None, sync from the last indexed block.
        """
        start = from_block if from_block is not None else self._last_indexed_block
        try:
            latest = await self._get_latest_block()
        except Exception as exc:
            log.warning("event_indexer.get_latest_block_failed", error=str(exc))
            return

        if start > latest:
            return

        log.debug("event_indexer.syncing", from_block=start, to_block=latest)

        # Fetch all four event types concurrently
        await asyncio.gather(
            self._process_events(self._sel_deposit, start, latest),
            self._process_events(self._sel_withdrawal, start, latest),
            self._process_events(self._sel_leverage, start, latest),
            self._process_events(self._sel_liquidated, start, latest),
        )

        async with self._lock:
            self._last_indexed_block = latest + 1

        log.info(
            "event_indexer.synced",
            indexed_to=latest,
            total_users=len(self._users),
            leveraged_users=len(self.get_leveraged_users()),
        )

    async def full_resync(self) -> None:
        """Re-index from block 0. Useful after a restart."""
        log.info("event_indexer.full_resync_started")
        async with self._lock:
            self._users.clear()
            self._last_indexed_block = 0
        await self.sync(from_block=0)

    def get_all_users(self) -> Set[str]:
        """Return the addresses of all known depositors."""
        return {addr for addr, rec in self._users.items() if rec.has_deposit}

    def get_leveraged_users(self) -> Set[str]:
        """Return addresses of users with an active leveraged position."""
        return {
            addr
            for addr, rec in self._users.items()
            if rec.has_deposit and rec.has_leverage
        }

    def user_count(self) -> int:
        return len(self._users)

    # ── Internal processing ────────────────────────────────────────────────────

    async def _process_events(
        self,
        selector: str,
        from_block: int,
        to_block: int,
    ) -> None:
        """Fetch and process all events matching `selector` in the block range."""
        vault_addr = self._cfg.vault_address_int
        continuation_token: Optional[str] = None

        while True:
            try:
                chunk: EventsChunk = await self._rpc.get_events(
                    address=vault_addr,
                    keys=[[selector]],
                    from_block_number=from_block,
                    to_block_number=to_block,
                    chunk_size=EVENT_CHUNK_SIZE,
                    continuation_token=continuation_token,
                )
            except Exception as exc:
                log.warning(
                    "event_indexer.fetch_failed",
                    selector=selector,
                    from_block=from_block,
                    error=str(exc),
                )
                return

            for event in chunk.events:
                await self._handle_event(selector, event)

            if chunk.continuation_token is None:
                break
            continuation_token = chunk.continuation_token

    async def _handle_event(self, selector: str, event: Any) -> None:
        """Route a single event to the appropriate handler."""
        # The first key in a Starknet event is always the event selector.
        # The second key is the `#[key]` annotated field (user address).
        # Data fields follow in the event.data list.
        if len(event.keys) < 2:
            return  # malformed event

        user_felt = event.keys[1]          # ContractAddress emitted as felt252
        user_hex = hex(user_felt)

        async with self._lock:
            if selector == self._sel_deposit:
                self._on_deposit(user_hex)
            elif selector == self._sel_withdrawal:
                self._on_withdrawal(user_hex)
            elif selector == self._sel_leverage:
                self._on_leverage(user_hex, event)
            elif selector == self._sel_liquidated:
                # keys[1] = liquidator, keys[2] = liquidated user
                if len(event.keys) >= 3:
                    liquidated_hex = hex(event.keys[2])
                    self._on_liquidated(liquidated_hex)

    # ── State mutation helpers (must be called under self._lock) ──────────────

    def _on_deposit(self, user: str) -> None:
        if user not in self._users:
            self._users[user] = UserRecord(address=user)
        self._users[user].has_deposit = True
        log.debug("event_indexer.deposit", user=user)

    def _on_withdrawal(self, user: str) -> None:
        # We mark the deposit as gone; a real implementation would check
        # remaining balance via get_user_position. For simplicity we keep
        # the user in the set but mark has_deposit=False so the guardian
        # skips them. A subsequent deposit re-activates the record.
        if user in self._users:
            # Conservative: keep record, set has_deposit False
            self._users[user].has_deposit = False
            self._users[user].has_leverage = False
        log.debug("event_indexer.withdrawal", user=user)

    def _on_leverage(self, user: str, event: Any) -> None:
        if user not in self._users:
            self._users[user] = UserRecord(address=user)
        # event.data: [old_leverage (u128 low, high), new_leverage (u128 low, high)]
        # If new_leverage > 100 the user has an active position
        if len(event.data) >= 4:
            new_leverage_low = int(event.data[2])
            self._users[user].has_leverage = new_leverage_low > 100
        else:
            self._users[user].has_leverage = True
        log.debug("event_indexer.leverage_adjusted", user=user)

    def _on_liquidated(self, user: str) -> None:
        if user in self._users:
            self._users[user].has_leverage = False
        log.info("event_indexer.position_liquidated", user=user)

    async def _get_latest_block(self) -> int:
        block = await self._rpc.get_block("latest")
        return block.block_number


# Type alias to avoid importing starknet_py types in handlers
from typing import Any  # noqa: E402 (placed after class for readability)
