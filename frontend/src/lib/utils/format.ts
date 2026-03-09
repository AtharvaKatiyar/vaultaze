import { HealthStatus } from "@/types";
import { BTC_DECIMALS, PRICE_DECIMALS, SCALE } from "@/lib/contracts/addresses";

// ─── BTC formatting ─────────────────────────────────────────────────────────

/** satoshi → BTC string, e.g. 100_000_000n → "1.00000000" */
export function formatBTC(satoshi: bigint, decimals = 8): string {
  if (satoshi === BigInt(0)) return "0.00000000";
  const divisor = BigInt(10 ** BTC_DECIMALS);
  const whole = satoshi / divisor;
  const frac = satoshi % divisor;
  const fracStr = frac.toString().padStart(BTC_DECIMALS, "0").slice(0, decimals);
  return `${whole}.${fracStr}`;
}

/** satoshi + BTC/USD price → USD string with $ sign */
export function satoshiToUSD(satoshi: bigint, btcUsdPrice: bigint): string {
  const priceDivisor = BigInt(10 ** PRICE_DECIMALS);
  const usd = (satoshi * btcUsdPrice) / priceDivisor;
  return formatUSD(Number(usd) / 1e8);
}

/** Number → formatted USD string */
export function formatUSD(amount: number): string {
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    maximumFractionDigits: 2,
  }).format(amount);
}

/** Pragma 8-dec price → dollar value */
export function pragmaToUSD(price: bigint): number {
  return Number(price) / 10 ** PRICE_DECIMALS;
}

// ─── Share price ─────────────────────────────────────────────────────────────

/** Share price (SCALE=1_000_000) → display string like "1.0234" */
export function formatSharePrice(sharePrice: bigint | number | undefined): string {
  const raw = sharePrice == null ? 0n : typeof sharePrice === "number" ? BigInt(Math.floor(sharePrice)) : sharePrice;
  // 0 is returned by the contract when total_supply=0 (fresh vault).
  // The vault invariant guarantees share_price ≥ 1.0 once supply > 0, and
  // defaults to SCALE (1.0) for the very first deposit.  Never show "0.000000".
  if (raw === 0n) return "1.000000";
  const n = Number(raw) / Number(SCALE);
  return n.toFixed(6);
}

// ─── APY / basis points ──────────────────────────────────────────────────────

/** Basis points → percentage string e.g. 850 → "8.50%" */
export function bpsToPercent(bps: number | bigint): string {
  const n = Number(bps) / 100;
  return `${n.toFixed(2)}%`;
}

// ─── Health factor ───────────────────────────────────────────────────────────

// Sentinel value used by useSystemMetrics when get_btc_health returns u128::MAX
// (meaning btc_exposure = 0, system perfectly backed / no open leverage)
const HEALTH_NO_EXPOSURE = 999999;

/** Health value (×100) → display string: "1.42" or "∞" */
export function formatHealth(health: number): string {
  if (health >= HEALTH_NO_EXPOSURE) return "∞";
  return (health / 100).toFixed(2);
}

/** Health value → status category */
export function healthToStatus(health: number): HealthStatus {
  if (health >= HEALTH_NO_EXPOSURE) return "healthy"; // no exposure = perfectly safe
  if (health >= 150) return "healthy";
  if (health >= 120) return "moderate";
  if (health >= 100) return "warning";
  return "critical";
}

/** Status → Tailwind colour token */
export function healthColor(status: HealthStatus): string {
  switch (status) {
    case "healthy":  return "text-emerald-400";
    case "moderate": return "text-yellow-400";
    case "warning":  return "text-orange-400";
    case "critical": return "text-red-500";
  }
}

export function healthBgColor(status: HealthStatus): string {
  switch (status) {
    case "healthy":  return "bg-emerald-400/10 border-emerald-400/30";
    case "moderate": return "bg-yellow-400/10 border-yellow-400/30";
    case "warning":  return "bg-orange-400/10 border-orange-400/30";
    case "critical": return "bg-red-500/10 border-red-500/30";
  }
}

// ─── Leverage ────────────────────────────────────────────────────────────────

/** Leverage stored as integer × 100 → "1.80x" */
export function formatLeverage(leverage: number): string {
  return `${(leverage / 100).toFixed(2)}x`;
}

// ─── Address ─────────────────────────────────────────────────────────────────

/** Shorten Starknet address for display */
export function shortAddress(addr: string): string {
  if (!addr || addr.length < 12) return addr;
  return `${addr.slice(0, 6)}...${addr.slice(-4)}`;
}

// ─── TVL ─────────────────────────────────────────────────────────────────────

/** Format TVL in BTC + USD */
export function formatTVL(totalAssets: bigint, btcUsdPrice: bigint): string {
  const btc = formatBTC(totalAssets, 4);
  const usd = satoshiToUSD(totalAssets, btcUsdPrice);
  return `${btc} BTC (${usd})`;
}

// ─── Time ─────────────────────────────────────────────────────────────────────

/** Unix timestamp → "X mins ago" */
export function timeAgo(ts: number): string {
  const diff = Math.floor(Date.now() / 1000) - ts;
  if (diff < 60)  return `${diff}s ago`;
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  return `${Math.floor(diff / 86400)}d ago`;
}
