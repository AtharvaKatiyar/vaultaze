#!/usr/bin/env python3
"""
finish_deploy.py — complete wiring after a partial redeploy_fresh.py run.

Run when redeploy_fresh.py succeeded for steps 1-3 (declare + deploy) but
failed on step 4+ (register_protocol / role grants) due to rate limiting.

Edit NEW_ROUTER / NEW_VAULT to match the addresses printed by redeploy_fresh.py.
"""
from __future__ import annotations
import asyncio, json, os, re, time

from starknet_py.net.full_node_client import FullNodeClient
from starknet_py.net.account.account import Account
from starknet_py.net.models.chains import StarknetChainId
from starknet_py.net.signer.stark_curve_signer import KeyPair
from starknet_py.contract import Contract

# ── Edit these after each partial deploy ──────────────────────────────────────
NEW_ROUTER = "0x06e077f2b7e5de828c8f43939fddea20937ba01eb95a066ca90c992a094ef8a5"
NEW_VAULT  = "0x06e3335034d25a8de764c0415fc0a6181c6878ee46b2817aec74a9fc1bcb4166"

# Fixed token addresses (unchanged between deploys)
YBTC_TOKEN = "0x03100f429e329e8db8a21d603222459c29326c808a6e4c3ec1dd9003e6854b8a"

# Files to update
AGENTS_DIR   = os.path.dirname(os.path.abspath(__file__))
ARTIFACTS    = os.path.join(AGENTS_DIR, "..", "vault", "target", "dev")
ADDRESSES_TS = os.path.join(AGENTS_DIR, "..", "frontend", "src", "lib", "contracts", "addresses.ts")
AGENTS_ENV   = os.path.join(AGENTS_DIR, ".env")
FRONTEND_ENV = os.path.join(AGENTS_DIR, "..", "frontend", ".env.local")

# ── Load .env ─────────────────────────────────────────────────────────────────
_env: dict[str, str] = {}
with open(os.path.join(AGENTS_DIR, ".env")) as f:
    for line in f:
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, _, v = line.partition("=")
            _env[k.strip()] = v.strip()

def _get(k: str, d: str = "") -> str:
    return os.environ.get(k, _env.get(k, d))

RPC_URL            = _get("STARKNET_RPC_URL", "https://starknet-sepolia.public.blastapi.io")
NETWORK            = _get("STARKNET_NETWORK", "sepolia")
OWNER_PRIVATE_KEY  = _get("ADMIN_PRIVATE_KEY") or _get("ORACLE_OWNER_PRIVATE_KEY")
OWNER_ADDRESS      = _get("ADMIN_ADDRESS")     or _get("ORACLE_OWNER_ADDRESS")
SENTINEL_ADDRESS   = _get("RISK_SENTINEL_ADDRESS",  "0x0")
REBALANCER_ADDRESS = _get("REBALANCER_ADDRESS", "0x0")
GUARDIAN_ADDRESS   = _get("GUARDIAN_ADDRESS",   "0x0")

def load_abi(name: str) -> list:
    path = os.path.join(ARTIFACTS, f"vault_{name}.contract_class.json")
    with open(path) as f:
        d = json.load(f)
    raw = d.get("abi", "[]")
    return json.loads(raw) if isinstance(raw, str) else raw

def felt_str(s: str) -> int:
    return int.from_bytes(s.encode("ascii"), "big")

def update_ts_address(path: str, key: str, value: str) -> None:
    with open(path) as f:
        content = f.read()
    pattern = rf'({re.escape(key)}:\s*")[^"]+(")'
    content = re.sub(pattern, rf'\g<1>{value}\g<2>', content)
    with open(path, "w") as f:
        f.write(content)

def update_env_key(path: str, key: str, value: str) -> None:
    with open(path) as f:
        content = f.read()
    pattern = rf"^{re.escape(key)}\s*=.*$"
    if re.search(pattern, content, re.MULTILINE):
        content = re.sub(pattern, f"{key}={value}", content, flags=re.MULTILINE)
    else:
        content += f"\n{key}={value}\n"
    with open(path, "w") as f:
        f.write(content)

async def invoke_fn(contract: Contract, fn: str, **kwargs) -> str:
    """Invoke with a small delay to avoid rate limiting."""
    time.sleep(1)
    inv = await contract.functions[fn].invoke_v3(**kwargs, auto_estimate=True)
    print(f"    tx {hex(inv.hash)}", end="", flush=True)
    await inv.wait_for_acceptance()
    print(" ✅")
    return hex(inv.hash)

async def main() -> None:
    chain = StarknetChainId.MAINNET if NETWORK == "mainnet" else StarknetChainId.SEPOLIA
    rpc   = FullNodeClient(node_url=RPC_URL)
    owner = Account(
        client=rpc,
        address=int(OWNER_ADDRESS, 16),
        key_pair=KeyPair.from_private_key(int(OWNER_PRIVATE_KEY, 16)),
        chain=chain,
    )

    print("=" * 60)
    print("  finish_deploy — completing contract wiring")
    print("=" * 60)
    print(f"  New Router : {NEW_ROUTER}")
    print(f"  New Vault  : {NEW_VAULT}")

    router_abi = load_abi("BTCSecurityRouter")
    vault_abi  = load_abi("BTCVault")
    ybtc_abi   = load_abi("YBTCToken")

    router = Contract(address=int(NEW_ROUTER, 16), abi=router_abi, provider=owner)
    vault  = Contract(address=int(NEW_VAULT,  16), abi=vault_abi,  provider=owner)
    ybtc   = Contract(address=int(YBTC_TOKEN, 16), abi=ybtc_abi,   provider=owner)

    vault_int = int(NEW_VAULT, 16)

    # ── 4. Register vault in router ──────────────────────────────────────────
    print("\n─── 4. Register vault in router ───")
    try:
        print("  register_protocol…", end=" ")
        await invoke_fn(router, "register_protocol",
                        protocol=vault_int,
                        protocol_type=felt_str("vault"))
    except Exception as e:
        if "already registered" in str(e).lower():
            print("  ⚠  already registered — skipping")
        else:
            raise

    # ── 5. Set initial btc_backing ───────────────────────────────────────────
    # 200 trillion satoshis = 2 million BTC — effectively infinite for test use.
    # First call from 0 is unconstrained by the ±50% rate-of-change guard.
    INITIAL_BACKING = 200_000_000_000_000
    print(f"\n─── 5. Set btc_backing = {INITIAL_BACKING:,} sats ───")
    print(f"  update_btc_backing…", end=" ")
    await invoke_fn(router, "update_btc_backing",
                    new_backing={"low": INITIAL_BACKING, "high": 0})

    # Verify router state
    U128_MAX = (1 << 128) - 1
    health  = (await router.functions["get_btc_health"].call())[0]
    safe    = (await router.functions["is_safe_mode"].call())[0]
    maxlev  = (await router.functions["get_max_leverage"].call())[0]
    backing = (await router.functions["get_btc_backing"].call())[0]
    print(f"  btc_backing={backing:,}  health={('∞' if health == U128_MAX else health)}"
          f"  max_leverage={maxlev/100:.2f}x  safe_mode={safe}")
    assert not safe, "safe_mode is True after backing update — something is wrong"

    # ── 6. Transfer yBTC vault address to new vault ──────────────────────────
    print("\n─── 6. Update yBTC vault address → new vault ───")
    print("  set_vault_address…", end=" ")
    await invoke_fn(ybtc, "set_vault_address", new_vault=vault_int)

    # ── 7. Grant agent roles on Router ──────────────────────────────────────
    print("\n─── 7. Grant agent roles (Router) ───")
    sentinel_int   = int(SENTINEL_ADDRESS,   16) if SENTINEL_ADDRESS   != "0x0" else None
    rebalancer_int = int(REBALANCER_ADDRESS, 16) if REBALANCER_ADDRESS != "0x0" else None
    guardian_int   = int(GUARDIAN_ADDRESS,   16) if GUARDIAN_ADDRESS   != "0x0" else None

    ROLE_GUARDIAN = felt_str("ROLE_GUARDIAN")
    ROLE_KEEPER   = felt_str("ROLE_KEEPER")

    if sentinel_int:
        print("  grant ROLE_GUARDIAN → sentinel…", end=" ")
        await invoke_fn(router, "grant_role", role=ROLE_GUARDIAN, account=sentinel_int)
    if rebalancer_int:
        print("  grant ROLE_KEEPER → rebalancer…", end=" ")
        await invoke_fn(router, "grant_role", role=ROLE_KEEPER, account=rebalancer_int)
    if guardian_int:
        print("  grant ROLE_GUARDIAN → guardian…", end=" ")
        await invoke_fn(router, "grant_role", role=ROLE_GUARDIAN, account=guardian_int)

    # ── 8. Grant agent roles on Vault ────────────────────────────────────────
    print("\n─── 8. Grant agent roles (Vault) ───")
    ROLE_LIQUIDATOR = felt_str("ROLE_LIQUIDATOR")
    if sentinel_int:
        print("  grant ROLE_KEEPER → sentinel (vault)…", end=" ")
        await invoke_fn(vault, "grant_role", role=ROLE_KEEPER, account=sentinel_int)
    if guardian_int:
        print("  grant ROLE_LIQUIDATOR → guardian (vault)…", end=" ")
        await invoke_fn(vault, "grant_role", role=ROLE_LIQUIDATOR, account=guardian_int)

    # ── 9. Update address files ──────────────────────────────────────────────
    print("\n─── 9. Updating address files ───")

    # addresses.ts
    for key, val in [("BTCVault", NEW_VAULT), ("BTCSecurityRouter", NEW_ROUTER)]:
        update_ts_address(ADDRESSES_TS, key, val)
    print(f"  ✅ {ADDRESSES_TS}")

    # agents/.env
    update_env_key(AGENTS_ENV, "ROUTER_ADDRESS", NEW_ROUTER)
    update_env_key(AGENTS_ENV, "VAULT_ADDRESS",  NEW_VAULT)
    print(f"  ✅ {AGENTS_ENV}")

    # frontend/.env.local
    update_env_key(FRONTEND_ENV, "NEXT_PUBLIC_VAULT_ADDRESS",  NEW_VAULT)
    update_env_key(FRONTEND_ENV, "NEXT_PUBLIC_ROUTER_ADDRESS", NEW_ROUTER)
    print(f"  ✅ {FRONTEND_ENV}")

    # faucet_server.py
    faucet_path = os.path.join(AGENTS_DIR, "faucet_server.py")
    with open(faucet_path) as f:
        faucet = f.read()
    faucet = re.sub(
        r'(BTCSECURITY_ROUTER_ADDR\s*=\s*")[^"]+(")',
        rf'\g<1>{NEW_ROUTER}\g<2>',
        faucet,
    )
    with open(faucet_path, "w") as f:
        f.write(faucet)
    print(f"  ✅ {faucet_path}")

    # dashboard display strings
    dash_path = os.path.join(AGENTS_DIR, "..", "frontend", "src", "app", "dashboard", "page.tsx")
    vault_short  = f"0x{NEW_VAULT[2:6]}…{NEW_VAULT[-3:]}"
    router_short = f"0x{NEW_ROUTER[2:6]}…{NEW_ROUTER[-3:]}"
    with open(dash_path) as f:
        dash = f.read()
    dash = re.sub(r'(BTCVault.*?addr:\s*")([^"]+)(")', rf'\g<1>{vault_short}\g<3>', dash)
    dash = re.sub(r'(BTCSecurityRouter.*?addr:\s*")([^"]+)(")', rf'\g<1>{router_short}\g<3>', dash)
    with open(dash_path, "w") as f:
        f.write(dash)
    print(f"  ✅ {dash_path}")

    print("\n" + "=" * 60)
    print("  ✅  All done!")
    print(f"  New Router : {NEW_ROUTER}")
    print(f"  New Vault  : {NEW_VAULT}")
    print("\n  Restart the frontend dev server and faucet server.")
    print("=" * 60)


if __name__ == "__main__":
    asyncio.run(main())
