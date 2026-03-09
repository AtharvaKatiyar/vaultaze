"""
agents/core/starknet_client.py
───────────────────────────────
Typed async wrapper around the BTCSecurityRouter and BTCVault contracts.

All contract calls are channelled through this single module so that:
  • ABIs are loaded once from the compiled Scarb artifacts.
  • Every call is retried with exponential back-off on transient RPC errors.
  • The rest of the codebase deals only with Python types (int, bool, str, dict).

Contract address integers follow the starknet-py convention (plain int).
"""

from __future__ import annotations

import asyncio
import json
import os
from dataclasses import dataclass
from typing import Any, Optional

from starknet_py.net.full_node_client import FullNodeClient
from starknet_py.net.account.account import Account
from starknet_py.net.models.chains import StarknetChainId
from starknet_py.net.signer.stark_curve_signer import KeyPair
from starknet_py.contract import Contract

from core.logger import get_logger
from config import AgentSettings

log = get_logger(__name__)

# ── Retry configuration ───────────────────────────────────────────────────────
MAX_RETRIES = 5
RETRY_BASE_DELAY = 2.0      # seconds — doubled on each attempt
RETRY_MAX_DELAY = 60.0

# ── Confirmed-block threshold ─────────────────────────────────────────────────
# We wait for "ACCEPTED_ON_L2" status (fast finality on Starknet).
TX_WAIT_TIMEOUT = 120       # seconds
TX_CHECK_INTERVAL = 5       # seconds


@dataclass
class UserHealthSnapshot:
    """Per-user health data returned by get_user_health_snapshot()."""
    user: str
    health_factor: int        # ×100, e.g. 150 = 1.50x; MAX_INT = no debt
    liquidation_price: int    # BTC/USD 8-decimal; 0 = no debt
    is_liquidatable: bool
    current_leverage: int     # 100-based


@dataclass
class RouterSnapshot:
    """System-level state returned by get_router_snapshot()."""
    btc_health: int           # ×100
    max_leverage: int         # 100-based
    max_ltv: int              # basis-points
    is_safe_mode: bool
    btc_usd_price: int        # 8-decimal
    is_price_fresh: bool


class StarknetClient:
    """
    Manages connections to the BTCSecurityRouter and BTCVault contracts.

    Each agent that writes to the chain should supply its own private key
    (i.e. call `connect` with its own address/key). Multiple read-only
    view calls can share a single FullNodeClient without a private key.

    Usage
    -----
        client = StarknetClient(settings)
        await client.connect(
            address=settings.risk_sentinel_address,
            private_key=settings.risk_sentinel_private_key,
        )
        health = await client.get_btc_health()
        await client.enter_safe_mode()
        await client.disconnect()
    """

    def __init__(self, settings: AgentSettings) -> None:
        self._cfg = settings
        self._rpc: Optional[FullNodeClient] = None
        self._account: Optional[Account] = None
        self._router: Optional[Contract] = None
        self._vault: Optional[Contract] = None
        # Optional — only set when oracle_address + oracle_owner_private_key are configured
        self._oracle_account: Optional[Account] = None
        self._oracle: Optional[Contract] = None

    # ── Connection lifecycle ───────────────────────────────────────────────────

    async def connect(self, address: str, private_key: str) -> None:
        """
        Initialise the RPC client, account signer, and contract dispatchers.

        Parameters
        ----------
        address:
            Hex address of the agent's Starknet account (e.g. '0xabc…').
        private_key:
            Hex private key for signing invoke transactions.
        """
        log.info("starknet_client.connect", network=self._cfg.starknet_network, address=address)

        self._rpc = FullNodeClient(node_url=self._cfg.starknet_rpc_url)

        chain = (
            StarknetChainId.MAINNET
            if self._cfg.is_mainnet
            else StarknetChainId.SEPOLIA
        )
        self._account = Account(
            client=self._rpc,
            address=int(address, 16),
            key_pair=KeyPair.from_private_key(int(private_key, 16)),
            chain=chain,
        )

        router_abi = self._load_abi("BTCSecurityRouter")
        vault_abi = self._load_abi("BTCVault")

        self._router = Contract(
            address=self._cfg.router_address_int,
            abi=router_abi,
            provider=self._account,
        )
        self._vault = Contract(
            address=self._cfg.vault_address_int,
            abi=vault_abi,
            provider=self._account,
        )
        # ── Optional: mock oracle keeper account ──────────────────────────────
        if self._cfg.oracle_address and self._cfg.oracle_owner_private_key and self._cfg.oracle_owner_address:
            oracle_abi = self._load_abi("MockPragmaOracle")
            self._oracle_account = Account(
                client=self._rpc,
                address=int(self._cfg.oracle_owner_address, 16),
                key_pair=KeyPair.from_private_key(int(self._cfg.oracle_owner_private_key, 16)),
                chain=chain,
            )
            self._oracle = Contract(
                address=int(self._cfg.oracle_address, 16),
                abi=oracle_abi,
                provider=self._oracle_account,
            )
            log.info("starknet_client.oracle_keeper_enabled", oracle=self._cfg.oracle_address)

        log.info("starknet_client.connected", router=self._cfg.router_address, vault=self._cfg.vault_address)

    async def disconnect(self) -> None:
        """Close the underlying HTTP session."""
        if self._rpc is not None:
            await self._rpc.close()
            log.debug("starknet_client.disconnected")

    # ── Router: view functions ─────────────────────────────────────────────────

    async def get_btc_health(self) -> int:
        """
        Return the global BTC health factor (×100).
        E.g. 150 → health = 1.50 (50% overcollateralised).
        """
        result = await self._view(self._router, "get_btc_health")
        return int(result[0])

    async def get_max_leverage(self) -> int:
        """Return the router's current dynamic max leverage (100-based)."""
        result = await self._view(self._router, "get_max_leverage")
        return int(result[0])

    async def get_max_ltv(self) -> int:
        """Return the router's current dynamic max LTV (basis points)."""
        result = await self._view(self._router, "get_max_ltv")
        return int(result[0])

    async def is_safe_mode(self) -> bool:
        """Return True when the router is in safe mode."""
        result = await self._view(self._router, "is_safe_mode")
        return bool(result[0])

    async def get_btc_usd_price(self) -> int:
        """
        Return the cached BTC/USD price from Pragma (8-decimal integer).
        Returns 0 when the price is stale.
        """
        result = await self._view(self._router, "get_btc_usd_price")
        return int(result[0])

    async def is_price_fresh(self) -> bool:
        """Return True when the Pragma price is within MAX_PRICE_AGE seconds."""
        result = await self._view(self._router, "is_price_fresh")
        return bool(result[0])

    async def get_router_snapshot(self) -> RouterSnapshot:
        """Fetch all commonly needed router state in one round-trip batch."""
        health, max_lev, max_ltv, safe, price, fresh = await asyncio.gather(
            self.get_btc_health(),
            self.get_max_leverage(),
            self.get_max_ltv(),
            self.is_safe_mode(),
            self.get_btc_usd_price(),
            self.is_price_fresh(),
        )
        return RouterSnapshot(
            btc_health=health,
            max_leverage=max_lev,
            max_ltv=max_ltv,
            is_safe_mode=safe,
            btc_usd_price=price,
            is_price_fresh=fresh,
        )

    # ── Router: write functions ────────────────────────────────────────────────

    async def enter_safe_mode(self) -> str:
        """
        Trigger safe mode on the router.
        Requires the connected account to hold ROLE_GUARDIAN.
        Returns the transaction hash (hex string).
        """
        return await self._invoke(self._router, "enter_safe_mode")

    async def refresh_btc_price(self) -> str:
        """
        Pull the latest BTC/USD price from Pragma and store it in the router.
        Requires ROLE_KEEPER.
        Returns the transaction hash.
        """
        return await self._invoke(self._router, "refresh_btc_price")

    async def set_oracle_mock_price(self, price_usd: float) -> str:
        """
        Push a fresh price to the MockPragmaOracle (testnet only).

        This refreshes the oracle's `last_updated` timestamp so that the
        subsequent `router.refresh_btc_price()` call does not fail with
        'Pragma data too stale'. Only available when oracle_address and
        oracle_owner_private_key are configured in settings.

        Converts `price_usd` to Pragma's 8-decimal u128 format.
        Returns the transaction hash or empty string if oracle not configured.
        """
        if self._oracle is None:
            return ""
        # Pragma 8-decimal format: $95,000.00 → 9_500_000_000_000
        price_pragma = int(price_usd * 10 ** 8)
        return await self._invoke(self._oracle, "set_price", [price_pragma])

    @property
    def has_oracle_keeper(self) -> bool:
        """True when the mock oracle keeper account is configured."""
        return self._oracle is not None

    # ── Vault: view functions ──────────────────────────────────────────────────

    async def get_user_health(self, user: str) -> int:
        """
        Return the user's health factor (×100).
        Returns int(2**128 - 1) when the user has no leveraged debt.
        """
        result = await self._view(self._vault, "get_user_health", [int(user, 16)])
        return self._to_int(result[0])

    async def get_liquidation_price(self, user: str) -> int:
        """
        Return the BTC/USD price (8 decimals) at which the user would be liquidated.
        Returns 0 when the user has no debt.
        """
        result = await self._view(self._vault, "get_liquidation_price", [int(user, 16)])
        return self._to_int(result[0])

    async def is_liquidatable(self, user: str) -> bool:
        """Return True when the user's health factor is ≤ 100 (1.00x)."""
        result = await self._view(self._vault, "is_liquidatable", [int(user, 16)])
        return bool(result[0])

    async def get_user_position(self, user: str) -> tuple[int, int, int]:
        """
        Return (ybtc_balance, btc_value_sat, leverage×100).
        leverage = 0 means no leveraged position.

        Note: Cairo returns (u256, u256, u128) as a single outer element when
        starknet-py deserializes tuple return types, so we unpack result[0]
        as the inner 3-tuple, not result[0..2] directly.
        """
        result = await self._view(self._vault, "get_user_position", [int(user, 16)])
        # result = [(ybtc_balance, btc_value, leverage)]  — one outer element
        inner = result[0]
        return self._to_int(inner[0]), self._to_int(inner[1]), self._to_int(inner[2])

    async def get_total_assets(self) -> int:
        """Return total BTC assets in the vault (satoshis)."""
        result = await self._view(self._vault, "get_total_assets")
        return self._to_int(result[0])

    async def get_apy(self) -> int:
        """Return the vault's estimated APY in basis points (1000 = 10%)."""
        result = await self._view(self._vault, "get_apy")
        return int(result[0])

    async def get_user_health_snapshot(self, user: str) -> UserHealthSnapshot:
        """Fetch all per-user health data in a single batch."""
        health, liq_price, liquidatable, position = await asyncio.gather(
            self.get_user_health(user),
            self.get_liquidation_price(user),
            self.is_liquidatable(user),
            self.get_user_position(user),
        )
        _, _, leverage = position
        return UserHealthSnapshot(
            user=user,
            health_factor=health,
            liquidation_price=liq_price,
            is_liquidatable=liquidatable,
            current_leverage=leverage,
        )

    # ── Vault: write functions ─────────────────────────────────────────────────

    async def liquidate(self, user: str) -> str:
        """
        Liquidate an under-collateralised position.
        Requires ROLE_LIQUIDATOR on the vault.
        Returns the transaction hash.
        """
        return await self._invoke(self._vault, "liquidate", [int(user, 16)])

    async def trigger_yield_accrual(self) -> str:
        """
        Trigger on-chain yield accrual for all active strategies.
        Requires ROLE_KEEPER on the vault.
        Returns the transaction hash.
        """
        return await self._invoke(self._vault, "trigger_yield_accrual")

    # ── Internal helpers ───────────────────────────────────────────────────────

    @staticmethod
    def _to_int(val: Any) -> int:
        """
        Convert a starknet-py call result field to a Python int.
        starknet-py may return u256 values as a 2-element tuple (low, high)
        rather than a single int, depending on ABI deserialization.
        """
        if isinstance(val, (tuple, list)) and len(val) == 2:
            low, high = val
            return int(low) + (int(high) << 128)
        return int(val)

    def _load_abi(self, contract_name: str) -> list[dict]:
        """
        Load the Sierra ABI from the compiled Scarb artifact.

        The JSON file at vault/target/dev/vault_{contract_name}.contract_class.json
        contains an 'abi' key whose value is a JSON-encoded string (Sierra format).
        """
        artifact_path = os.path.join(
            self._cfg.artifacts_dir,
            f"vault_{contract_name}.contract_class.json",
        )
        if not os.path.exists(artifact_path):
            raise FileNotFoundError(
                f"Compiled artifact not found: {artifact_path}\n"
                "Run `cd vault && scarb build` to compile the contracts first."
            )
        with open(artifact_path, "r", encoding="utf-8") as fh:
            data = json.load(fh)

        raw_abi = data.get("abi", "[]")
        # In Sierra (Cairo 2.x) the abi field is a JSON-encoded string
        if isinstance(raw_abi, str):
            return json.loads(raw_abi)
        # Older Cairo 1.x contract classes have abi as a plain list
        return raw_abi

    async def _view(
        self,
        contract: Optional[Contract],
        fn_name: str,
        calldata: Optional[list[Any]] = None,
    ) -> list[Any]:
        """Call a view (state_mutability=view) function with retry."""
        assert contract is not None, "Client not connected — call connect() first"
        calldata = calldata or []
        for attempt in range(1, MAX_RETRIES + 1):
            try:
                fn = contract.functions[fn_name]
                result = await fn.call(*calldata)
                # starknet-py returns a named tuple; cast to plain list
                return list(result)
            except Exception as exc:
                delay = min(RETRY_BASE_DELAY * (2 ** (attempt - 1)), RETRY_MAX_DELAY)
                log.warning(
                    "starknet_view_failed",
                    fn=fn_name,
                    attempt=attempt,
                    error=str(exc),
                    retry_in=delay,
                )
                if attempt == MAX_RETRIES:
                    raise
                await asyncio.sleep(delay)
        return []  # unreachable

    async def _invoke(
        self,
        contract: Optional[Contract],
        fn_name: str,
        calldata: Optional[list[Any]] = None,
    ) -> str:
        """
        Invoke a state-changing function with retry.
        Uses invoke_v3 (STRK fee token) with auto fee estimation.
        Returns the transaction hash as a hex string.
        """
        assert contract is not None, "Client not connected — call connect() first"
        calldata = calldata or []
        for attempt in range(1, MAX_RETRIES + 1):
            try:
                fn = contract.functions[fn_name]
                invocation = await fn.invoke_v3(*calldata, auto_estimate=True)
                log.info(
                    "tx_submitted",
                    fn=fn_name,
                    tx_hash=hex(invocation.hash),
                )
                # Wait for acceptance on L2
                await invocation.wait_for_acceptance(
                    check_interval=TX_CHECK_INTERVAL,
                )
                log.info("tx_accepted", fn=fn_name, tx_hash=hex(invocation.hash))
                return hex(invocation.hash)
            except Exception as exc:
                delay = min(RETRY_BASE_DELAY * (2 ** (attempt - 1)), RETRY_MAX_DELAY)
                log.warning(
                    "starknet_invoke_failed",
                    fn=fn_name,
                    attempt=attempt,
                    error=str(exc),
                    retry_in=delay,
                )
                if attempt == MAX_RETRIES:
                    raise
                await asyncio.sleep(delay)
        return ""  # unreachable
