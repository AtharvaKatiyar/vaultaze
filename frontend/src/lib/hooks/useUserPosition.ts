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
