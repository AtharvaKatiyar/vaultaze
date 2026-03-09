"""
agents/price_keeper.py
──────────────────────
Keeps the BTCSecurityRouter oracle price fresh by calling admin_set_btc_price
on a schedule.

The router's MAX_PRICE_AGE = 3600 seconds.  After 1 hour without a refresh
get_btc_usd_price() returns 0, making is_price_fresh() → false and triggering
the "stale" banner in the frontend.

This script fetches the current BTC/USD spot price (from a public REST API),
converts it to Pragma u256 format (price × 10^8), and calls admin_set_btc_price
on the router.  It repeats every REFRESH_INTERVAL seconds (default 1800 = 30 min).

Usage
─────
    cd /home/mime/Desktop/btc_vault/agents
    source ../.venv/bin/activate
    python price_keeper.py              # run forever (Ctrl-C to stop)
    python price_keeper.py --once       # single refresh, then exit

Environment (loaded from agents/.env)
──────────────────────────────────────
    STARKNET_RPC_URL         – RPC endpoint (default: Blast public)
    STARKNET_NETWORK         – "sepolia" or "mainnet"
    ROUTER_ADDRESS           – deployed BTCSecurityRouter address
    ADMIN_PRIVATE_KEY        – admin/owner private key (has ROLE_ADMIN)
    ADMIN_ADDRESS            – admin/owner account address

    PRICE_KEEPER_INTERVAL    – refresh period in seconds (default: 1800)
    PRICE_KEEPER_BTC_PRICE   – override fixed price in USD cents precision
                               (e.g. "95000" to always push $95,000).
                               Leave unset to fetch live price from CoinGecko.
"""
from __future__ import annotations

import asyncio
import json
import os
import sys
import time
import urllib.request

from starknet_py.net.full_node_client import FullNodeClient
from starknet_py.net.account.account import Account
from starknet_py.net.models.chains import StarknetChainId
from starknet_py.net.signer.stark_curve_signer import KeyPair
from starknet_py.contract import Contract

# ── Load .env ─────────────────────────────────────────────────────────────────
_ENV_PATH = os.path.join(os.path.dirname(__file__), ".env")
_env: dict[str, str] = {}
if os.path.exists(_ENV_PATH):
    with open(_ENV_PATH) as _f:
        for _line in _f:
            _line = _line.strip()
            if _line and not _line.startswith("#") and "=" in _line:
                _k, _, _v = _line.partition("=")
                _env[_k.strip()] = _v.strip()


def _get(key: str, default: str = "") -> str:
    return os.environ.get(key, _env.get(key, default))


# ── Configuration ─────────────────────────────────────────────────────────────
RPC_URL           = _get("STARKNET_RPC_URL", "https://starknet-sepolia.public.blastapi.io")
NETWORK           = _get("STARKNET_NETWORK", "sepolia")
ROUTER_ADDRESS    = _get("ROUTER_ADDRESS")
OWNER_PRIVATE_KEY = _get("ADMIN_PRIVATE_KEY") or _get("ORACLE_OWNER_PRIVATE_KEY")
OWNER_ADDRESS     = _get("ADMIN_ADDRESS")     or _get("ORACLE_OWNER_ADDRESS")

REFRESH_INTERVAL  = int(_get("PRICE_KEEPER_INTERVAL", "1800"))  # 30 min
FIXED_PRICE_USD   = _get("PRICE_KEEPER_BTC_PRICE", "")          # override (optional)

# Pragma u256 scale: price_in_usd * 10^8 = on-chain value
PRAGMA_SCALE = 10 ** 8

if not all([ROUTER_ADDRESS, OWNER_PRIVATE_KEY, OWNER_ADDRESS]):
    print("ERROR: Missing required env vars. Check agents/.env:")
    print(f"  ROUTER_ADDRESS  = {ROUTER_ADDRESS!r}")
    print(f"  ADMIN_ADDRESS   = {OWNER_ADDRESS!r}  (or ORACLE_OWNER_ADDRESS)")
    sys.exit(1)


# ── ABI loader ────────────────────────────────────────────────────────────────
_ARTIFACTS = os.path.join(os.path.dirname(__file__), "..", "vault", "target", "dev")


def load_abi(contract_name: str) -> list[dict]:
    path = os.path.join(_ARTIFACTS, f"vault_{contract_name}.contract_class.json")
    with open(path) as f:
        data = json.load(f)
    raw = data.get("abi", "[]")
    return json.loads(raw) if isinstance(raw, str) else raw


# ── Account factory ───────────────────────────────────────────────────────────
def make_account(rpc: FullNodeClient, address: str, private_key: str, chain: StarknetChainId) -> Account:
    return Account(
        client=rpc,
        address=int(address, 16),
        key_pair=KeyPair.from_private_key(int(private_key, 16)),
        chain=chain,
    )


# ── Price fetcher ─────────────────────────────────────────────────────────────
def fetch_btc_usd_price() -> float:
    """
    Fetch live BTC/USD from CoinGecko simple/price endpoint (no API key needed).
    Falls back to $95,000 if the request fails.
    """
    if FIXED_PRICE_USD:
        return float(FIXED_PRICE_USD)
    try:
        url = "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd"
        req = urllib.request.Request(url, headers={"User-Agent": "btc-vault-price-keeper/1.0"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
        price = float(data["bitcoin"]["usd"])
        return price
    except Exception as exc:
        print(f"  [price_keeper] WARNING: price fetch failed ({exc}), using $95,000 fallback")
        return 95_000.0


def usd_to_pragma(price_usd: float) -> int:
    """Convert a USD float to the Pragma u256 on-chain format (price × 10^8)."""
    return int(price_usd * PRAGMA_SCALE)


# ── Invoke helper ─────────────────────────────────────────────────────────────
async def invoke(contract: Contract, fn_name: str, **kwargs) -> str:
    fn = contract.functions[fn_name]
    inv = await fn.invoke_v3(**kwargs, auto_estimate=True)
    print(f"    → tx {hex(inv.hash)}")
    print("    waiting…", end="", flush=True)
    await inv.wait_for_acceptance()
    print(" ✅")
    return hex(inv.hash)


# ── Single refresh ────────────────────────────────────────────────────────────
async def refresh_price(router: Contract) -> None:
    price_usd   = fetch_btc_usd_price()
    pragma_val  = usd_to_pragma(price_usd)
    print(f"  [price_keeper] BTC/USD = ${price_usd:,.0f}  →  pragma value = {pragma_val}")
    await invoke(router, "admin_set_btc_price", price=pragma_val)


# ── Main loop ─────────────────────────────────────────────────────────────────
async def main() -> None:
    once = "--once" in sys.argv

    chain = StarknetChainId.MAINNET if NETWORK == "mainnet" else StarknetChainId.SEPOLIA
    rpc   = FullNodeClient(node_url=RPC_URL)

    owner = make_account(rpc, OWNER_ADDRESS, OWNER_PRIVATE_KEY, chain)
    router_abi = load_abi("BTCSecurityRouter")
    router = Contract(address=int(ROUTER_ADDRESS, 16), abi=router_abi, provider=owner)

    print(f"[price_keeper] RPC      : {RPC_URL}")
    print(f"[price_keeper] Router   : {ROUTER_ADDRESS}")
    print(f"[price_keeper] Admin    : {OWNER_ADDRESS}")
    print(f"[price_keeper] Interval : {REFRESH_INTERVAL}s ({REFRESH_INTERVAL//60} min)")
    if FIXED_PRICE_USD:
        print(f"[price_keeper] Fixed price override: ${float(FIXED_PRICE_USD):,.0f}")
    print()

    while True:
        ts = time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime())
        print(f"[{ts}] Refreshing BTC price…")
        try:
            await refresh_price(router)
        except Exception as exc:
            print(f"  [price_keeper] ERROR: {exc}")

        if once:
            print("[price_keeper] --once mode, exiting.")
            break

        print(f"[price_keeper] Next refresh in {REFRESH_INTERVAL // 60} minutes.\n")
        await asyncio.sleep(REFRESH_INTERVAL)


if __name__ == "__main__":
    asyncio.run(main())
