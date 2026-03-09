#!/usr/bin/env python3
"""
agents/redeploy_fresh.py
─────────────────────────────
Full redeploy of BTCSecurityRouter + BTCVault with safe_mode disabled.

Keeps wBTC and yBTC token contracts — only the vault logic + router are redeployed.
yBTC must have its minter/vault address updated to the new vault.

Steps:
  1.  Deploy new BTCSecurityRouter (safe_mode=false, btc_backing pre-set)
  2.  Deploy new BTCVault pointing at the new router
  3.  Register new vault in new router
  4.  Set btc_backing = 200,000,000
  5.  Transfer yBTC minter role to new vault
  6.  Grant agent roles (KEEPER/GUARDIAN) on new router
  7.  Grant KEEPER/LIQUIDATOR on new vault
  8.  Update frontend/src/lib/contracts/addresses.ts
  9.  Update agents/.env

Usage:
    cd /home/mime/Desktop/btc_vault/agents
    python redeploy_fresh.py
"""
from __future__ import annotations
import asyncio, json, os, re, sys

from starknet_py.net.full_node_client import FullNodeClient
from starknet_py.net.account.account import Account
from starknet_py.net.models.chains import StarknetChainId
from starknet_py.net.signer.stark_curve_signer import KeyPair
from starknet_py.contract import Contract

# ── Load .env ────────────────────────────────────────────────────────────────
_ENV = os.path.join(os.path.dirname(__file__), ".env")
_env: dict[str, str] = {}
with open(_ENV) as f:
    for line in f:
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, _, v = line.partition("=")
            _env[k.strip()] = v.strip()

def _get(k: str, d: str = "") -> str:
    return os.environ.get(k, _env.get(k, d))

RPC_URL            = _get("STARKNET_RPC_URL", "https://starknet-sepolia.public.blastapi.io")
NETWORK            = _get("STARKNET_NETWORK", "sepolia")
ORACLE_ADDRESS     = _get("ORACLE_ADDRESS", "0x0")
OWNER_PRIVATE_KEY  = _get("ADMIN_PRIVATE_KEY") or _get("ORACLE_OWNER_PRIVATE_KEY")
OWNER_ADDRESS      = _get("ADMIN_ADDRESS")     or _get("ORACLE_OWNER_ADDRESS")
SENTINEL_ADDRESS   = _get("RISK_SENTINEL_ADDRESS",  "0x0")
REBALANCER_ADDRESS = _get("REBALANCER_ADDRESS", "0x0")
GUARDIAN_ADDRESS   = _get("GUARDIAN_ADDRESS",   "0x0")

# Fixed token addresses (reuse existing deployments)
MOCK_WBTC  = "0x0129f01b63b9eb403e07c9da8e69e2bed648a5fbc81fddb0b27768ee323bf446"
YBTC_TOKEN = "0x03100f429e329e8db8a21d603222459c29326c808a6e4c3ec1dd9003e6854b8a"
USDC_ADDR  = "0x0"   # zero = usdc not wired (vault accepts it as optional)

AGENTS_DIR   = os.path.dirname(os.path.abspath(__file__))
ARTIFACTS    = os.path.join(AGENTS_DIR, "..", "vault", "target", "dev")
ADDRESSES_TS = os.path.join(AGENTS_DIR, "..", "frontend", "src", "lib", "contracts", "addresses.ts")
AGENTS_ENV   = os.path.join(AGENTS_DIR, ".env")


# ── Helpers ───────────────────────────────────────────────────────────────────
def load_sierra(name: str) -> dict:
    with open(os.path.join(ARTIFACTS, f"vault_{name}.contract_class.json")) as f:
        return json.load(f)

def load_casm(name: str) -> dict:
    with open(os.path.join(ARTIFACTS, f"vault_{name}.compiled_contract_class.json")) as f:
        return json.load(f)

def load_abi(name: str) -> list:
    d = load_sierra(name)
    raw = d.get("abi", "[]")
    return json.loads(raw) if isinstance(raw, str) else raw

def felt_str(s: str) -> int:
    return int.from_bytes(s.encode("ascii"), "big")

def hex40(n: int) -> str:
    return "0x" + format(n, "064x")

def update_ts_address(path: str, key: str, value: str) -> None:
    with open(path) as f:
        content = f.read()
    pattern = rf'({re.escape(key)}:\s*")[^"]+(")'
    content = re.sub(pattern, rf'\g<1>{value}\g<2>', content)
    with open(path, "w") as f:
        f.write(content)

def update_env(path: str, key: str, value: str) -> None:
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
    inv = await contract.functions[fn].invoke_v3(**kwargs, auto_estimate=True)
    print(f"    tx {hex(inv.hash)}", end="", flush=True)
    await inv.wait_for_acceptance()
    print(" ✅")
    return hex(inv.hash)

async def declare(account: Account, name: str) -> int:
    sierra = load_sierra(name)
    casm   = load_casm(name)
    print(f"  Declaring {name}…", end="", flush=True)
    try:
        result = await Contract.declare_v3(
            account=account,
            compiled_contract=json.dumps(sierra),
            compiled_contract_casm=json.dumps(casm),
            auto_estimate=True,
        )
        await result.wait_for_acceptance()
        class_hash = result.class_hash
        print(f" class_hash={hex(class_hash)} ✅")
        return class_hash
    except Exception as e:
        err = str(e)
        if "already declared" in err.lower() or "class hash already declared" in err.lower():
            try:
                from starknet_py.hash.sierra_class_hash import compute_sierra_class_hash
                class_hash = compute_sierra_class_hash(sierra)
                print(f" already declared. class_hash={hex(class_hash)} ✅")
                return class_hash
            except Exception:
                pass
        m = re.search(r"0x[0-9a-f]{10,}", err)
        if m:
            class_hash = int(m.group(), 16)
            print(f" already declared. class_hash={hex(class_hash)} ✅")
            return class_hash
        print(f" ❌\n  {e}")
        raise


async def deploy(account: Account, class_hash: int, abi: list, name: str, **constructor_args) -> Contract:
    print(f"  Deploying {name}…", end="", flush=True)
    result = await Contract.deploy_contract_v3(
        account=account,
        class_hash=class_hash,
        abi=abi,
        constructor_args=constructor_args,
        auto_estimate=True,
    )
    await result.wait_for_acceptance()
    addr = hex(result.deployed_contract.address)
    print(f" address={addr} ✅")
    return result.deployed_contract


# ── Main ──────────────────────────────────────────────────────────────────────
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
    print("  BTC Vault — Full Redeploy (clean state)")
    print("=" * 60)
    print(f"  Owner    : {OWNER_ADDRESS}")
    print(f"  Oracle   : {ORACLE_ADDRESS}")
    print(f"  wBTC     : {MOCK_WBTC}  (reused)")
    print(f"  yBTC     : {YBTC_TOKEN}  (reused)")
    print()

    # ── 1. Declare classes ───────────────────────────────────────────────────
    print("─── 1. Declare contract classes ───")
    router_class = await declare(owner, "BTCSecurityRouter")
    vault_class  = await declare(owner, "BTCVault")

    # ── 2. Deploy Router ─────────────────────────────────────────────────────
    print("\n─── 2. Deploy BTCSecurityRouter ───")
    oracle_int = int(ORACLE_ADDRESS, 16) if ORACLE_ADDRESS and ORACLE_ADDRESS != "0x0" else 0
    router_contract = await deploy(
        owner, router_class, load_abi("BTCSecurityRouter"), "BTCSecurityRouter",
        owner=int(OWNER_ADDRESS, 16),
        safe_mode_threshold=110,   # health must be < 1.10 before safe mode triggers
        oracle_address=oracle_int,
    )
    ROUTER_NEW = hex(router_contract.address)
    router = Contract(address=router_contract.address, abi=load_abi("BTCSecurityRouter"), provider=owner)

    # ── 3. Deploy Vault ──────────────────────────────────────────────────────
    print("\n─── 3. Deploy BTCVault ───")
    vault_contract = await deploy(
        owner, vault_class, load_abi("BTCVault"), "BTCVault",
        owner=int(OWNER_ADDRESS, 16),
        wbtc_address=int(MOCK_WBTC, 16),
        ybtc_address=int(YBTC_TOKEN, 16),
        usdc_address=0,   # zero address accepted
        router_address=router_contract.address,
    )
    VAULT_NEW = hex(vault_contract.address)
    vault = Contract(address=vault_contract.address, abi=load_abi("BTCVault"), provider=owner)

    # ── 4. Register vault in router ──────────────────────────────────────────
    print("\n─── 4. Register vault in router ───")
    print("  register_protocol…", end=" ")
    await invoke_fn(router, "register_protocol",
                    protocol=vault_contract.address,
                    protocol_type=felt_str("vault"))

    # ── 5. Set initial btc_backing ───────────────────────────────────────────
    # Use a large value (200 trillion satoshis = 2 million BTC).
    # The FIRST call from 0 is unconstrained by the ±50% rate-of-change guard,
    # so we can jump straight to any value here.
    # With safe_mode_threshold=110, safe mode triggers when:
    #   btc_exposure > btc_backing * 100/110 ≈ 181.8T satoshis ≈ 1.8M BTC
    # This gives essentially unlimited headroom for test deposits.
    INITIAL_BTC_BACKING = 200_000_000_000_000   # 200 trillion sats = 2M BTC
    print(f"\n─── 5. Set btc_backing = {INITIAL_BTC_BACKING:,} sats ───")
    print(f"  update_btc_backing({INITIAL_BTC_BACKING})…", end=" ")
    await invoke_fn(router, "update_btc_backing",
                    new_backing={"low": INITIAL_BTC_BACKING, "high": 0})

    U128_MAX = (1 << 128) - 1
    health  = (await router.functions["get_btc_health"].call())[0]
    safe    = (await router.functions["is_safe_mode"].call())[0]
    maxlev = (await router.functions["get_max_leverage"].call())[0]
    maxlev_str = f"{maxlev/100:.2f}x"
    print(f"  health={('∞ (no deposits yet)' if health == U128_MAX else health)}  max_leverage={maxlev_str}  safe_mode={safe}")

    # ── 6. Transfer yBTC vault address to new vault ──────────────────────────
    print("\n─── 6. Update yBTC vault address → new vault ───")
    ybtc_abi = load_abi("YBTCToken")
    ybtc = Contract(address=int(YBTC_TOKEN, 16), abi=ybtc_abi, provider=owner)
    print("  set_vault_address(new_vault)…", end=" ")
    await invoke_fn(ybtc, "set_vault_address", new_vault=vault_contract.address)

    # ── 7. Grant agent roles on Router ──────────────────────────────────────
    print("\n─── 7. Grant agent roles (Router) ───")
    ROLE_GUARDIAN = felt_str("ROLE_GUARDIAN")
    ROLE_KEEPER   = felt_str("ROLE_KEEPER")

    for label, role, addr_str in [
        ("GUARDIAN → sentinel",   ROLE_GUARDIAN, SENTINEL_ADDRESS),
        ("KEEPER   → sentinel",   ROLE_KEEPER,   SENTINEL_ADDRESS),
        ("KEEPER   → rebalancer", ROLE_KEEPER,   REBALANCER_ADDRESS),
    ]:
        if addr_str and addr_str not in ("0x0", ""):
            print(f"  grant {label}…", end=" ")
            await invoke_fn(router, "grant_role", role=role, account=int(addr_str, 16))

    # ── 8. Grant agent roles on Vault ───────────────────────────────────────
    print("\n─── 8. Grant agent roles (Vault) ───")
    ROLE_LIQUIDATOR = felt_str("ROLE_LIQUIDATOR")
    for label, role, addr_str in [
        ("KEEPER      → rebalancer", ROLE_KEEPER,    REBALANCER_ADDRESS),
        ("LIQUIDATOR  → guardian",   ROLE_LIQUIDATOR, GUARDIAN_ADDRESS),
    ]:
        if addr_str and addr_str not in ("0x0", ""):
            print(f"  grant {label}…", end=" ")
            await invoke_fn(vault, "grant_role", role=role, account=int(addr_str, 16))

    # ── 9. Update addresses.ts ───────────────────────────────────────────────
    print("\n─── 9. Update frontend/src/lib/contracts/addresses.ts ───")
    with open(ADDRESSES_TS) as f:
        ts = f.read()
    # Update CONTRACTS object values
    ts = re.sub(r'(BTCSecurityRouter:\s*")[^"]+(")', rf'\g<1>{ROUTER_NEW}\g<2>', ts)
    ts = re.sub(r'(BTCVault:\s*")[^"]+(")', rf'\g<1>{VAULT_NEW}\g<2>', ts)
    # Update EXPLORERS object values (voyager URLs containing the old addresses)
    OLD_ROUTER = "0x079c852ec6c79d011a42eba2b0de16f13b9e35bdc42facf073ea2f7ffc579fc0"
    OLD_VAULT  = "0x04f3f2276f3c8e1d20296c0cf95329211fd22caa58898caf298c79160c281cdc"
    ts = ts.replace(OLD_ROUTER, ROUTER_NEW)
    ts = ts.replace(OLD_VAULT,  VAULT_NEW)
    with open(ADDRESSES_TS, "w") as f:
        f.write(ts)
    print(f"  BTCSecurityRouter = {ROUTER_NEW} ✅")
    print(f"  BTCVault          = {VAULT_NEW} ✅")

    # ── 10. Update agents/.env ────────────────────────────────────────────────
    print("\n─── 10. Update agents/.env ───")
    update_env(AGENTS_ENV, "ROUTER_ADDRESS", ROUTER_NEW)
    update_env(AGENTS_ENV, "VAULT_ADDRESS",  VAULT_NEW)
    print(f"  ROUTER_ADDRESS={ROUTER_NEW} ✅")
    print(f"  VAULT_ADDRESS={VAULT_NEW} ✅")

    # ── Summary ───────────────────────────────────────────────────────────────
    print()
    print("=" * 60)
    print("  DEPLOYMENT COMPLETE ✅")
    print("=" * 60)
    print(f"  Router  : {ROUTER_NEW}")
    print(f"  Vault   : {VAULT_NEW}")
    print(f"  wBTC    : {MOCK_WBTC}  (unchanged)")
    print(f"  yBTC    : {YBTC_TOKEN}  (unchanged)")
    print(f"  Health  : {'∞' if health == U128_MAX else health}")
    print(f"  MaxLev  : {maxlev_str}")
    print(f"  SafeMode: {safe}  ← should be False")
    print()
    print("  Next: restart the frontend dev server")
    print("    cd frontend && npm run dev")


if __name__ == "__main__":
    asyncio.run(main())
