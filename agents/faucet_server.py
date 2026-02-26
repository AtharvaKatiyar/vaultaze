"""
agents/faucet_server.py
────────────────────────
Testnet wBTC faucet HTTP server.

Any Starknet Sepolia wallet can POST their address and receive test wBTC.
The server uses the deployer's private key to execute a multicall that:
  1. Refreshes the MockPragmaOracle price  ($95,000)
  2. Syncs the BTCSecurityRouter price cache
  3. Mints Mock wBTC to the requesting wallet

This mirrors how public Ethereum testnet faucets work — the user never needs
the deployer key in their browser.

Run standalone
──────────────
    cd agents/
    uvicorn faucet_server:app --host 0.0.0.0 --port 8400 --reload

Environment variables required (add to agents/.env)
────────────────────────────────────────────────────
    FAUCET_PRIVATE_KEY  — deployer private key (or reuse ORACLE_OWNER_PRIVATE_KEY)
    FAUCET_ADDRESS      — deployer address    (or reuse ORACLE_OWNER_ADDRESS)
    STARKNET_RPC_URL    — already set for the agents
"""

from __future__ import annotations

import asyncio
import time
from contextlib import asynccontextmanager
from typing import Optional

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, field_validator

from starknet_py.net.full_node_client import FullNodeClient
from starknet_py.net.account.account import Account
from starknet_py.net.models.chains import StarknetChainId
from starknet_py.net.signer.stark_curve_signer import KeyPair
from starknet_py.net.client_models import Call
from starknet_py.hash.selector import get_selector_from_name

from config import settings
from core.logger import get_logger

log = get_logger(__name__)

# ── Deployed contract addresses (Sepolia) ─────────────────────────────────────
DEPLOYER_ADDRESS          = "0x01390501de9c3e2c1f06d97fd317c1cd002d95250ab6f58bf1f272bdb9f8ed18"
MOCK_ORACLE_ADDRESS       = "0x06d1c9aa3cb65003c51a4b360c8ac3a23a9724530246031ba92ff0b2461f7e74"
MOCK_WBTC_ADDRESS         = "0x0129f01b63b9eb403e07c9da8e69e2bed648a5fbc81fddb0b27768ee323bf446"
BTCSECURITY_ROUTER_ADDR   = "0x014c306f04fd602c1a06f61367de622af2558972c7eead39600b5d99fd1e2639"

# $95,000 in Pragma 8-decimal format (u128)
DEFAULT_BTC_PRICE = 9_500_000_000_000

# ── Faucet parameters ─────────────────────────────────────────────────────────
MAX_SATOSHI_PER_REQUEST   = 500_000_000   # 5 wBTC per request
DEFAULT_SATOSHI           = 100_000_000   # 1 wBTC default
RATE_LIMIT_HOURS          = 24            # one request per address per 24 h
TX_CHECK_INTERVAL         = 5            # poll every 5 s for acceptance

# ── Shared async state ────────────────────────────────────────────────────────
_rate_limits: dict[str, float] = {}      # normalised_address → last_mint_unix
_rate_lock   = asyncio.Lock()
_account: Optional[Account] = None
_rpc: Optional[FullNodeClient] = None
_init_lock   = asyncio.Lock()


# ── Starknet helpers ──────────────────────────────────────────────────────────

def _u256_calldata(value: int) -> list[int]:
    """Split a Python int into [low128, high128] for u256 calldata."""
    return [value & ((1 << 128) - 1), value >> 128]


async def _get_account() -> Account:
    """Lazy-initialise the deployer account on first request."""
    global _account, _rpc
    async with _init_lock:
        if _account is not None:
            return _account

        # Prefer explicit FAUCET_* keys; fall back to ORACLE_OWNER_* (same deployer)
        pk   = settings.faucet_private_key or settings.oracle_owner_private_key
        addr = settings.faucet_address     or settings.oracle_owner_address

        if not pk or pk in ("0x0", "0", ""):
            raise RuntimeError(
                "Faucet not configured. "
                "Set FAUCET_PRIVATE_KEY + FAUCET_ADDRESS (or ORACLE_OWNER_PRIVATE_KEY + "
                "ORACLE_OWNER_ADDRESS) in agents/.env and restart the server."
            )

        _rpc = FullNodeClient(node_url=settings.starknet_rpc_url)
        _account = Account(
            client=_rpc,
            address=int(addr, 16),
            key_pair=KeyPair.from_private_key(int(pk, 16)),
            chain=StarknetChainId.SEPOLIA,
        )
        log.info("faucet.account_ready", address=addr)
        return _account


async def _execute_mint(recipient: str, amount_satoshi: int) -> str:
    """
    Send a 3-call multicall:
      1. oracle.set_price($95k)  — refreshes the timestamp
      2. router.refresh_btc_price()  — syncs the router cache
      3. wbtc.mint(recipient, amount_u256)

    Returns the confirmed transaction hash.
    """
    account = await _get_account()
    [low, high] = _u256_calldata(amount_satoshi)

    calls: list[Call] = [
        Call(
            to_addr=int(MOCK_ORACLE_ADDRESS, 16),
            selector=get_selector_from_name("set_price"),
            calldata=[DEFAULT_BTC_PRICE],
        ),
        Call(
            to_addr=int(BTCSECURITY_ROUTER_ADDR, 16),
            selector=get_selector_from_name("refresh_btc_price"),
            calldata=[],
        ),
        Call(
            to_addr=int(MOCK_WBTC_ADDRESS, 16),
            selector=get_selector_from_name("mint"),
            calldata=[int(recipient, 16), low, high],
        ),
    ]

    log.info("faucet.submitting", recipient=recipient, satoshi=amount_satoshi)
    invocation = await account.execute_v3(calls=calls, auto_estimate=True)
    tx_hash = hex(invocation.transaction_hash)
    log.info("faucet.tx_submitted", tx_hash=tx_hash)

    await _rpc.wait_for_tx(invocation.transaction_hash, check_interval=TX_CHECK_INTERVAL)
    log.info("faucet.tx_accepted", tx_hash=tx_hash)
    return tx_hash


# ── FastAPI app ───────────────────────────────────────────────────────────────

@asynccontextmanager
async def lifespan(_: FastAPI):
    log.info("faucet_server.started", rpc=settings.starknet_rpc_url)
    yield
    log.info("faucet_server.stopping")
    if _rpc is not None:
        await _rpc.close()


app = FastAPI(
    title="BTC Vault Testnet Faucet",
    description="Mint test wBTC on Starknet Sepolia — open to all wallets",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],   # restrict to your frontend origin in production
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)


# ── Request / response models ─────────────────────────────────────────────────

class MintRequest(BaseModel):
    address: str
    amount_satoshi: int = DEFAULT_SATOSHI

    @field_validator("address")
    @classmethod
    def validate_address(cls, v: str) -> str:
        v = v.strip()
        if not v.startswith("0x") or len(v) < 10:
            raise ValueError("Must be a valid hex Starknet address starting with 0x")
        return v.lower()

    @field_validator("amount_satoshi")
    @classmethod
    def validate_amount(cls, v: int) -> int:
        if v <= 0:
            raise ValueError("amount_satoshi must be positive")
        return min(v, MAX_SATOSHI_PER_REQUEST)


class MintResponse(BaseModel):
    tx_hash: str
    recipient: str
    amount_satoshi: int
    amount_btc: float
    message: str


class FaucetStatus(BaseModel):
    status: str
    max_per_request_btc: float
    rate_limit_hours: int
    total_mints_served: int


# ── Endpoints ─────────────────────────────────────────────────────────────────

@app.get("/health")
async def health_check():
    return {"status": "ok"}


@app.post("/oracle/refresh")
async def refresh_oracle():
    """
    Refresh the MockPragmaOracle price and sync the BTCSecurityRouter cache.
    Does NOT mint any tokens — just keeps the oracle timestamp current so
    the router returns a non-zero BTC price.
    """
    try:
        account = await _get_account()
        calls: list[Call] = [
            Call(
                to_addr=int(MOCK_ORACLE_ADDRESS, 16),
                selector=get_selector_from_name("set_price"),
                calldata=[DEFAULT_BTC_PRICE],
            ),
            Call(
                to_addr=int(BTCSECURITY_ROUTER_ADDR, 16),
                selector=get_selector_from_name("refresh_btc_price"),
                calldata=[],
            ),
        ]
        invocation = await account.execute_v3(calls=calls, auto_estimate=True)
        tx_hash = hex(invocation.transaction_hash)
        await _rpc.wait_for_tx(invocation.transaction_hash, check_interval=TX_CHECK_INTERVAL)
        log.info("oracle.refreshed", tx_hash=tx_hash)
        return {"tx_hash": tx_hash, "message": "Oracle price refreshed to $95,000"}
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail={"error": "not_configured", "message": str(exc)})
    except Exception as exc:
        log.error("oracle.refresh_error", error=str(exc))
        raise HTTPException(status_code=500, detail={"error": "refresh_failed", "message": str(exc)[:400]})


@app.get("/faucet/status", response_model=FaucetStatus)
async def faucet_status():
    return FaucetStatus(
        status="operational",
        max_per_request_btc=MAX_SATOSHI_PER_REQUEST / 1e8,
        rate_limit_hours=RATE_LIMIT_HOURS,
        total_mints_served=len(_rate_limits),
    )


@app.post("/faucet/mint", response_model=MintResponse)
async def request_mint(req: MintRequest):
    """
    Mint test wBTC to `address`.

    Rate-limited: one successful mint per address per 24 hours.
    Also refreshes the oracle price and router cache as part of the same tx.
    """
    now = time.time()

    # ── Rate-limit check ──────────────────────────────────────────────────────
    async with _rate_lock:
        last = _rate_limits.get(req.address, 0.0)
        wait = int(RATE_LIMIT_HOURS * 3600 - (now - last))
        if wait > 0:
            h, m = divmod(wait, 3600)
            m //= 60
            raise HTTPException(
                status_code=429,
                detail={
                    "error": "rate_limited",
                    "message": f"Already received wBTC. Try again in {h}h {m}m.",
                    "retry_after_seconds": wait,
                },
            )

    # ── Execute mint ──────────────────────────────────────────────────────────
    try:
        tx_hash = await _execute_mint(req.address, req.amount_satoshi)
    except RuntimeError as exc:
        raise HTTPException(
            status_code=503,
            detail={"error": "not_configured", "message": str(exc)},
        )
    except Exception as exc:
        log.error("faucet.mint_error", address=req.address, error=str(exc))
        raise HTTPException(
            status_code=500,
            detail={"error": "mint_failed", "message": str(exc)[:400]},
        )

    # ── Record rate-limit only after success ──────────────────────────────────
    async with _rate_lock:
        _rate_limits[req.address] = now

    btc = req.amount_satoshi / 1e8
    return MintResponse(
        tx_hash=tx_hash,
        recipient=req.address,
        amount_satoshi=req.amount_satoshi,
        amount_btc=btc,
        message=f"Successfully minted {btc:.4f} wBTC to {req.address[:10]}…",
    )


# ── Standalone entry point ────────────────────────────────────────────────────

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("faucet_server:app", host="0.0.0.0", port=settings.faucet_port, reload=True)
