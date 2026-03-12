"""
agents/config.py
────────────────
Central configuration loaded from environment variables (or a .env file).
All other modules import `settings` from here.
"""

from __future__ import annotations

import os
from pydantic import field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class AgentSettings(BaseSettings):
    """
    All configuration is read from environment variables.
    Place a .env file next to main.py (or export variables before running).
    See .env.example for the full list of supported keys.
    """

    model_config = SettingsConfigDict(
        env_file=os.path.join(os.path.dirname(__file__), ".env"),
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    # ── Network ───────────────────────────────────────────────────────────────
    starknet_network: str = "sepolia"
    # Blast public endpoint has a much more generous free rate limit than
    # nethermind's shared node (which throttles at ~1 req/s via zan.top).
    starknet_rpc_url: str = "https://starknet-sepolia.public.blastapi.io"

    # ── Contract Addresses (hex strings) ─────────────────────────────────────
    router_address: str = "0x0"
    vault_address: str = "0x0"

    # ── Risk Sentinel Wallet ──────────────────────────────────────────────────
    risk_sentinel_private_key: str = "0x0"
    risk_sentinel_address: str = "0x0"

    # ── Strategy Rebalancer Wallet ────────────────────────────────────────────
    rebalancer_private_key: str = "0x0"
    rebalancer_address: str = "0x0"

    # ── User Guardian Wallet ──────────────────────────────────────────────────
    guardian_private_key: str = "0x0"
    guardian_address: str = "0x0"

    # ── Poll Intervals (seconds) ──────────────────────────────────────────────
    risk_sentinel_interval: int = 60
    rebalancer_interval: int = 300
    guardian_interval: int = 30

    # ── Risk Thresholds ───────────────────────────────────────────────────────
    max_price_drop_pct: float = 10.0         # % drop in 1 h → safe mode
    max_volatility_24h: float = 0.80         # annualised σ → safe mode
    leverage_rebalance_threshold: float = 0.1
    guardian_warn_health: int = 130          # health×100 — warning level
    guardian_liquidate_health: int = 100     # health×100 — liquidation trigger

    # ── Price Feed ────────────────────────────────────────────────────────────
    price_history_size: int = 288            # rolling window depth
    price_sample_max_age: int = 600          # seconds before sample expires

    # ── Mock Oracle Keeper (testnet / Sepolia only) ───────────────────────────
    # Set these three vars when using the MockPragmaOracle deployed on Sepolia.
    # The sentinel will push a fresh price to the mock oracle before each
    # router.refresh_btc_price() call, keeping the oracle timestamp current.
    # Leave empty ("") to skip (use a real Pragma oracle on mainnet instead).
    oracle_address: str = ""
    oracle_owner_private_key: str = ""
    oracle_owner_address: str = ""

    # ── Faucet Server (testnet / Sepolia only) ────────────────────────────────
    # The faucet server mints test wBTC on behalf of any requesting wallet.
    # Set to the deployer's credentials (same account that owns MockWBTC).
    # Falls back to oracle_owner_private_key / oracle_owner_address if empty.
    faucet_private_key: str = ""
    faucet_address: str = ""
    # MockWBTC contract — vault_address is set to the deployer, only it can mint
    mock_wbtc_address: str = "0x0129f01b63b9eb403e07c9da8e69e2bed648a5fbc81fddb0b27768ee323bf446"
    # Per-request cap (satoshi, 8 decimals). Default = 5 wBTC
    faucet_max_satoshi: int = 500_000_000
    # Hours a wallet must wait between requests
    faucet_rate_limit_hours: int = 24
    # Port the faucet HTTP server listens on
    faucet_port: int = 8400

    # ── Logging ───────────────────────────────────────────────────────────────
    log_level: str = "INFO"
    log_format: str = "json"                 # "json" | "console"

    # ── Prometheus Metrics ────────────────────────────────────────────────────
    enable_metrics: bool = False
    metrics_port: int = 9090

    # ── Derived helpers ───────────────────────────────────────────────────────

    @field_validator("*", mode="before")
    @classmethod
    def strip_quotes(cls, v: object) -> object:
        """
        Railway (and some other platforms) automatically wraps env var values
        in double quotes when they are stored via their UI, so the Python
        process receives  '"0x06e077f2…"'  instead of  '0x06e077f2…'.
        Strip any leading/trailing single or double quotes from every string
        field before Pydantic validates it further.
        """
        if isinstance(v, str):
            return v.strip('"').strip("'")
        return v

    @field_validator("starknet_network")
    @classmethod
    def validate_network(cls, v: str) -> str:
        allowed = {"mainnet", "sepolia"}
        if v.lower() not in allowed:
            raise ValueError(f"starknet_network must be one of {allowed}, got '{v}'")
        return v.lower()

    @field_validator("log_level")
    @classmethod
    def validate_log_level(cls, v: str) -> str:
        allowed = {"DEBUG", "INFO", "WARNING", "ERROR"}
        v = v.upper()
        if v not in allowed:
            raise ValueError(f"log_level must be one of {allowed}")
        return v

    @model_validator(mode="after")
    def validate_addresses(self) -> "AgentSettings":
        """Warn (but do not hard-fail) when placeholder addresses are left as 0x0."""
        placeholders = [
            ("router_address", self.router_address),
            ("vault_address", self.vault_address),
        ]
        for name, addr in placeholders:
            if addr in ("0x0", "0", ""):
                import warnings
                warnings.warn(
                    f"[config] {name} is still set to the placeholder '0x0'. "
                    "Update it in .env before running against a live network.",
                    stacklevel=2,
                )
        return self

    # ── Convenience properties ────────────────────────────────────────────────

    @property
    def router_address_int(self) -> int:
        """Return the router address as an integer (required by starknet-py)."""
        return int(self.router_address, 16)

    @property
    def vault_address_int(self) -> int:
        return int(self.vault_address, 16)

    @property
    def is_mainnet(self) -> bool:
        return self.starknet_network == "mainnet"

    @property
    def artifacts_dir(self) -> str:
        """Path to the compiled contract artifacts directory."""
        return os.path.join(
            os.path.dirname(__file__),
            "..", "vault", "target", "dev",
        )


# Singleton — import this everywhere
settings = AgentSettings()
