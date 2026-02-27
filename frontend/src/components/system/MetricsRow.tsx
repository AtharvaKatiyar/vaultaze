"use client";

import { TrendingUp, DollarSign, Layers, Zap, ShieldCheck } from "lucide-react";
import { Card, CardTitle, CardValue } from "@/components/ui/Card";
import { HealthBadge } from "@/components/system/HealthBadge";
import { useSystemMetrics } from "@/lib/hooks/useRouterData";
import { formatBTC, formatUSD, pragmaToUSD, bpsToPercent, formatLeverage } from "@/lib/utils/format";

// Fallback BTC price shown when the on-chain oracle is stale (>1 hour old).
// The Cairo router spec (S-4) explicitly returns 0 for get_btc_usd_price when stale.
const FALLBACK_BTC_PRICE = 95_000;

export function MetricsRow() {
  const { data, loading } = useSystemMetrics();

  const skeleton = <span className="block h-7 w-24 rounded-lg bg-white/5 animate-pulse" />;

  // Detect stale oracle — btcUsdPrice === 0 means router returned 0 (stale)
  const priceIsStale = !loading && data !== null && (data.btcUsdPrice === 0 || !data.isPriceFresh);
  const rawBtcPrice  = data ? pragmaToUSD(BigInt(data.btcUsdPrice)) : 0;
  const btcPrice     = rawBtcPrice > 0 ? rawBtcPrice : (data ? FALLBACK_BTC_PRICE : 0);

  const tvlBTC = data ? formatBTC(data.totalAssets, 4) : "—";
  const tvlUSD = data ? formatUSD(btcPrice * (Number(data.totalAssets) / 1e8)) : "—";

  // Health is independent of oracle price — always show the badge regardless of price staleness.
  // healthIsUnknown is retained on the data object for future diagnostics only.

  return (
    <div className="space-y-3">
      {/* Stale price banner — informational only, no broken refresh button */}
      {priceIsStale && (
        <div className="flex items-center gap-3 bg-orange-500/10 border border-orange-500/20 rounded-xl px-4 py-2.5">
          <p className="text-xs text-orange-300">
            ⚠ On-chain oracle price is stale on Sepolia testnet. Displaying estimated price (~$95,000). Health metrics are unaffected.
          </p>
        </div>
      )}

      <div className="grid grid-cols-2 md:grid-cols-3 xl:grid-cols-5 gap-4">

        {/* BTC Health */}
        <Card glow={data?.healthStatus === "healthy" ? "green" : data?.healthStatus === "critical" ? "red" : "orange"}>
          <CardTitle className="flex items-center gap-1.5">
            <ShieldCheck className="w-3.5 h-3.5" /> BTC Health
          </CardTitle>
          <div className="mt-2">
            {loading ? skeleton : <HealthBadge health={data!.btcHealth} />}
          </div>
        </Card>

        {/* BTC Price */}
        <Card>
          <CardTitle className="flex items-center gap-1.5">
            <DollarSign className="w-3.5 h-3.5" /> BTC Price
          </CardTitle>
          <CardValue className={priceIsStale ? "text-orange-300" : ""}>
            {loading ? skeleton : formatUSD(btcPrice)}
          </CardValue>
          {!loading && priceIsStale && (
            <p className="text-xs text-orange-400/70 mt-1">est. · oracle stale</p>
          )}
        </Card>

        {/* TVL */}
        <Card>
          <CardTitle className="flex items-center gap-1.5">
            <Layers className="w-3.5 h-3.5" /> TVL
          </CardTitle>
          <CardValue className="text-xl">
            {loading ? skeleton : `${tvlBTC} BTC`}
          </CardValue>
          <p className="text-xs text-white/40 mt-0.5">{loading ? "" : tvlUSD}</p>
        </Card>

        {/* APY */}
        <Card glow="green">
          <CardTitle className="flex items-center gap-1.5">
            <TrendingUp className="w-3.5 h-3.5" /> Est. APY
          </CardTitle>
          <CardValue className="text-emerald-400">
            {loading ? skeleton : data!.apy > 0 ? bpsToPercent(data!.apy) : "6–20%"}
          </CardValue>
          {!loading && data!.apy === 0 && (
            <p className="text-xs text-white/30 mt-1">by strategy</p>
          )}
        </Card>

        {/* Max Leverage */}
        <Card>
          <CardTitle className="flex items-center gap-1.5">
            <Zap className="w-3.5 h-3.5" /> Max Leverage
          </CardTitle>
          <CardValue className="text-orange-400">
            {loading ? skeleton : data!.maxLeverage > 0 ? formatLeverage(data!.maxLeverage) : "2.00×"}
          </CardValue>
          {!loading && data!.maxLeverage === 0 && (
            <p className="text-xs text-white/30 mt-1">est.</p>
          )}
        </Card>

      </div>
    </div>
  );
}
