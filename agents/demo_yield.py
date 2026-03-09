"""
agents/demo_yield.py
────────────────────
End-to-end demonstration that share price actually rises from yield.

HOW IT WORKS
  The vault's _accrue_yield() is a deliberate NO-OP.
  Real yield flow:
    1. vault.deploy_to_strategy(strategy, amount)
         → vault sends `amount` wBTC to MockStrategy
         → MockStrategy.total_deployed += amount
    2. [optional] strategy.add_pending_yield(bonus)
         → marks extra wBTC the strategy will return on next withdraw
         → YOU must first mint/transfer `bonus` wBTC TO the strategy contract
    3. vault.withdraw_from_strategy(strategy, amount)
         → MockStrategy.withdraw() returns principal + pending_yield
         → vault receives MORE wBTC than it deployed → surplus
         → vault.total_assets += surplus
         → share price = total_assets / total_supply → RISES

Usage
─────
    cd /home/mime/Desktop/btc_vault/agents
    source ../.venv/bin/activate        # or: conda activate / poetry shell

    python demo_yield.py                # deploy 0.5 BTC, add 0.01 BTC yield, withdraw
    python demo_yield.py --dry-run      # print plan without sending tx
    python demo_yield.py --deploy-only  # only deploy capital (no immediate withdraw)
    python demo_yield.py --withdraw-only # only withdraw (after previous --deploy-only)
    python demo_yield.py --amount 10000000 --yield 500000  # custom amounts (satoshis)

Environment variables (agents/.env)
────────────────────────────────────
    STARKNET_RPC_URL        (default: Blast Sepolia public node)
    VAULT_ADDRESS           (required)
    MOCK_STRATEGY_ADDRESS   (required – shown by admin_setup.py or redeploy_fresh.py)
    WBTC_ADDRESS            (required)
    ADMIN_ADDRESS           (required)
    ADMIN_PRIVATE_KEY       (required)
"""
from __future__ import annotations

import argparse
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


# ── Config ────────────────────────────────────────────────────────────────────
RPC_URL          = _get("STARKNET_RPC_URL", "https://starknet-sepolia.public.blastapi.io")
VAULT_ADDR       = _get("VAULT_ADDRESS")
STRATEGY_ADDR    = _get("MOCK_STRATEGY_ADDRESS")
WBTC_ADDR        = _get("WBTC_ADDRESS")
ADMIN_ADDR       = _get("ADMIN_ADDRESS")     or _get("ORACLE_OWNER_ADDRESS")
ADMIN_KEY        = _get("ADMIN_PRIVATE_KEY") or _get("ORACLE_OWNER_PRIVATE_KEY")

# ── ABI helpers ───────────────────────────────────────────────────────────────
_ARTIFACTS = os.path.join(os.path.dirname(__file__), "..", "vault", "target", "dev")


def _load_abi(contract_name: str) -> list[dict]:
    path = os.path.join(_ARTIFACTS, f"vault_{contract_name}.contract_class.json")
    with open(path) as f:
        data = json.load(f)
    raw = data.get("abi", "[]")
    return json.loads(raw) if isinstance(raw, str) else raw


# ── Helpers ───────────────────────────────────────────────────────────────────
def _fmt_sat(sat: int) -> str:
    btc = sat / 1e8
    return f"{btc:.8f} BTC ({sat:,} sat)"


def _fmt_share_price(raw: int) -> str:
    """raw uses SCALE = 1_000_000. 1.0 = 1_000_000."""
    return f"{raw / 1_000_000:.6f} wBTC/yBTC"


async def _call_view(rpc: FullNodeClient, contract: Contract, fn: str, *args) -> int:
    """Call a view function and return the first return value as int."""
    result = await contract.functions[fn].call(*args)
    val = result[0] if hasattr(result, "__getitem__") else result
    return int(val)


async def main(args: argparse.Namespace) -> None:
    # ── Validate env ──────────────────────────────────────────────────────────
    missing = [k for k, v in {
        "VAULT_ADDRESS": VAULT_ADDR,
        "MOCK_STRATEGY_ADDRESS": STRATEGY_ADDR,
        "WBTC_ADDRESS": WBTC_ADDR,
        "ADMIN_ADDRESS": ADMIN_ADDR,
        "ADMIN_PRIVATE_KEY": ADMIN_KEY,
    }.items() if not v]
    if missing:
        print("❌  Missing required env vars in agents/.env:")
        for k in missing:
            print(f"     {k}")
        sys.exit(1)

    deploy_amount = args.amount   # satoshis of wBTC to deploy into strategy
    yield_bonus   = args.yield_   # satoshis of extra yield to simulate

    print("═" * 60)
    print(" BTC Vault — Demo Yield Script")
    print("═" * 60)
    print(f" RPC:            {RPC_URL}")
    print(f" Vault:          {VAULT_ADDR}")
    print(f" Strategy:       {STRATEGY_ADDR}")
    print(f" wBTC:           {WBTC_ADDR}")
    print(f" Admin:          {ADMIN_ADDR}")
    print(f" Deploy amount:  {_fmt_sat(deploy_amount)}")
    print(f" Yield bonus:    {_fmt_sat(yield_bonus)}")
    print(f" Dry run:        {args.dry_run}")
    print("─" * 60)

    # ── Connect ───────────────────────────────────────────────────────────────
    rpc = FullNodeClient(node_url=RPC_URL)
    chain = StarknetChainId.SEPOLIA
    account = Account(
        client=rpc,
        address=int(ADMIN_ADDR, 16),
        key_pair=KeyPair.from_private_key(int(ADMIN_KEY, 16)),
        chain=chain,
    )

    vault_abi    = _load_abi("BTCVault")
    strategy_abi = _load_abi("MockStrategy")
    wbtc_erc20_abi = _load_abi("YBTCToken")  # YBTCToken is ERC20 — same shape as wBTC mock

    vault    = Contract(address=int(VAULT_ADDR, 16),    abi=vault_abi,    provider=account)
    strategy = Contract(address=int(STRATEGY_ADDR, 16), abi=strategy_abi, provider=account)
    wbtc     = Contract(address=int(WBTC_ADDR, 16),     abi=wbtc_erc20_abi, provider=account)

    # ── Pre-flight snapshot ───────────────────────────────────────────────────
    try:
        share_price_before = await _call_view(rpc, vault, "get_share_price")
        total_assets_before = await _call_view(rpc, vault, "get_total_assets")
        strategy_value_before = await _call_view(rpc, strategy, "get_value")
        admin_wbtc_before = await _call_view(rpc, wbtc, "balance_of", int(ADMIN_ADDR, 16))
        vault_wbtc_before = await _call_view(rpc, wbtc, "balance_of", int(VAULT_ADDR, 16))
    except Exception as e:
        print(f"❌  Pre-flight read failed: {e}")
        sys.exit(1)

    print("\n📊  PRE-FLIGHT STATE")
    print(f"   Share price (SCALE 1e6):  {share_price_before:,}  →  {_fmt_share_price(share_price_before)}")
    print(f"   Total assets:             {_fmt_sat(total_assets_before)}")
    print(f"   Strategy value:           {_fmt_sat(strategy_value_before)}")
    print(f"   Admin wBTC balance:       {_fmt_sat(admin_wbtc_before)}")
    print(f"   Vault wBTC balance:       {_fmt_sat(vault_wbtc_before)}")

    # ── Step 0: Auto-seed vault if it has insufficient liquid wBTC ───────────
    if not args.withdraw_only and vault_wbtc_before < deploy_amount:
        seed = deploy_amount - vault_wbtc_before
        needs_mint = admin_wbtc_before < seed
        print(f"\n▶  Step 0 — Auto-seed vault with {_fmt_sat(seed)} wBTC (vault is short)…")
        if needs_mint:
            print(f"   0a. Will mint {_fmt_sat(seed - admin_wbtc_before)} wBTC to admin")
        print(f"   0b. Will approve {_fmt_sat(seed)} wBTC to vault")
        print(f"   0c. Will deposit  {_fmt_sat(seed)} wBTC into vault")

        if not args.dry_run:
            if needs_mint:
                to_mint = seed - admin_wbtc_before
                try:
                    m = await wbtc.functions["mint"].invoke_v3(
                        int(ADMIN_ADDR, 16), {"low": to_mint, "high": 0},
                        auto_estimate=True,
                    )
                    print(f"       mint tx: {hex(m.hash)} …")
                    await m.wait_for_acceptance()
                    print(f"       ✅  Minted {_fmt_sat(to_mint)}")
                except Exception as e:
                    print(f"       ❌  mint failed: {e}")
                    sys.exit(1)
            try:
                a = await wbtc.functions["approve"].invoke_v3(
                    int(VAULT_ADDR, 16), {"low": seed, "high": 0},
                    auto_estimate=True,
                )
                print(f"       approve tx: {hex(a.hash)} …")
                await a.wait_for_acceptance()
                print(f"       ✅  Approved")
            except Exception as e:
                print(f"       ❌  approve failed: {e}")
                sys.exit(1)
            try:
                d = await vault.functions["deposit"].invoke_v3(
                    {"low": seed, "high": 0},
                    auto_estimate=True,
                )
                print(f"       deposit tx: {hex(d.hash)} …")
                await d.wait_for_acceptance()
                # Refresh snapshots so the rest of the script sees the updated state
                vault_wbtc_before   = await _call_view(rpc, wbtc,  "balance_of", int(VAULT_ADDR, 16))
                total_assets_before = await _call_view(rpc, vault, "get_total_assets")
                share_price_before  = await _call_view(rpc, vault, "get_share_price")
                print(f"       ✅  Vault seeded  →  wBTC: {_fmt_sat(vault_wbtc_before)}  |  total_assets: {_fmt_sat(total_assets_before)}")
            except Exception as e:
                print(f"       ❌  deposit failed: {e}")
                sys.exit(1)

    if args.dry_run:
        print("\n✅  Dry run complete — no transactions sent.")
        return

    # ── Step 1: (Optional) Register strategy if not yet registered ───────────
    # The vault keeps a map of registered strategies.  If we've never called
    # register_strategy before, deploy_to_strategy will revert.
    # We do a best-effort register (owner-only); it's idempotent if already active.
    if not args.withdraw_only:
        print("\n▶  Step 1 — Ensure strategy is registered…")
        try:
            reg_inv = await vault.functions["register_strategy"].invoke_v3(
                int(STRATEGY_ADDR, 16),
                2,          # risk_level = 2 (moderate)
                auto_estimate=True,
            )
            print(f"   register_strategy tx: {hex(reg_inv.hash)}")
            print("   ⏳  Waiting for acceptance…")
            await reg_inv.wait_for_acceptance()
            print("   ✅  Registered (or already active)")
        except Exception as e:
            err = str(e)
            if "already" in err.lower() or "active" in err.lower() or "exists" in err.lower():
                print("   ℹ️   Strategy already registered — continuing")
            else:
                print(f"   ⚠️   register_strategy: {err}")
                print("   Continuing anyway — strategy may already be registered.")

    # ── Step 2: Deploy wBTC to strategy ──────────────────────────────────────
    if not args.withdraw_only:
        print(f"\n▶  Step 2 — Deploy {_fmt_sat(deploy_amount)} to strategy…")
        try:
            deploy_inv = await vault.functions["deploy_to_strategy"].invoke_v3(
                int(STRATEGY_ADDR, 16),
                {"low": deploy_amount, "high": 0},  # u256 as struct
                auto_estimate=True,
            )
            print(f"   deploy_to_strategy tx: {hex(deploy_inv.hash)}")
            print("   ⏳  Waiting for acceptance…")
            await deploy_inv.wait_for_acceptance()
            print("   ✅  Capital deployed")
        except Exception as e:
            print(f"   ❌  deploy_to_strategy failed: {e}")
            sys.exit(1)

    if args.deploy_only:
        print("\n✅  --deploy-only: stopping after deploy.  Run with --withdraw-only to harvest.")
        return

    # ── Step 3: Add pending yield (mint extra wBTC to strategy) ──────────────
    if yield_bonus > 0:
        print(f"\n▶  Step 3 — Inject yield bonus of {_fmt_sat(yield_bonus)}…")
        # 3a. Mint yield_bonus wBTC to admin (vault minting function or faucet)
        print("   3a. Minting yield wBTC to admin via wBTC.mint()…")
        try:
            mint_inv = await wbtc.functions["mint"].invoke_v3(
                int(ADMIN_ADDR, 16),
                {"low": yield_bonus, "high": 0},
                auto_estimate=True,
            )
            await mint_inv.wait_for_acceptance()
            print(f"       ✅  Minted {_fmt_sat(yield_bonus)} to admin")
        except Exception as e:
            print(f"       ⚠️   mint failed ({e}) — trying approve+transfer pattern instead")

        # 3b. Transfer yield wBTC from admin to strategy contract
        print("   3b. Transferring yield wBTC from admin → strategy…")
        try:
            transfer_inv = await wbtc.functions["transfer"].invoke_v3(
                int(STRATEGY_ADDR, 16),
                {"low": yield_bonus, "high": 0},
                auto_estimate=True,
            )
            await transfer_inv.wait_for_acceptance()
            print(f"       ✅  Transferred {_fmt_sat(yield_bonus)} to strategy")
        except Exception as e:
            print(f"       ❌  transfer failed: {e}")
            print("       Continuing — add_pending_yield may still succeed if wBTC is already there")

        # 3c. Mark as pending yield inside the strategy
        print("   3c. Calling strategy.add_pending_yield()…")
        try:
            yield_inv = await strategy.functions["add_pending_yield"].invoke_v3(
                {"low": yield_bonus, "high": 0},
                auto_estimate=True,
            )
            print(f"       add_pending_yield tx: {hex(yield_inv.hash)}")
            await yield_inv.wait_for_acceptance()
            print(f"       ✅  Yield bonus of {_fmt_sat(yield_bonus)} queued in strategy")
        except Exception as e:
            print(f"       ❌  add_pending_yield failed: {e}")
            print("       The vault will still reclaim principal on withdraw, just no bonus.")
    else:
        print("\n   ℹ️   No yield bonus requested (--yield 0). Skipping step 3.")
        print("        Wait for time-based APY to accrue naturally in the strategy.")
        print("        Re-run with --withdraw-only after some time to harvest.")

    # ── Step 4: Withdraw from strategy (trigger share price rise) ────────────
    # Pass only `deploy_amount` — the strategy.withdraw() adds pending_yield on top
    # automatically, returning principal + bonus.  The vault detects the surplus
    # (returned > requested) and credits it to total_assets → share price rises.
    withdraw_amount = deploy_amount
    print(f"\n▶  Step 4 — Withdraw {_fmt_sat(withdraw_amount)} from strategy (triggers accounting)…")
    try:
        withdraw_inv = await vault.functions["withdraw_from_strategy"].invoke_v3(
            int(STRATEGY_ADDR, 16),
            {"low": withdraw_amount, "high": 0},
            auto_estimate=True,
        )
        print(f"   withdraw_from_strategy tx: {hex(withdraw_inv.hash)}")
        print("   ⏳  Waiting for acceptance…")
        await withdraw_inv.wait_for_acceptance()
        print("   ✅  Withdrawal complete — vault received principal + yield surplus")
    except Exception as e:
        print(f"   ❌  withdraw_from_strategy failed: {e}")
        print("       The surplus was not yet credited. Check strategy balance manually.")
        sys.exit(1)

    # ── Post-flight snapshot ──────────────────────────────────────────────────
    # Small delay so RPC state propagates
    await asyncio.sleep(2)

    try:
        share_price_after  = await _call_view(rpc, vault, "get_share_price")
        total_assets_after = await _call_view(rpc, vault, "get_total_assets")
    except Exception as e:
        print(f"\n⚠️   Post-flight read failed: {e}")
        print("   Run admin_setup.py --status to check state manually.")
        return

    print("\n" + "═" * 60)
    print(" RESULT SUMMARY")
    print("═" * 60)
    print(f"   Share price BEFORE:  {_fmt_share_price(share_price_before)}")
    print(f"   Share price AFTER:   {_fmt_share_price(share_price_after)}")

    delta = share_price_after - share_price_before
    if delta > 0:
        pct = delta / share_price_before * 100 if share_price_before > 0 else 0
        print(f"\n   🚀  Share price rose by {delta} ({pct:.4f}%)")
        print(f"      Depositors who held yBTC are now {pct:.4f}% richer in BTC terms.")
    elif delta == 0:
        print("\n   ⚠️   Share price unchanged — either no surplus reached the vault,")
        print("        or it's a fresh vault (share price is pinned at 1.0 until yield flows).")
    else:
        print(f"\n   ❌  Share price decreased by {abs(delta)} — this should not happen.")

    print(f"\n   Total assets BEFORE: {_fmt_sat(total_assets_before)}")
    print(f"   Total assets AFTER:  {_fmt_sat(total_assets_after)}")
    surplus = total_assets_after - total_assets_before
    if surplus > 0:
        print(f"   Surplus credited:    +{_fmt_sat(surplus)}")
    print("═" * 60)


if __name__ == "__main__":
    p = argparse.ArgumentParser(description="Demo: deploy capital to MockStrategy, inject yield, harvest")
    p.add_argument("--amount",    type=int, default=50_000_000,
                   help="wBTC amount to deploy (satoshis, default 50_000_000 = 0.5 BTC)")
    p.add_argument("--yield",     type=int, default=1_000_000, dest="yield_",
                   help="Extra yield bonus to inject (satoshis, default 1_000_000 = 0.01 BTC)")
    p.add_argument("--dry-run",   action="store_true",
                   help="Print plan without sending any transactions")
    p.add_argument("--deploy-only",  action="store_true",
                   help="Only deploy capital — do not withdraw in this run")
    p.add_argument("--withdraw-only", action="store_true",
                   help="Skip deploy — only withdraw (use after a previous --deploy-only)")
    args = p.parse_args()

    if args.deploy_only and args.withdraw_only:
        p.error("Cannot use --deploy-only and --withdraw-only together")

    asyncio.run(main(args))
