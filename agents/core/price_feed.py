"""
agents/core/price_feed.py
─────────────────────────
Multi-exchange BTC/USD price feed with:
  • Parallel fetching from Binance, Coinbase, and Kraken REST APIs
  • Median aggregation (ignores any one bad actor)
  • Rolling price-history window for volatility + drawdown calculations
  • Annualised 24-h volatility (log-return std dev × √(periods_per_year))
  • 1-hour price-change percentage (for safe-mode trigger)

All public methods are async and safe to call from multiple coroutines.

Usage:
    feed = PriceFeed(history_size=288, sample_max_age=600)
    await feed.start_session()         # call once; creates the aiohttp session
    ...
    price   = await feed.get_price()   # current median USD price
    vol     = await feed.get_volatility_24h()
    change  = await feed.get_price_change_1h()
    ...
    await feed.close_session()
"""

from __future__ import annotations

import asyncio
import math
import time
from collections import deque
from dataclasses import dataclass
from statistics import median
from typing import Deque, Optional

import aiohttp

from core.logger import get_logger

log = get_logger(__name__)

# ── Exchange API endpoints ────────────────────────────────────────────────────

BINANCE_TICKER_URL = "https://api.binance.com/api/v3/ticker/24hr?symbol=BTCUSDT"
COINBASE_SPOT_URL = "https://api.coinbase.com/v2/prices/BTC-USD/spot"
KRAKEN_TICKER_URL = "https://api.kraken.com/0/public/Ticker?pair=XBTUSD"

# Timeout per single HTTP request
REQUEST_TIMEOUT = aiohttp.ClientTimeout(total=10)

# Approximate periods per year for different sample intervals (seconds)
# We store one sample per REBALANCER_INTERVAL (default 300 s = 5 min)
# → 365 * 24 * 12 = 105_120 periods/year
_PERIODS_PER_DAY = 288      # 24 h / 5 min
_PERIODS_PER_YEAR = _PERIODS_PER_DAY * 365


@dataclass
class PriceSample:
    """A single timestamped price observation."""
    price: float
    timestamp: float   # unix epoch (seconds)


class PriceFeed:
    """
    Fetches BTC/USD from three exchanges and maintains a rolling window of
    historical prices for volatility and drawdown calculations.

    Parameters
    ----------
    history_size:
        Maximum number of price samples to keep (default 288 = 24 h at 5-min sampling).
    sample_max_age:
        Samples older than this many seconds are pruned on each fetch (default 600 s).
    """

    def __init__(
        self,
        history_size: int = 288,
        sample_max_age: int = 600,
    ) -> None:
        self._history: Deque[PriceSample] = deque(maxlen=history_size)
        self._sample_max_age = sample_max_age
        self._session: Optional[aiohttp.ClientSession] = None
        self._lock = asyncio.Lock()

    # ── Session lifecycle ──────────────────────────────────────────────────────

    async def start_session(self) -> None:
        """Create the shared aiohttp session. Call once before first fetch."""
        if self._session is None or self._session.closed:
            self._session = aiohttp.ClientSession(timeout=REQUEST_TIMEOUT)

    async def close_session(self) -> None:
        """Gracefully close the aiohttp session."""
        if self._session and not self._session.closed:
            await self._session.close()

    # ── Public API ─────────────────────────────────────────────────────────────

    async def get_price(self) -> float:
        """
        Fetch fresh prices from all three exchanges and return the median.
        Automatically records the sample into the rolling history.
        Raises RuntimeError if no exchange responds.
        """
        prices = await self._fetch_all()
        if not prices:
            raise RuntimeError("All price sources failed — cannot determine BTC/USD price")
        p = median(prices)
        await self._record(p)
        log.debug("price_fetched", price=round(p, 2), sources=len(prices))
        return p

    async def get_24h_high(self) -> float:
        """Return the highest price observed in the rolling history."""
        samples = self._valid_samples()
        if not samples:
            return 0.0
        return max(s.price for s in samples)

    async def get_24h_low(self) -> float:
        """Return the lowest price observed in the rolling history."""
        samples = self._valid_samples()
        if not samples:
            return 0.0
        return min(s.price for s in samples)

    async def get_price_change_1h(self) -> float:
        """
        Return the percentage price change over the last hour (negative = drop).
        Uses the oldest sample within ~60 min as the reference.
        Returns 0.0 if there is insufficient history.
        """
        samples = self._valid_samples()
        if len(samples) < 2:
            return 0.0

        now = time.time()
        one_hour_ago = now - 3600

        # Find the sample closest to 1 hour ago
        candidates = [s for s in samples if s.timestamp <= now - 3300]  # allow 5-min slack
        if not candidates:
            return 0.0

        reference = min(candidates, key=lambda s: abs(s.timestamp - one_hour_ago))
        current = samples[-1].price
        if reference.price == 0:
            return 0.0
        return (current - reference.price) / reference.price * 100.0

    async def get_volatility_24h(self) -> float:
        """
        Compute the annualised 24-h volatility from log returns in the history.

        σ_annual = σ_log_returns × √(periods_per_year)

        Returns 0.0 when there are fewer than 3 samples.
        """
        samples = self._valid_samples()
        if len(samples) < 3:
            return 0.0

        prices = [s.price for s in samples]
        log_returns = [
            math.log(prices[i] / prices[i - 1])
            for i in range(1, len(prices))
            if prices[i - 1] > 0
        ]
        if len(log_returns) < 2:
            return 0.0

        n = len(log_returns)
        mean = sum(log_returns) / n
        variance = sum((r - mean) ** 2 for r in log_returns) / (n - 1)
        sigma_interval = math.sqrt(variance)

        # Annualise assuming each sample is taken every ~5 minutes
        sample_interval_seconds = self._estimate_sample_interval(samples)
        periods_per_year = (365 * 24 * 3600) / max(sample_interval_seconds, 1)
        return sigma_interval * math.sqrt(periods_per_year)

    # ── Exchange fetchers ──────────────────────────────────────────────────────

    async def _fetch_all(self) -> list[float]:
        """Fetch from all exchanges concurrently; return list of valid prices."""
        if self._session is None or self._session.closed:
            await self.start_session()

        tasks = [
            self._fetch_binance(),
            self._fetch_coinbase(),
            self._fetch_kraken(),
        ]
        results = await asyncio.gather(*tasks, return_exceptions=True)
        valid: list[float] = []
        sources = ["binance", "coinbase", "kraken"]
        for src, r in zip(sources, results):
            if isinstance(r, Exception):
                log.warning("price_source_failed", source=src, error=str(r))
            elif r is not None and r > 0:
                valid.append(r)
        return valid

    async def _fetch_binance(self) -> float:
        """GET /api/v3/ticker/24hr — uses 'lastPrice' field."""
        assert self._session is not None
        async with self._session.get(BINANCE_TICKER_URL) as resp:
            resp.raise_for_status()
            data = await resp.json()
            return float(data["lastPrice"])

    async def _fetch_coinbase(self) -> float:
        """GET /v2/prices/BTC-USD/spot — uses data.amount field."""
        assert self._session is not None
        async with self._session.get(COINBASE_SPOT_URL) as resp:
            resp.raise_for_status()
            data = await resp.json()
            return float(data["data"]["amount"])

    async def _fetch_kraken(self) -> float:
        """GET /0/public/Ticker?pair=XBTUSD — uses result.XXBTZUSD.c[0]."""
        assert self._session is not None
        async with self._session.get(KRAKEN_TICKER_URL) as resp:
            resp.raise_for_status()
            data = await resp.json()
            # Kraken returns the pair key as 'XXBTZUSD'
            pair_data = data["result"].get("XXBTZUSD") or next(
                iter(data["result"].values())
            )
            return float(pair_data["c"][0])

    # ── Internal helpers ───────────────────────────────────────────────────────

    async def _record(self, price: float) -> None:
        """Append a price sample and prune stale entries."""
        async with self._lock:
            now = time.time()
            self._history.append(PriceSample(price=price, timestamp=now))
            # Prune samples that are too old (beyond the declared window)
            cutoff = now - self._sample_max_age * self._history.maxlen  # type: ignore[operator]
            while self._history and self._history[0].timestamp < cutoff:
                self._history.popleft()

    def _valid_samples(self) -> list[PriceSample]:
        """Return samples that are not older than sample_max_age * history_size."""
        now = time.time()
        cutoff = now - self._sample_max_age * len(self._history)
        return [s for s in self._history if s.timestamp >= cutoff]

    @staticmethod
    def _estimate_sample_interval(samples: list[PriceSample]) -> float:
        """Estimate the average time between consecutive samples (seconds)."""
        if len(samples) < 2:
            return 300.0  # default 5 min
        deltas = [
            samples[i].timestamp - samples[i - 1].timestamp
            for i in range(1, len(samples))
        ]
        return sum(deltas) / len(deltas)
