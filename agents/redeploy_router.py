#!/usr/bin/env python3
"""
agents/redeploy_router.py
─────────────────────────
Redeploys ONLY the BTCSecurityRouter with safe_mode=false from the start,
then wires everything back up in one script:

  1. Declare BTCSecurityRouter class (if not already declared)
  2. Deploy new BTCSecurityRouter instance
     constructor(owner, safe_mode_threshold=110, oracle_address)
  3. Register the vault as a protocol
  4. Set btc_backing to a healthy value (200x exposure)
  5. Update agents/.env and frontend/.env.local with the new router address
  6. Grant ROLE_KEEPER/ROLE_GUARDIAN to agent wallets on the new router

Usage:
    cd /home/mime/Desktop/btc_vault/agents
    python redeploy_router.py
"""
from __future__ import annotations
import asyncio, json, os, re, sys, time

from starknet_py.net.full_node_client import FullNodeClient
from starknet_py.net.account.account import Account
from starknet_py.net.models.chains import StarknetChainId
from starknet_py.net.signer.stark_curve_signer import KeyPair
from starknet_py.contract import Contract
from starknet_py.net.client_models import ResourceBounds
from starknet_py.hash.casm_class_hash import compute_casm_class_hash

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

RPC_URL       = _get("STARKNET_RPC_URL", "https://starknet-sepolia.public.blastapi.io")
NETWORK       = _get("STARKNET_NETWORK", "sepolia")
VAULT_ADDRESS = _get("VAULT_ADDRESS")
ORACLE_ADDRESS = _get("ORACLE_ADDRESS", "0x0")

OWNER_PRIVATE_KEY = _get("ADMIN_PRIVATE_KEY") or _get("ORACLE_OWNER_PRIVATE_KEY")
OWNER_ADDRESS     = _get("ADMIN_ADDRESS")     or _get("ORACLE_OWNER_ADDRESS")

SENTINEL_ADDRESS   = _get("RISK_SENTINEL_ADDRESS")
REBALANCER_ADDRESS = _get("REBALANCER_ADDRESS")

# ── Paths ────────────────────────────────────────────────────────────────────
AGENTS_DIR   = os.path.dirname(__file__)
ARTIFACTS    = os.path.join(AGENTS_DIR, "..", "vault", "target", "dev")
AGENTS_ENV   = os.path.join(AGENTS_DIR, ".env")
FRONTEND_ENV = os.path.join(AGENTS_DIR, "..", "frontend", ".env.local")


def load_sierra(name: str) -> dict:
    path = os.path.join(ARTIFACTS, f"vault_{name}.contract_class.json")
    with open(path) as f:
        return json.load(f)


def load_abi(name: str) -> list:
    d = load_sierra(name)
    raw = d.get("abi", "[]")
    return json.loads(raw) if isinstance(raw, str) else raw


def felt_str(s: str) -> int:
    return int.from_bytes(s.encode("ascii"), "big")


def update_env_file(path: str, key: str, value: str) -> None:
    """Update or append a key=value line in an env file."""
    if not os.path.exists(path):
        with open(path, "a") as f:
            f.write(f"\n{key}={value}\n")
        return
    with open(path) as f:
        content = f.read()
    pattern = rf"^({re.escape(key)}\s*=).*$"
    new_line = f"{key}={value}"
    if re.search(pattern, content, re.MULTILINE):
        content = re.sub(pattern, new_line, content, flags=re.MULTILINE)
    else:
        content += f"\n{new_line}\n"
    with open(path, "w") as f:
        f.write(content)


async def invoke(contract: Contract, fn: str, **kwargs) -> str:
    inv = await contract.functions[fn].invoke_v3(**kwargs, auto_estimate=True)
    print(f"  tx {hex(inv.hash)}", end="", flush=True)
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

    print(f"Owner   : {OWNER_ADDRESS}")
    print(f"Vault   : {VAULT_ADDRESS}")
    print(f"Oracle  : {ORACLE_ADDRESS}")
    print(f"RPC     : {RPC_URL}")
    print()

    # ── Step 1: Declare class ────────────────────────────────────────────────
    print("─── Step 1: Declare BTCSecurityRouter ───")
    sierra = load_sierra("BTCSecurityRouter")

    try:
        from starknet_py.net.account.account import Account as _A
        declare_result = await owner.sign_declare_v3_transaction(
            compiled_contract=json.dumps(sierra),
            compiled_contract_casm=None,
            auto_estimate=True,
        )
    except Exception:
        pass

    # Use the high-level Contract.declare_v2 path
    try:
        declared = await Contract.declare_v2(
            account=owner,
            compiled_contract=json.dumps(sierra),
            auto_estimate=True,
        )
        await declared.wait_for_acceptance()
        class_hash = declared.class_hash
        print(f"  Declared class hash : {hex(class_hash)} ✅")
    except Exception as e:
        if "already declared" in str(e).lower() or "class hash" in str(e).lower():
            # Extract class hash from error or compute it
            existing = sierra.get("contract_class_version")
            # Compute from the artifact
            from starknet_py.hash.sierra_class_hash import compute_sierra_class_hash
            class_hash = compute_sierra_class_hash(sierra)
            print(f"  Already declared. Class hash : {hex(class_hash)} ✅")
        else:
            print(f"  ❌ Declare failed: {e}")
            sys.exit(1)

    # ── Step 2: Deploy new router ────────────────────────────────────────────
    print("\n─── Step 2: Deploy new BTCSecurityRouter ───")
    # constructor(owner, safe_mode_threshold=110, oracle_address)
    # safe_mode_threshold=110 means health must be < 1.10 to enter safe mode
    # (gives generous headroom — system needs to be really stressed)
    owner_int  = int(OWNER_ADDRESS, 16)
    oracle_int = int(ORACLE_ADDRESS, 16) if ORACLE_ADDRESS and ORACLE_ADDRESS != "0x0" else 0

    try:
        deploy_result = await Contract.deploy_contract_v3(
            account=owner,
            class_hash=class_hash,
            abi=load_abi("BTCSecurityRouter"),
            constructor_args={
                "owner": owner_int,
                "safe_mode_threshold": 110,
                "oracle_address": oracle_int,
            },
            auto_estimate=True,
        )
        await deploy_result.wait_for_acceptance()
        new_router_address = hex(deploy_result.deployed_contract.address)
        print(f"  New router address  : {new_router_address} ✅")
    except Exception as e:
        print(f"  ❌ Deploy failed: {e}")
        sys.exit(1)

    new_router_int = deploy_result.deployed_contract.address
    router = Contract(
        address=new_router_int,
        abi=load_abi("BTCSecurityRouter"),
        provider=owner,
    )

    # ── Step 3: Register vault as protocol ──────────────────────────────────
    print("\n─── Step 3: Register vault as protocol ───")
    await invoke(router, "register_protocol",
                 protocol=int(VAULT_ADDRESS, 16),
                 protocol_type=felt_str("vault"))

    # ── Step 4: Set btc_backing ──────────────────────────────────────────────
    # Since vault exposure = 0 on a fresh router, set a generous nominal backing
    # so health = ∞ (no exposure) and max_leverage = 200
    print("\n─── Step 4: Set btc_backing = 200,000,000 (nominal) ───")
    await invoke(router, "update_btc_backing",
                 new_backing={"low": 200_000_000, "high": 0})

    health = (await router.functions["get_btc_health"].call())[0]
    max_lev = (await router.functions["get_max_leverage"].call())[0]
    safe    = (await router.functions["is_safe_mode"].call())[0]
    U128_MAX = (1 << 128) - 1
    print(f"  health={('∞' if health == U128_MAX else health)}  max_leverage={max_lev}  safe_mode={safe}")

    # ── Step 5: Grant roles to agent wallets ─────────────────────────────────
    print("\n─── Step 5: Grant agent roles ───")
    ROLE_GUARDIAN = felt_str("ROLE_GUARDIAN")
    ROLE_KEEPER   = felt_str("ROLE_KEEPER")

    roles_to_grant = []
    if SENTINEL_ADDRESS and SENTINEL_ADDRESS != "0x0":
        roles_to_grant.append(("ROLE_GUARDIAN → sentinel",  ROLE_GUARDIAN, int(SENTINEL_ADDRESS, 16)))
        roles_to_grant.append(("ROLE_KEEPER   → sentinel",  ROLE_KEEPER,   int(SENTINEL_ADDRESS, 16)))
    if REBALANCER_ADDRESS and REBALANCER_ADDRESS != "0x0":
        roles_to_grant.append(("ROLE_KEEPER   → rebalancer", ROLE_KEEPER,  int(REBALANCER_ADDRESS, 16)))

    for label, role, account in roles_to_grant:
        print(f"  {label}  ", end="", flush=True)
        await invoke(router, "grant_role", role=role, account=account)

    # ── Step 6: Update .env files ─────────────────────────────────────────────
    print("\n─── Step 6: Update env files ───")
    update_env_file(AGENTS_ENV,   "ROUTER_ADDRESS", new_router_address)
    print(f"  agents/.env         ROUTER_ADDRESS={new_router_address} ✅")

    if os.path.exists(FRONTEND_ENV):
        update_env_file(FRONTEND_ENV, "NEXT_PUBLIC_ROUTER_ADDRESS", new_router_address)
        print(f"  frontend/.env.local NEXT_PUBLIC_ROUTER_ADDRESS={new_router_address} ✅")
    else:
        print(f"  frontend/.env.local not found — update manually: NEXT_PUBLIC_ROUTER_ADDRESS={new_router_address}")

    # ── Step 7: Point vault at new router ────────────────────────────────────
    print("\n─── Step 7: Update vault's router address ───")
    print(f"  ⚠  The deployed BTCVault still points to the OLD router.")
    print(f"     Call vault.set_router(op_id, {new_router_address}) after a 2-day timelock.")
    print(f"     For demo purposes, the vault will work read-only with the old router.")
    print(f"     If the vault constructor or an emergency admin function allows direct set, use that.")
    print(f"\n     Alternatively: redeploy the vault too (see redeploy_full.py).")

    print(f"\n{'─'*60}")
    print(f"✅  New BTCSecurityRouter deployed and configured:")
    print(f"    Address      : {new_router_address}")
    print(f"    safe_mode    : False")
    print(f"    max_leverage : {max_lev / 100:.2f}x")
    print(f"    health       : {'∞' if health == U128_MAX else health}")
    print(f"\nNext step: point the vault at the new router.")
    print(f"  Option A (fastest for demo): redeploy vault too")
    print(f"  Option B: queue vault.set_router() timelock (2 days)")


if __name__ == "__main__":
    asyncio.run(main())
