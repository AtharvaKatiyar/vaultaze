"use client";

import { useReadContract } from "@starknet-react/core";
import { CONTRACTS } from "@/lib/contracts/addresses";
import { ROUTER_ABI } from "@/lib/contracts/router-abi";
import { VAULT_ABI } from "@/lib/contracts/vault-abi";
import { healthToStatus } from "@/lib/utils/format";
import { SystemMetrics, type HealthStatus } from "@/types";
import { useMemo } from "react";

// ─── Low-level reads ────────────────────────────────────────────────────────

export function useRouterHealth() {
  return useReadContract({
    abi: ROUTER_ABI,
    address: CONTRACTS.BTCSecurityRouter,
    functionName: "get_btc_health",
    watch: true,
  });
}

export function useRouterSafeMode() {
  return useReadContract({
    abi: ROUTER_ABI,
    address: CONTRACTS.BTCSecurityRouter,
    functionName: "is_safe_mode",
    watch: true,
  });
}

export function useRouterMaxLeverage() {
  return useReadContract({
    abi: ROUTER_ABI,
    address: CONTRACTS.BTCSecurityRouter,
    functionName: "get_max_leverage",
    watch: true,
  });
}

export function useRouterBTCPrice() {
  return useReadContract({
    abi: ROUTER_ABI,
    address: CONTRACTS.BTCSecurityRouter,
    functionName: "get_btc_usd_price",
    watch: true,
  });
}

export function useRouterBacking() {
  return useReadContract({
    abi: ROUTER_ABI,
    address: CONTRACTS.BTCSecurityRouter,
    functionName: "get_btc_backing",
    watch: true,
  });
}

export function useRouterExposure() {
  return useReadContract({
    abi: ROUTER_ABI,
    address: CONTRACTS.BTCSecurityRouter,
    functionName: "get_btc_exposure",
    watch: true,
  });
}

export function usePriceFresh() {
  return useReadContract({
    abi: ROUTER_ABI,
    address: CONTRACTS.BTCSecurityRouter,
    functionName: "is_price_fresh",
    watch: true,
  });
}

export function useVaultTotalAssets() {
  return useReadContract({
    abi: VAULT_ABI,
    address: CONTRACTS.BTCVault,
    functionName: "get_total_assets",
    watch: true,
  });
}

export function useVaultSharePrice() {
  return useReadContract({
    abi: VAULT_ABI,
    address: CONTRACTS.BTCVault,
    functionName: "get_share_price",
    watch: true,
  });
}

export function useVaultAPY() {
  return useReadContract({
    abi: VAULT_ABI,
    address: CONTRACTS.BTCVault,
    functionName: "get_apy",
    watch: true,
  });
}

// ─── Aggregated system metrics ──────────────────────────────────────────────

// u128::MAX — returned by get_btc_health when btc_exposure = 0 (no leverage open)
const U128_MAX = 340282366920938463463374607431768211455n;

export function useSystemMetrics(): { data: SystemMetrics | null; loading: boolean } {
  const { data: health,       isLoading: l1 }  = useRouterHealth();
  const { data: safeMode,     isLoading: l2 }  = useRouterSafeMode();
  const { data: maxLeverage,  isLoading: l3 }  = useRouterMaxLeverage();
  const { data: btcPrice,     isLoading: l4 }  = useRouterBTCPrice();
  const { data: backing,      isLoading: l5 }  = useRouterBacking();
  const { data: exposure,     isLoading: l6 }  = useRouterExposure();
  const { data: isPriceFresh, isLoading: l7 }  = usePriceFresh();
  const { data: totalAssets,  isLoading: l8 }  = useVaultTotalAssets();
  const { data: sharePrice,   isLoading: l9 }  = useVaultSharePrice();
  const { data: apy,          isLoading: l10 } = useVaultAPY();

  const loading = l1 || l2 || l3 || l4 || l5 || l6 || l7 || l8 || l9 || l10;

  const data = useMemo<SystemMetrics | null>(() => {
    // Keep null while any hook is still in its initial fetch
    if (loading) return null;

    // Helper: convert Uint256 | bigint | number | undefined → bigint
    const toBigInt = (v: unknown): bigint => {
      if (v == null) return 0n;
      if (typeof v === "bigint") return v;
      if (typeof v === "number") return BigInt(v);
      if (typeof v === "string") return BigInt(v);
      if (typeof v === "object" && "low" in (v as object) && "high" in (v as object)) {
        const u = v as { low: bigint; high: bigint };
        return (BigInt(u.high) << 128n) + BigInt(u.low);
      }
      return 0n;
    };

    // Raw health value (×100 integer). u128::MAX means btc_exposure=0 → no open leverage.
    // We use sentinel 999999 so HealthBadge can display "∞ (No Exposure)".
    const rawHealth = health as bigint | undefined;
    const h: number =
      rawHealth === undefined           ? 0
      : rawHealth >= U128_MAX           ? 999999        // no exposure → perfectly safe
      : Number(rawHealth);

    return {
      btcHealth:    h,
      healthStatus: healthToStatus(h) as HealthStatus,
      isSafeMode:   Boolean(safeMode),
      btcUsdPrice:  Number((btcPrice as bigint | undefined) ?? 0n),
      totalAssets:  toBigInt(totalAssets),
      sharePrice:   toBigInt(sharePrice),
      apy:          Number((apy as bigint | undefined) ?? 0n),
      maxLeverage:  Number((maxLeverage as bigint | undefined) ?? 0n),
      maxLtv:       0,
      btcBacking:   toBigInt(backing),
      btcExposure:  toBigInt(exposure),
      isPriceFresh: Boolean(isPriceFresh ?? false),
    };
  }, [loading, health, safeMode, maxLeverage, btcPrice, backing, exposure, isPriceFresh, totalAssets, sharePrice, apy]);

  return { data, loading };
}


