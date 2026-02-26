"use client";

import { useState } from "react";
import { TrendingUp, DollarSign, Layers, Zap, ShieldCheck, RefreshCw } from "lucide-react";
import { Card, CardTitle, CardValue } from "@/components/ui/Card";
import { HealthBadge } from "@/components/system/HealthBadge";
import { useSystemMetrics } from "@/lib/hooks/useRouterData";
import { formatBTC, formatUSD, pragmaToUSD, bpsToPercent, formatLeverage } from "@/lib/utils/format";

// Fallback BTC price shown when the on-chain oracle is stale (>1 hour old).
// The Cairo router spec (S-4) explicitly returns 0 for get_btc_usd_price when stale.
const FALLBACK_BTC_PRICE = 95_000;
const FAUCET_API = process.env.NEXT_PUBLIC_FAUCET_API_URL ?? "http://localhost:8400";

export function MetricsRow() {
  const { data, loading } = useSystemMetrics();
  const [refreshing, setRefreshing] = useState(false);
  const [refreshed,  setRefreshed]  = useState(false);

  const skeleton = <span className="block h-7 w-24 rounded-lg bg-white/5 animate-pulse" />;

  // Detect stale oracle — btcUsdPrice === 0 means router returned 0 (stale)
  const priceIsStale = !loading && data !== null && (data.btcUsdPrice === 0 || !data.isPriceFresh);
  const rawBtcPrice  = data ? pragmaToUSD(BigInt(data.btcUsdPrice)) : 0;
  const btcPrice     = rawBtcPrice > 0 ? rawBtcPrice : (data ? FALLBACK_BTC_PRICE : 0);

  const tvlBTC = data ? formatBTC(data.totalAssets, 4) : "—";
  const tvlUSD = data ? formatUSD(btcPrice * (Number(data.totalAssets) / 1e8)) : "—";

  // health cascades from price — don't show "critical" when price is simply stale
  const healthIsStale = priceIsStale && data?.btcHealth === 0;

  async function handleRefreshOracle() {
    setRefreshing(true);
    try {
      await fetch(`${FAUCET_API}/oracle/refresh`, { method: "POST" });
      setRefreshed(true);
      setTimeout(() => setRefreshed(false), 5000);
    } catch { /* server unreachable */ }
    finally { setRefreshing(false); }
  }

  return (
    <div className="space-y-3">
      {/* Stale price banner */}
      {priceIsStale && (
        <div className="flex items-center justify-between bg-orange-500/10 border border-orange-500/20 rounded-xl px-4 py-2.5">
          <p className="text-xs text-orange-300">
            ⚠ Oracle price stale — metrics are estimated. Last known: ~$95,000.
          </p>
          <button
            onClick={handleRefreshOracle}
            disabled={refreshing}
            className="ml-4 shrink-0 flex items-center gap-1.5 text-xs bg-orange-500/15 hover:bg-orange-500/25 border border-orange-500/25 text-orange-300 rounded-lg px-3 py-1.5 transition-colors disabled:opacity-50"
          >
            <RefreshCw className={`w-3 h-3 ${refreshing ? "animate-spin" : ""}`} />
            {refreshed ? "Refreshed ✓" : refreshing ? "Refreshing…" : "Refresh Price"}
          </button>
        </div>
      )}

      <div className="grid grid-cols-2 md:grid-cols-3 xl:grid-cols-5 gap-4">

        {/* BTC Health */}
        <Card glow={healthIsStale ? "orange" : data?.healthStatus === "healthy" ? "green" : data?.healthStatus === "critical" ? "red" : "orange"}>
          <CardTitle className="flex items-center gap-1.5">
            <ShieldCheck className="w-3.5 h-3.5" /> BTC Health
          </CardTitle>
          <div className="mt-2">
            {loading
              ? skeleton
              : healthIsStale
                ? <span className="text-base font-bold text-orange-400">— stale</span>
                : <HealthBadge health={data!.btcHealth} />}
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
            <p className="text-xs text-orange-400/70 mt-1">est. · stale</p>
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
