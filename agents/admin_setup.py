"""
agents/admin_setup.py
─────────────────────
Bootstrap and fix the BTCSecurityRouter after deployment.

ROOT CAUSE of "Router rejected leverage":
  The router is in SAFE MODE because btc_backing was never set (= 0) but
  btc_exposure became > 0 after the first vault deposit (vault calls
  report_exposure() on every deposit/withdraw/leverage).
  health = btc_backing * 100 / btc_exposure = 0 → auto-triggered safe mode.
  In safe mode, is_operation_allowed() returns false for all non-withdraw ops.

FIX SEQUENCE:
  Step 1 (immediate):
    a. register_protocol(vault, 'vault')     — owner key
    b. update_btc_backing(large_value)       — keeper/owner key (sets health > 130)
    c. queue_operation(exit_safe_mode op)    — owner key (starts 2-day timelock)

  Step 2 (after 2 days, TIMELOCK_DELAY = 172800 seconds):
    d. exit_safe_mode(op_id)                 — owner key

  Pass --exit-safe-mode to run Step 2 (script auto-detects if ready).

Usage
─────
    cd /home/mime/Desktop/btc_vault/agents
    source ../.venv/bin/activate
    python admin_setup.py              # Step 1
    python admin_setup.py --status     # Check state at any time
    python admin_setup.py --exit       # Step 2 (after 2 days)
"""
from __future__ import annotations

import asyncio
import json
import os
import sys
import time

from starknet_py.net.full_node_client import FullNodeClient
from starknet_py.net.account.account import Account
from starknet_py.net.models.chains import StarknetChainId
from starknet_py.net.signer.stark_curve_signer import KeyPair
from starknet_py.contract import Contract

# ── Load .env manually ────────────────────────────────────────────────────────
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
RPC_URL        = _get("STARKNET_RPC_URL", "https://starknet-sepolia.public.blastapi.io")
NETWORK        = _get("STARKNET_NETWORK", "sepolia")
ROUTER_ADDRESS = _get("ROUTER_ADDRESS")
VAULT_ADDRESS  = _get("VAULT_ADDRESS")

# Owner key — the account that deployed the contracts (router's owner)
OWNER_PRIVATE_KEY = _get("ADMIN_PRIVATE_KEY") or _get("ORACLE_OWNER_PRIVATE_KEY")
OWNER_ADDRESS     = _get("ADMIN_ADDRESS")     or _get("ORACLE_OWNER_ADDRESS")

# Keeper key — has ROLE_KEEPER on the router (can call update_btc_backing)
# If not set separately, fall back to owner (owner passes _only_owner_or_role too)
KEEPER_PRIVATE_KEY = _get("RISK_SENTINEL_PRIVATE_KEY") or OWNER_PRIVATE_KEY
KEEPER_ADDRESS     = _get("RISK_SENTINEL_ADDRESS")     or OWNER_ADDRESS

if not all([ROUTER_ADDRESS, VAULT_ADDRESS, OWNER_PRIVATE_KEY, OWNER_ADDRESS]):
    print("ERROR: Missing required env vars. Check agents/.env:")
    print(f"  ROUTER_ADDRESS = {ROUTER_ADDRESS!r}")
    print(f"  VAULT_ADDRESS  = {VAULT_ADDRESS!r}")
    print(f"  OWNER_ADDRESS  = {OWNER_ADDRESS!r} (set via ADMIN_ADDRESS or ORACLE_OWNER_ADDRESS)")
    sys.exit(1)

# ── ABI loader ────────────────────────────────────────────────────────────────
_ARTIFACTS = os.path.join(os.path.dirname(__file__), "..", "vault", "target", "dev")


def load_abi(contract_name: str) -> list[dict]:
    path = os.path.join(_ARTIFACTS, f"vault_{contract_name}.contract_class.json")
    with open(path) as f:
        data = json.load(f)
    raw = data.get("abi", "[]")
    return json.loads(raw) if isinstance(raw, str) else raw


def felt_str(s: str) -> int:
    """Encode a short ASCII string as a Cairo felt252."""
    return int.from_bytes(s.encode("ascii"), "big")


def normalize_addr(addr: str) -> str:
    """Normalize to lowercase hex without leading zeros after 0x."""
    return "0x" + hex(int(addr, 16))[2:].lower()


# ── Account factory ───────────────────────────────────────────────────────────
def make_account(rpc: FullNodeClient, address: str, private_key: str, chain: StarknetChainId) -> Account:
    return Account(
        client=rpc,
        address=int(address, 16),
        key_pair=KeyPair.from_private_key(int(private_key, 16)),
        chain=chain,
    )


# ── Invoke helper ─────────────────────────────────────────────────────────────
async def invoke(contract: Contract, fn_name: str, **kwargs) -> str:
    fn = contract.functions[fn_name]
    inv = await fn.invoke_v3(**kwargs, auto_estimate=True)
    print(f"  → tx {hex(inv.hash)}")
    print("    waiting for acceptance…", end="", flush=True)
    await inv.wait_for_acceptance()
    print(" ✅")
    return hex(inv.hash)


# ── Main ──────────────────────────────────────────────────────────────────────
async def main() -> None:
    mode_exit  = "--exit" in sys.argv
    mode_status = "--status" in sys.argv

    chain = StarknetChainId.MAINNET if NETWORK == "mainnet" else StarknetChainId.SEPOLIA

    print(f"[admin_setup] RPC       : {RPC_URL}")
    print(f"[admin_setup] Owner     : {OWNER_ADDRESS}")
    print(f"[admin_setup] Keeper    : {KEEPER_ADDRESS}")
    print(f"[admin_setup] Router    : {ROUTER_ADDRESS}")
    print(f"[admin_setup] Vault     : {VAULT_ADDRESS}")

    rpc = FullNodeClient(node_url=RPC_URL)

    owner_account  = make_account(rpc, OWNER_ADDRESS,  OWNER_PRIVATE_KEY,  chain)
    keeper_account = make_account(rpc, KEEPER_ADDRESS, KEEPER_PRIVATE_KEY, chain)

    router_abi = load_abi("BTCSecurityRouter")

    router_owner  = Contract(address=int(ROUTER_ADDRESS, 16), abi=router_abi, provider=owner_account)
    router_keeper = Contract(address=int(ROUTER_ADDRESS, 16), abi=router_abi, provider=keeper_account)

    vault_int     = int(VAULT_ADDRESS, 16)
    vault_protocol_type = felt_str("vault")

    # ── 1. Read current state ─────────────────────────────────────────────────
    print("\n─── Current Router State ───")
    try:
        r_owner   = normalize_addr(hex((await router_owner.functions["get_owner"].call())[0]))
        backing   = (await router_owner.functions["get_btc_backing"].call())[0]
        exposure  = (await router_owner.functions["get_btc_exposure"].call())[0]
        health    = (await router_owner.functions["get_btc_health"].call())[0]
        safe_mode = (await router_owner.functions["is_safe_mode"].call())[0]

        # get_max_leverage overflows when exposure=0 (health=u128::MAX) — catch separately
        U128_MAX = (1 << 128) - 1
        try:
            max_lev = (await router_owner.functions["get_max_leverage"].call())[0]
            max_lev_display = f"{max_lev}  ({max_lev / 100:.2f}x)"
        except Exception:
            max_lev = None
            max_lev_display = "OVERFLOW (exposure=0, no deposits yet)"

        health_display = "∞ (no exposure)" if health == U128_MAX else str(health)

        print(f"  router owner   : {r_owner}")
        print(f"  btc_backing    : {backing}")
        print(f"  btc_exposure   : {exposure}")
        print(f"  btc_health     : {health_display}")
        print(f"  max_leverage   : {max_lev_display}")
        print(f"  safe_mode      : {safe_mode}")

        # Check vault registration
        try:
            proto = (await router_owner.functions["get_protocol_info"].call(protocol=vault_int))
            proto_active = proto[0].get("active", False) if isinstance(proto[0], dict) else bool(proto[4])
            print(f"  vault registered: {proto_active}")
        except Exception as e2:
            print(f"  vault registration check: {e2}")

        if normalize_addr(OWNER_ADDRESS) != r_owner:
            print(f"\n⚠  OWNER MISMATCH: using {OWNER_ADDRESS!r} but router owner is {r_owner!r}")
            print("   Set ADMIN_PRIVATE_KEY and ADMIN_ADDRESS in agents/.env to the router owner key.")
    except Exception as e:
        print(f"  ERROR reading state: {e}")
        sys.exit(1)

    if mode_status:
        return

    # ── Step 2: exit_safe_mode (called after 2-day wait) ─────────────────────
    if mode_exit:
        print("\n─── Step 2: Exit Safe Mode ───")
        try:
            op_id_res = await router_owner.functions["hash_operation"].call(
                selector=felt_str("exit_safe_mode"),
                params=[],
            )
            op_id = op_id_res[0]
            print(f"  op_id : {hex(op_id)}")

            eta_res = await router_owner.functions["get_operation_eta"].call(op_id=op_id)
            eta = eta_res[0]
            if eta == 0:
                print("  ❌  Operation not queued. Run without --exit first.")
            else:
                now = int(time.time())
                if now < eta:
                    remaining = eta - now
                    days = remaining // 86400
                    hours = (remaining % 86400) // 3600
                    print(f"  ⏳  Timelock not expired yet. {days}d {hours}h remaining (ETA {eta}).")
                else:
                    health_now = (await router_owner.functions["get_btc_health"].call())[0]
                    if health_now < 130:
                        print(f"  ❌  Health too low ({health_now} < 130). Update btc_backing first.")
                    else:
                        print(f"  Health {health_now} >= 130, calling exit_safe_mode…")
                        await invoke(router_owner, "exit_safe_mode", op_id=op_id)
                        print("  ✅  Safe mode exited! Leverage is now unblocked.")
        except Exception as e:
            print(f"  ❌  {e}")
        return

    # ── Step 1a: Register vault as protocol ───────────────────────────────────
    print("\n─── Step 1a: Register Vault Protocol ───")
    try:
        await invoke(router_owner, "register_protocol",
                     protocol=vault_int,
                     protocol_type=vault_protocol_type)
        print("  Vault registered.")
    except Exception as e:
        if "Protocol already registered" in str(e):
            print("  ℹ  Already registered — skipping.")
        else:
            print(f"  ❌  {e}")
            print("     Check that OWNER_ADDRESS holds the router's owner role.")

    # ── Step 1b: Set btc_backing to healthy level ─────────────────────────────
    print("\n─── Step 1b: Set btc_backing ───")
    # health = backing * 100 / exposure. We need health >= 130 for exit_safe_mode.
    # The contract enforces a +50% max increase per call (rate-of-change guard),
    # so we loop until backing is large enough.
    U128_MAX = (1 << 128) - 1
    health_now = (await router_owner.functions["get_btc_health"].call())[0]
    backing_now = (await router_owner.functions["get_btc_backing"].call())[0]
    exposure_now = (await router_owner.functions["get_btc_exposure"].call())[0]

    if exposure_now == 0:
        target_backing = max(backing_now, 10**8)  # 1 wBTC nominal
    else:
        target_backing = int(exposure_now) * 200 // 100  # health = 200

    if health_now >= 130:
        print(f"  btc_health = {health_now} >= 130, no change needed.")
    elif backing_now == 0:
        print(f"  btc_backing is 0 — setting directly to {target_backing}…")
        try:
            await invoke(router_owner, "update_btc_backing",
                         new_backing={"low": target_backing, "high": 0})
        except Exception as e:
            print(f"  ❌  {e}")
    else:
        print(f"  btc_backing={backing_now}, btc_exposure={exposure_now}, health={health_now}")
        print(f"  Target backing: {target_backing}  (need health >= 130 for exit_safe_mode)")
        print(f"  Ramping up backing in +50% steps (rate-of-change guard)…")
        cur = backing_now
        step = 0
        while cur < target_backing:
            # Each step: max new = old + old//2 (150% of current)
            nxt = min(cur + cur // 2, target_backing)
            if nxt == cur:
                nxt = cur + 1  # avoid infinite loop if cur is very small
            step += 1
            print(f"  Step {step:>2}: {cur} → {nxt}  ", end="", flush=True)
            try:
                fn = router_owner.functions["update_btc_backing"]
                inv = await fn.invoke_v3(
                    new_backing={"low": nxt, "high": 0},
                    auto_estimate=True,
                )
                print(f"tx {hex(inv.hash)} ", end="", flush=True)
                await inv.wait_for_acceptance()
                print("✅")
                cur = nxt
            except Exception as e:
                print(f"\n  ❌  Step {step} failed: {e}")
                break
        health_after = (await router_owner.functions["get_btc_health"].call())[0]
        print(f"  Health after ramp: {'∞' if health_after == U128_MAX else health_after}")

    # ── Step 1c: Queue exit_safe_mode timelock ────────────────────────────────
    print("\n─── Step 1c: Queue exit_safe_mode (2-day timelock) ───")
    try:
        op_id_res = await router_owner.functions["hash_operation"].call(
            selector=felt_str("exit_safe_mode"),
            params=[],
        )
        op_id = op_id_res[0]
        print(f"  op_id : {hex(op_id)}")

        # Check if already queued
        eta_res = await router_owner.functions["get_operation_eta"].call(op_id=op_id)
        existing_eta = eta_res[0]
        if existing_eta != 0:
            now = int(time.time())
            days = max(0, (existing_eta - now)) // 86400
            hours = max(0, (existing_eta - now) % 86400) // 3600
            if now >= existing_eta:
                print(f"  ℹ  Already queued and timelock EXPIRED — run: python admin_setup.py --exit")
            else:
                print(f"  ℹ  Already queued. Timelock expires in {days}d {hours}h.")
                print(f"     ETA timestamp: {existing_eta}")
                print(f"     Then run: python admin_setup.py --exit")
        else:
            TIMELOCK_DELAY = 172_800  # 2 days in seconds
            eta = int(time.time()) + TIMELOCK_DELAY + 60  # +60s buffer
            print(f"  Queueing with ETA = {eta} (2 days from now)…")
            await invoke(router_owner, "queue_operation", op_id=op_id, eta=eta)
            print(f"\n  ⏳  WAIT 2 DAYS, then run:")
            print(f"      python admin_setup.py --exit")
    except Exception as e:
        print(f"  ❌  {e}")

    print("\n[admin_setup] Done.")


if __name__ == "__main__":
    asyncio.run(main())
