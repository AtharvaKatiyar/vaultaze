"""
agents/main.py
───────────────
Orchestrator — starts all three autonomous agents concurrently.

Usage
─────
    cd agents/
    python main.py                        # run all three agents
    python main.py --agent risk_sentinel  # run only one agent
    python main.py --agent rebalancer
    python main.py --agent guardian

Environment
───────────
    Copy .env.example to .env and fill in the contract addresses,
    RPC endpoint, and agent wallet keys before running.

Architecture
────────────
    Each agent runs as an independent asyncio Task.
    They share:
      • settings  — read-only configuration
      • price_feed  — shared aiohttp session + rolling price history
      • event_indexer — shared on-chain event cache (rebalancer + guardian)

    They use separate Starknet accounts (different private keys, different roles).

Signal handling
───────────────
    SIGINT / SIGTERM → graceful shutdown: each agent finishes its current tick,
    then teardown() is called before the process exits.
"""

from __future__ import annotations

import argparse
import asyncio
import signal
import sys

from config import settings
from core.logger import configure_logging, get_logger
from core.price_feed import PriceFeed
from core.starknet_client import StarknetClient
from core.event_indexer import EventIndexer
from starknet_py.net.full_node_client import FullNodeClient

from agents.risk_sentinel import RiskSentinelAgent
from agents.strategy_rebalancer import StrategyRebalancerAgent
from agents.user_guardian import UserGuardianAgent

log = get_logger(__name__)


# ── Agent factory ─────────────────────────────────────────────────────────────


async def build_risk_sentinel(feed: PriceFeed) -> RiskSentinelAgent:
    """Create and connect the Risk Sentinel agent."""
    client = StarknetClient(settings)
    await client.connect(
        address=settings.risk_sentinel_address,
        private_key=settings.risk_sentinel_private_key,
    )
    return RiskSentinelAgent(settings=settings, client=client, feed=feed)


async def build_strategy_rebalancer() -> StrategyRebalancerAgent:
    """Create and connect the Strategy Rebalancer agent."""
    client = StarknetClient(settings)
    await client.connect(
        address=settings.rebalancer_address,
        private_key=settings.rebalancer_private_key,
    )
    return StrategyRebalancerAgent(settings=settings, client=client)


async def build_user_guardian(indexer: EventIndexer) -> UserGuardianAgent:
    """Create and connect the User Guardian agent."""
    client = StarknetClient(settings)
    await client.connect(
        address=settings.guardian_address,
        private_key=settings.guardian_private_key,
    )
    return UserGuardianAgent(settings=settings, client=client, indexer=indexer)


# ── Main coroutine ─────────────────────────────────────────────────────────────


async def run(agent_filter: str | None = None) -> None:
    """
    Instantiate and run the selected agents concurrently.

    Parameters
    ----------
    agent_filter:
        If provided, only the named agent is started.
        Options: "risk_sentinel" | "rebalancer" | "guardian" | None (all).
    """
    configure_logging(level=settings.log_level, fmt=settings.log_format)

    log.info(
        "btc_vault_agents.starting",
        network=settings.starknet_network,
        rpc=settings.starknet_rpc_url,
        router=settings.router_address,
        vault=settings.vault_address,
        agent_filter=agent_filter or "all",
    )

    # ── Shared infrastructure ─────────────────────────────────────────────────
    feed = PriceFeed(
        history_size=settings.price_history_size,
        sample_max_age=settings.price_sample_max_age,
    )
    # Shared read-only RPC for event indexer (no signing key needed)
    rpc = FullNodeClient(node_url=settings.starknet_rpc_url)
    indexer = EventIndexer(settings=settings, rpc_client=rpc)

    # ── Build requested agents ─────────────────────────────────────────────────
    agents = []
    tasks: list[asyncio.Task] = []

    if agent_filter in (None, "risk_sentinel"):
        sentinel = await build_risk_sentinel(feed)
        agents.append(sentinel)

    if agent_filter in (None, "rebalancer"):
        rebalancer = await build_strategy_rebalancer()
        agents.append(rebalancer)

    if agent_filter in (None, "guardian"):
        guardian = await build_user_guardian(indexer)
        agents.append(guardian)

    if not agents:
        log.error("no_agents_selected", agent_filter=agent_filter)
        return

    # ── Launch all agents as concurrent tasks ─────────────────────────────────
    for agent in agents:
        tasks.append(asyncio.create_task(agent.run(), name=agent.name))

    log.info("all_agents_running", count=len(agents), names=[a.name for a in agents])

    # ── Graceful shutdown on SIGINT / SIGTERM ──────────────────────────────────
    loop = asyncio.get_running_loop()
    stop_event = asyncio.Event()

    def _signal_handler(sig: signal.Signals) -> None:
        log.info("shutdown_signal_received", signal=sig.name)
        stop_event.set()

    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, _signal_handler, sig)

    # Wait until a stop signal arrives or all tasks complete on their own
    try:
        await stop_event.wait()
    except asyncio.CancelledError:
        pass

    log.info("shutting_down")
    for agent in agents:
        await agent.stop()

    # Give tasks a moment to finish their current tick
    await asyncio.gather(*tasks, return_exceptions=True)

    # ── Print final stats ─────────────────────────────────────────────────────
    for agent in agents:
        log.info("agent_final_stats", **agent.stats())

    log.info("btc_vault_agents.stopped")


# ── CLI entry point ────────────────────────────────────────────────────────────


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="BTC Vault Autonomous Agents",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--agent",
        choices=["risk_sentinel", "rebalancer", "guardian"],
        default=None,
        help="Run only a specific agent (default: run all three).",
    )
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()
    try:
        asyncio.run(run(agent_filter=args.agent))
    except KeyboardInterrupt:
        sys.exit(0)
