"""
agents/agents/base.py
──────────────────────
Abstract base class for all autonomous agents.

Lifecycle
─────────
  1. await agent.setup()     — one-time initialisation (open connections, etc.)
  2. await agent.run()       — infinite loop: tick → sleep → tick → …
  3. await agent.stop()      — graceful shutdown (close connections, flush logs)

Error handling strategy
────────────────────────
  • Transient errors inside tick() are caught, logged, and the loop continues.
  • Three consecutive fatal errors cause the agent to enter a back-off pause
    (2 × normal interval) before resuming.
  • A KeyboardInterrupt or CancelledError triggers a clean stop().

Subclassing
───────────
  class MyAgent(BaseAgent):
      async def setup(self) -> None:
          await super().setup()
          # … connect, subscribe, etc.

      async def tick(self) -> None:
          # … one monitoring cycle

      async def teardown(self) -> None:
          # … close resources
"""

from __future__ import annotations

import abc
import asyncio
import time
from typing import Optional

from core.logger import get_logger
from config import AgentSettings

log = get_logger(__name__)

# After this many consecutive errors, double the wait before next attempt.
CONSECUTIVE_ERROR_BACKOFF_THRESHOLD = 3
BACKOFF_MULTIPLIER = 2


class BaseAgent(abc.ABC):
    """
    Lifecycle-managed async agent base class.

    Parameters
    ----------
    name:
        Human-readable agent name used in log messages.
    settings:
        Shared configuration object.
    interval:
        Poll interval in seconds.
    """

    def __init__(
        self,
        name: str,
        settings: AgentSettings,
        interval: int,
    ) -> None:
        self.name = name
        self._cfg = settings
        self._interval = interval
        self._running = False
        self._consecutive_errors = 0
        self._total_ticks = 0
        self._total_errors = 0
        self._start_time: Optional[float] = None
        self._log = log.bind(agent=name)

    # ── Abstract interface ─────────────────────────────────────────────────────

    @abc.abstractmethod
    async def setup(self) -> None:
        """
        Called once before the main loop begins.
        Subclasses must call super().setup() first.
        """
        self._log.info("agent.setup")

    @abc.abstractmethod
    async def tick(self) -> None:
        """One monitoring / action cycle. Called every `interval` seconds."""

    async def teardown(self) -> None:
        """
        Called once after the loop exits.
        Override to close connections, flush buffers, etc.
        Subclasses should call super().teardown() last.
        """
        self._log.info("agent.teardown")

    # ── Main loop ──────────────────────────────────────────────────────────────

    async def run(self) -> None:
        """
        Start the agent loop.  Runs until stop() is called or the task is cancelled.
        """
        self._running = True
        self._start_time = time.monotonic()
        self._log.info("agent.starting", interval_s=self._interval)

        try:
            await self.setup()
        except Exception as exc:
            self._log.error("agent.setup_failed", error=str(exc), exc_info=True)
            return

        self._log.info("agent.running")

        try:
            while self._running:
                tick_start = time.monotonic()
                try:
                    await self.tick()
                    self._total_ticks += 1
                    self._consecutive_errors = 0
                except asyncio.CancelledError:
                    raise
                except Exception as exc:
                    self._total_errors += 1
                    self._consecutive_errors += 1
                    self._log.error(
                        "agent.tick_error",
                        error=str(exc),
                        consecutive_errors=self._consecutive_errors,
                        exc_info=True,
                    )

                elapsed = time.monotonic() - tick_start
                # Adaptive wait: if tick took longer than interval, skip sleep
                sleep_time = max(0.0, self._interval - elapsed)

                # Back-off when errors are accumulating
                if self._consecutive_errors >= CONSECUTIVE_ERROR_BACKOFF_THRESHOLD:
                    sleep_time = min(sleep_time * BACKOFF_MULTIPLIER, 300.0)
                    self._log.warning(
                        "agent.backoff",
                        sleep_s=sleep_time,
                        consecutive_errors=self._consecutive_errors,
                    )

                if sleep_time > 0 and self._running:
                    await asyncio.sleep(sleep_time)

        except asyncio.CancelledError:
            self._log.info("agent.cancelled")
        finally:
            try:
                await self.teardown()
            except Exception as exc:
                self._log.error("agent.teardown_failed", error=str(exc))
            self._running = False
            self._log.info(
                "agent.stopped",
                total_ticks=self._total_ticks,
                total_errors=self._total_errors,
                uptime_s=round(time.monotonic() - (self._start_time or 0), 1),
            )

    async def stop(self) -> None:
        """Signal the agent loop to exit cleanly after the current tick."""
        self._running = False
        self._log.info("agent.stop_requested")

    # ── Diagnostics ────────────────────────────────────────────────────────────

    @property
    def is_running(self) -> bool:
        return self._running

    @property
    def uptime_seconds(self) -> float:
        if self._start_time is None:
            return 0.0
        return time.monotonic() - self._start_time

    @property
    def error_rate(self) -> float:
        """Fraction of ticks that resulted in an error."""
        if self._total_ticks == 0:
            return 0.0
        return self._total_errors / self._total_ticks

    def stats(self) -> dict:
        return {
            "agent": self.name,
            "running": self._running,
            "uptime_s": round(self.uptime_seconds, 1),
            "total_ticks": self._total_ticks,
            "total_errors": self._total_errors,
            "error_rate": round(self.error_rate, 4),
            "consecutive_errors": self._consecutive_errors,
        }
