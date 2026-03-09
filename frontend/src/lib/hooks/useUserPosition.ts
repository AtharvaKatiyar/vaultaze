"use client";

import { useReadContract } from "@starknet-react/core";
import { useAccount } from "@starknet-react/core";
import { CONTRACTS } from "@/lib/contracts/addresses";
import { VAULT_ABI } from "@/lib/contracts/vault-abi";
import { ERC20_ABI } from "@/lib/contracts/erc20-abi";

// ─── Uint256 / bigint normaliser ────────────────────────────────────────────
// starknet.js v6 returns u256 ABI values as { low: bigint, high: bigint }.
// This helper handles every possible shape the RPC might return.
export function toBalance(v: unknown): bigint {
  if (v == null) return 0n;
  if (typeof v === "bigint") return v;
  if (typeof v === "number") return BigInt(v);
  if (typeof v === "string") {
    try { return BigInt(v); } catch { return 0n; }
  }
  if (typeof v === "object" && "low" in (v as object) && "high" in (v as object)) {
    const u = v as { low: bigint | string | number; high: bigint | string | number };
    return (BigInt(u.high) << 128n) + BigInt(u.low);
  }
  return 0n;
}

// ─── User position ──────────────────────────────────────────────────────────

export function useUserPosition() {
  const { address } = useAccount();
  return useReadContract({
    abi: VAULT_ABI,
    address: CONTRACTS.BTCVault,
    functionName: "get_user_position",
    args: address ? [address] : undefined,
    enabled: Boolean(address),
    watch: true,
  });
}

export function useUserHealth() {
  const { address } = useAccount();
  return useReadContract({
    abi: VAULT_ABI,
    address: CONTRACTS.BTCVault,
    functionName: "get_user_health",
    args: address ? [address] : undefined,
    enabled: Boolean(address),
    watch: true,
  });
}

export function useUserLiquidationPrice() {
  const { address } = useAccount();
  return useReadContract({
    abi: VAULT_ABI,
    address: CONTRACTS.BTCVault,
    functionName: "get_liquidation_price",
    args: address ? [address] : undefined,
    enabled: Boolean(address),
    watch: true,
  });
}

export function useUserClaimableYield() {
  const { address } = useAccount();
  return useReadContract({
    abi: VAULT_ABI,
    address: CONTRACTS.BTCVault,
    functionName: "get_user_claimable_yield",
    args: address ? [address] : undefined,
    enabled: Boolean(address),
    watch: true,
  });
}

export function useRecommendedLeverage() {
  const { address } = useAccount();
  return useReadContract({
    abi: VAULT_ABI,
    address: CONTRACTS.BTCVault,
    functionName: "get_recommended_leverage",
    args: address ? [address] : undefined,
    enabled: Boolean(address),
    watch: true,
  });
}

// ─── Token balances ──────────────────────────────────────────────────────────

export function useWBTCBalance() {
  const { address } = useAccount();
  return useReadContract({
    abi: ERC20_ABI,
    address: CONTRACTS.MockWBTC,
    functionName: "balance_of",
    args: address ? [address] : undefined,
    enabled: Boolean(address),
    watch: true,
  });
}

export function useYBTCBalance() {
  const { address } = useAccount();
  return useReadContract({
    abi: ERC20_ABI,
    address: CONTRACTS.YBTCToken,
    functionName: "balance_of",
    args: address ? [address] : undefined,
    enabled: Boolean(address),
    watch: true,
  });
}

export function useWBTCAllowance() {
  const { address } = useAccount();
  return useReadContract({
    abi: ERC20_ABI,
    address: CONTRACTS.MockWBTC,
    functionName: "allowance",
    args: address ? [address, CONTRACTS.BTCVault] : undefined,
    enabled: Boolean(address),
    watch: true,
  });
}

export function useUserDebt() {
  const { address } = useAccount();
  return useReadContract({
    abi: VAULT_ABI,
    address: CONTRACTS.BTCVault,
    functionName: "get_user_debt",
    args: address ? [address] : undefined,
    enabled: Boolean(address),
    watch: true,
  });
}

// ─── Full user dashboard (single RPC call) ──────────────────────────────────
// Mirrors the UserDashboard struct returned by get_user_dashboard(user).
// All numeric fields come back as bigint from starknet.js — use toBalance() to normalise.
export interface ParsedDashboard {
  ybtcBalance:         bigint;   // yBTC shares (8 dec)
  btcValueSat:         bigint;   // BTC value of shares (satoshis)
  btcValueUsd:         bigint;   // USD value (8 dec Pragma scale, 0 if price stale)
  currentLeverage:     number;   // 100 = 1.0x
  userDebtUsd:         bigint;   // outstanding USD debt (8 dec Pragma scale)
  healthFactor:        number;   // ×100, u128::MAX sentinel → 999999
  liquidationPriceUsd: number;   // 0 when no debt
  claimableYieldSat:   bigint;   // wBTC yield claimable (satoshis)
  sharePrice:          bigint;   // SCALE=1_000_000 = 1.0x
  vaultApy:            number;   // basis points
  priceFresh:          boolean;
  safeMode:            boolean;
  canDeposit:          boolean;
  canLeverage:         boolean;
  recommendedLeverage: number;
  depositTimestamp:    number;
}

const U128_MAX_SENTINEL = 340282366920938463463374607431768211455n;

export function useUserDashboard(): { data: ParsedDashboard | null; loading: boolean } {
  const { address } = useAccount();
  const { data: raw, isLoading } = useReadContract({
    abi: VAULT_ABI,
    address: CONTRACTS.BTCVault,
    functionName: "get_user_dashboard",
    args: address ? [address] : undefined,
    enabled: Boolean(address),
    watch: true,
  });

  if (isLoading || !raw || !address) return { data: null, loading: isLoading };

  const d = raw as any;
  const hf = toBalance(d.health_factor);
  return {
    data: {
      ybtcBalance:         toBalance(d.ybtc_balance),
      btcValueSat:         toBalance(d.btc_value_sat),
      btcValueUsd:         toBalance(d.btc_value_usd),
      currentLeverage:     Number(toBalance(d.current_leverage)) || 100,
      userDebtUsd:         toBalance(d.user_debt_usd),
      healthFactor:        hf >= U128_MAX_SENTINEL ? 999999 : Number(hf),
      liquidationPriceUsd: Number(toBalance(d.liquidation_price_usd)),
      claimableYieldSat:   toBalance(d.claimable_yield_sat),
      sharePrice:          toBalance(d.share_price),
      vaultApy:            Number(toBalance(d.vault_apy)),
      priceFresh:          Boolean(d.price_is_fresh),
      safeMode:            Boolean(d.is_safe_mode),
      canDeposit:          Boolean(d.can_deposit),
      canLeverage:         Boolean(d.can_leverage),
      recommendedLeverage: Number(toBalance(d.recommended_leverage)) || 100,
      depositTimestamp:    Number(toBalance(d.deposit_timestamp)),
    },
    loading: false,
  };
}
