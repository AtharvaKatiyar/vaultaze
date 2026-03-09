"use client";

import { AppLayout } from "@/components/layout/AppLayout";
import { PositionCard } from "@/components/portfolio/PositionCard";
import { Card, CardTitle } from "@/components/ui/Card";
import { useAccount } from "@starknet-react/core";
import {
  useWBTCBalance, useYBTCBalance,
  useUserClaimableYield, useUserDashboard,
} from "@/lib/hooks/useUserPosition";
import { useSystemMetrics } from "@/lib/hooks/useRouterData";
import { formatBTC, formatUSD, pragmaToUSD, formatSharePrice, bpsToPercent, healthToStatus } from "@/lib/utils/format";
import { EXPLORERS, CONTRACTS } from "@/lib/contracts/addresses";
import {
  ExternalLink, ArrowUpFromLine, ArrowDownToLine, ShieldAlert,
  Bitcoin, Coins, Zap, TrendingUp, AlertTriangle, CheckCircle2, RefreshCw,
} from "lucide-react";
import Link from "next/link";
import { Button } from "@/components/ui/Button";
import { HealthBadge } from "@/components/system/HealthBadge";
import { useAuthGuard } from "@/lib/hooks/useAuthGuard";
import { motion } from "framer-motion";

const FADE_UP = (delay = 0) => ({
  initial: { opacity: 0, y: 16 },
  animate: { opacity: 1, y: 0 },
  transition: { duration: 0.35, delay },
});

export default function PortfolioPage() {
  useAuthGuard();
  const { address }             = useAccount();
  const { data: wbtcBal }       = useWBTCBalance();
  const { data: ybtcBal }       = useYBTCBalance();
  const { data: metrics }       = useSystemMetrics();
  const { data: dash, loading: dashLoading } = useUserDashboard();
  const { data: claimable }     = useUserClaimableYield();

  // ── Prices / balances ────────────────────────────────────────────────────
  const btcPrice   = metrics ? pragmaToUSD(BigInt(metrics.btcUsdPrice)) : 95_000;
  const wbtcBal_   = wbtcBal ? BigInt(wbtcBal.toString()) : 0n;
  const ybtcBal_   = ybtcBal ? BigInt(ybtcBal.toString()) : 0n;

  // Share price from dashboard (single call). Fall back to metrics.sharePrice
  // (which is vault-level). 0 → 1.0 for fresh vault (handled in formatSharePrice).
  const sharePriceBigInt = dash?.sharePrice ?? metrics?.sharePrice ?? 0n;
  const sharePrice = Number(sharePriceBigInt) / 1_000_000 || 1;

  // ── User position from dashboard (correct data) ──────────────────────────
  // get_user_position tuple[0] = ybtc_balance, tuple[1] = BTC value (NOT debt).
  // Real per-user USD debt only comes from get_user_dashboard.user_debt_usd.
  const leverage_     = dash ? dash.currentLeverage : 100;

  // user_debt_usd is stored in Pragma 8-decimal format ($95k = 9_500_000_000_000).
  // Divide by 1e8 to get human-readable USD.
  const debtPragma_   = dash ? dash.userDebtUsd : 0n;
  const debtUSD       = Number(debtPragma_) / 1e8;

  // Collateral = BTC value of user's yBTC shares (from dashboard btc_value_sat)
  const collateralSat = dash ? dash.btcValueSat : 0n;
  const collateralBTC = Number(collateralSat) / 1e8;
  const collateralUSD = collateralBTC * btcPrice;

  const healthVal     = dash ? dash.healthFactor : 999999;
  const liqPriceUSD   = dash ? dash.liquidationPriceUsd / 1e8 : 0;
  const claimable_    = claimable ? BigInt(claimable.toString()) : 0n;
  const claimableUSD  = (Number(claimable_) / 1e8) * btcPrice;

  // ── Derived display values ────────────────────────────────────────────────
  const ybtcInBTC  = (Number(ybtcBal_) / 1e8) * sharePrice;
  const ybtcUSD    = ybtcInBTC * btcPrice;
  const wbtcUSD    = (Number(wbtcBal_) / 1e8) * btcPrice;

  const isLeveraged   = leverage_ > 100;
  const ltvPct        = collateralUSD > 0 ? ((debtUSD / collateralUSD) * 100).toFixed(1) : "0";
  const liqDistPct    = btcPrice > 0 && liqPriceUSD > 0
    ? (((btcPrice - liqPriceUSD) / btcPrice) * 100).toFixed(1)
    : null;

  // ── Unrealized P&L for leveraged positions ────────────────────────────────
  // Entry price = debtUSD / extraBTC  where  extraBTC = collateral × (lev − 1)
  const leverageFactor   = leverage_ / 100;
  const leveragedBTC     = collateralBTC * leverageFactor;         // total exposure
  const extraBTC         = collateralBTC * (leverageFactor - 1);   // borrowed BTC amount
  const entryPriceEst    = (isLeveraged && debtUSD > 0 && extraBTC > 0)
    ? debtUSD / extraBTC
    : btcPrice;
  const unrealizedPnlUSD = isLeveraged && btcPrice > 0
    ? (btcPrice - entryPriceEst) * extraBTC
    : 0;
  const unrealizedPnlPct = isLeveraged && entryPriceEst > 0
    ? ((btcPrice - entryPriceEst) / entryPriceEst) * leverageFactor * 100
    : 0;

  // Share price yield: how much extra BTC accrued per share above 1:1
  const yieldGainBTC = ybtcBal_ > 0n ? (Number(ybtcBal_) / 1e8) * (sharePrice - 1) : 0;
  const yieldGainUSD = yieldGainBTC * btcPrice;

  // Vault APY from dashboard (has real deployed_capital ratio), fall back to metrics estimate
  const displayApy   = (dash?.vaultApy ?? 0) > 0 ? (dash?.vaultApy ?? 0) : (metrics?.apy ?? 800);

  // Detect the "ghost leverage" state: user applied leverage when oracle price was 0,
  // so user_leverage was stored but no debt was recorded.
  const ghostLeverage = isLeveraged && debtUSD === 0;


  return (
    <AppLayout>
      <div className="space-y-6">

        {/* Header */}
        <motion.div {...FADE_UP()} className="flex items-start justify-between">
          <div>
            <h1 className="text-2xl font-bold text-white">Portfolio</h1>
            <p className="text-white/40 text-sm mt-1">
              Track your deposits, borrowed capital, strategy earnings and position health.
            </p>
          </div>
          <div className="flex gap-2">
            <Link href="/vault">
              <Button size="sm" variant="secondary">
                <ArrowDownToLine className="w-3.5 h-3.5" /> Deposit
              </Button>
            </Link>
            <Link href="/vault">
              <Button size="sm" variant="outline">
                <ArrowUpFromLine className="w-3.5 h-3.5" /> Withdraw
              </Button>
            </Link>
          </div>
        </motion.div>

        {/* Safe mode banner */}
        {metrics?.isSafeMode && (
          <motion.div {...FADE_UP(0.05)}>
            <div className="flex items-start gap-3 bg-red-500/10 border border-red-500/25 rounded-xl px-4 py-3">
              <ShieldAlert className="w-5 h-5 text-red-400 shrink-0 mt-0.5" />
              <div>
                <p className="text-sm font-semibold text-red-400">Safe Mode Active</p>
                <p className="text-xs text-white/50 mt-0.5">
                  BTC volatility is elevated. Deposits, withdrawals and new leverage are paused.
                  Your existing yield position continues to accrue normally.
                  {isLeveraged && " Monitor your health factor closely while leveraged."}
                </p>
              </div>
            </div>
          </motion.div>
        )}

        {/* ── SECTION 1: Balance snapshot ── */}
        <motion.div {...FADE_UP(0.08)}>
          <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
            <div className="bg-white/3 border border-white/6 rounded-xl p-4">
              <p className="text-[10px] text-white/40 uppercase tracking-wider mb-1.5">wBTC in Wallet</p>
              <p className="text-lg font-bold font-mono text-orange-400">{formatBTC(wbtcBal_)}</p>
              <p className="text-[10px] text-white/30 mt-0.5">{formatUSD(wbtcUSD)}</p>
            </div>
            <div className="bg-white/3 border border-white/6 rounded-xl p-4">
              <p className="text-[10px] text-white/40 uppercase tracking-wider mb-1.5">yBTC Shares</p>
              <p className="text-lg font-bold font-mono text-emerald-400">{formatBTC(ybtcBal_)}</p>
              <p className="text-[10px] text-white/30 mt-0.5">{formatUSD(ybtcUSD)}</p>
            </div>
            <div className="bg-white/3 border border-white/6 rounded-xl p-4">
              <p className="text-[10px] text-white/40 uppercase tracking-wider mb-1.5">Share Price</p>
              <p className="text-lg font-bold font-mono text-white">
                {formatSharePrice(sharePriceBigInt)}
              </p>
              <p className="text-[10px] text-white/30 mt-0.5">
                {sharePrice > 1 ? <span className="text-emerald-400">+{((sharePrice - 1) * 100).toFixed(4)}%</span> : "wBTC per yBTC"}
              </p>
            </div>
            <div className="bg-white/3 border border-white/6 rounded-xl p-4">
              <p className="text-[10px] text-white/40 uppercase tracking-wider mb-1.5">Est. APY</p>
              <p className="text-lg font-bold text-emerald-400">
                {bpsToPercent(displayApy)}
              </p>
              <p className="text-[10px] text-white/30 mt-0.5">
                {(dash?.vaultApy ?? 0) > 0 ? "live · strategy" : "est. · no strategy yet"}
              </p>
            </div>
          </div>
        </motion.div>

        {/* ── SECTION 2: Deposit + Borrowed capital ── */}
        <motion.div {...FADE_UP(0.12)} className="grid grid-cols-1 md:grid-cols-2 gap-4">

          {/* Vault deposit */}
          <Card glow="orange">
            <CardTitle className="flex items-center gap-1.5 mb-4">
              <Bitcoin className="w-3.5 h-3.5 text-orange-400" /> Your Vault Deposit
            </CardTitle>
            <div className="space-y-3">
              <div className="flex justify-between items-end">
                <p className="text-xs text-white/40">BTC Collateral (via yBTC)</p>
                <div className="text-right">
                  <p className="text-base font-bold font-mono text-white">
                    {collateralBTC > 0 ? `${collateralBTC.toFixed(8)} BTC` : "—"}
                  </p>
                  {collateralUSD > 0 && (
                    <p className="text-[10px] text-white/30">{formatUSD(collateralUSD)}</p>
                  )}
                </div>
              </div>
              <div className="flex justify-between items-end">
                <p className="text-xs text-white/40">yBTC Shares Received</p>
                <div className="text-right">
                  <p className="text-base font-bold font-mono text-emerald-400">
                    {ybtcBal_ > 0n ? formatBTC(ybtcBal_) : "—"} yBTC
                  </p>
                </div>
              </div>
              <div className="pt-2 border-t border-white/6">
                <div className="flex justify-between items-center">
                  <p className="text-xs text-white/40">Claimable Yield</p>
                  {claimable_ > 0n
                    ? <p className="text-sm font-bold text-emerald-400">+{formatBTC(claimable_)} wBTC</p>
                    : <p className="text-xs text-white/30">Accruing to share price…</p>
                  }
                </div>
              </div>
              {yieldGainBTC > 0 && (
                <div className="flex justify-between items-center">
                  <p className="text-xs text-white/40">Share price gain</p>
                  <p className="text-sm font-semibold text-emerald-400">
                    +{yieldGainBTC.toFixed(8)} wBTC
                    <span className="text-white/30 ml-1">({formatUSD(yieldGainUSD)})</span>
                  </p>
                </div>
              )}
            </div>
          </Card>

          {/* Borrowed capital */}
          <Card glow={isLeveraged ? "yellow" : undefined}>
            <CardTitle className="flex items-center gap-1.5 mb-4">
              <Coins className="w-3.5 h-3.5 text-yellow-400" /> Borrowed Capital
            </CardTitle>

            {/* Ghost leverage banner — leverage recorded but oracle was 0 at apply time */}
            {ghostLeverage && (
              <div className="flex items-start gap-3 bg-yellow-500/10 border border-yellow-500/20 rounded-xl px-4 py-3 mb-4">
                <AlertTriangle className="w-4 h-4 text-yellow-400 shrink-0 mt-0.5" />
                <div>
                  <p className="text-sm font-semibold text-yellow-400">Leverage recorded but not funded</p>
                  <p className="text-xs text-white/50 mt-0.5">
                    The BTC oracle was unavailable when you applied leverage, so no stablecoins were
                    borrowed. Re-apply your leverage now that the price feed is active.
                  </p>
                  <Link href="/leverage">
                    <Button size="sm" variant="secondary" className="mt-2 text-xs">Re-apply Leverage →</Button>
                  </Link>
                </div>
              </div>
            )}

            {debtUSD > 0 ? (
              <div className="space-y-3">
                <div className="flex justify-between items-end">
                  <p className="text-xs text-white/40">Stablecoins Borrowed</p>
                  <div className="text-right">
                    <p className="text-base font-bold font-mono text-yellow-400">{formatUSD(debtUSD)}</p>
                    <p className="text-[10px] text-white/30">Against your wBTC collateral</p>
                  </div>
                </div>
                <div className="flex justify-between items-center">
                  <p className="text-xs text-white/40">LTV Ratio</p>
                  <p className="text-sm font-semibold text-white">{ltvPct}%</p>
                </div>
                <div className="flex justify-between items-center">
                  <p className="text-xs text-white/40">Active Leverage</p>
                  <p className="text-sm font-bold text-yellow-400">{(leverage_ / 100).toFixed(2)}×</p>
                </div>
                <div className="flex justify-between items-center">
                  <p className="text-xs text-white/40">BTC Exposure</p>
                  <p className="text-sm font-semibold text-white">
                    {leveragedBTC > 0 ? `${leveragedBTC.toFixed(6)} BTC` : "—"}
                  </p>
                </div>
                {isLeveraged && (
                  <div className="flex justify-between items-center">
                    <p className="text-xs text-white/40">Entry Price (est.)</p>
                    <p className="text-sm font-mono text-white/70">{entryPriceEst > 0 ? formatUSD(entryPriceEst) : "—"}</p>
                  </div>
                )}
                <div className={`flex justify-between items-center pt-2 border-t border-white/6 ${
                  unrealizedPnlUSD > 0 ? "border-emerald-500/20" : unrealizedPnlUSD < 0 ? "border-red-500/20" : ""
                }`}>
                  <p className="text-xs text-white/40">Unrealised P&amp;L</p>
                  <div className="text-right">
                    <p className={`text-sm font-bold ${
                      unrealizedPnlUSD > 0 ? "text-emerald-400"
                      : unrealizedPnlUSD < 0 ? "text-red-400"
                      : "text-white/50"
                    }`}>
                      {unrealizedPnlUSD > 0 ? "+" : ""}
                      {formatUSD(unrealizedPnlUSD)}
                    </p>
                    <p className="text-[10px] text-white/30">
                      {unrealizedPnlPct > 0 ? "+" : ""}
                      {unrealizedPnlPct.toFixed(2)}% leveraged
                    </p>
                  </div>
                </div>
                <div className="pt-2 border-t border-white/6 text-[11px] text-white/30 space-y-1">
                  <p className="flex items-center gap-1.5">
                    <Zap className="w-3 h-3 text-yellow-400/60" />
                    Borrowed stables were used to buy more BTC.
                  </p>
                  <p className="flex items-center gap-1.5">
                    <TrendingUp className="w-3 h-3 text-emerald-400/60" />
                    BTC price appreciation amplifies your gains.
                  </p>
                </div>
              </div>
            ) : !ghostLeverage ? (
              <div className="flex flex-col items-center justify-center h-24 gap-2 text-center">
                <CheckCircle2 className="w-6 h-6 text-emerald-400/50" />
                <p className="text-xs text-white/40">No leverage active.</p>
                <p className="text-[10px] text-white/25">The vault auto-borrows stablecoins when you apply leverage.</p>
                <Link href="/leverage">
                  <Button size="sm" variant="secondary" className="mt-1 text-xs">Set Leverage</Button>
                </Link>
              </div>
            ) : null}
          </Card>
        </motion.div>

        {/* ── SECTION 3: Strategy Allocation ── */}
        <motion.div {...FADE_UP(0.16)}>
          <Card glass>
            <CardTitle className="flex items-center gap-1.5 mb-4">
              <TrendingUp className="w-3.5 h-3.5" /> Strategy Allocation
            </CardTitle>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-4">

              {/* Yield track */}
              <div className="rounded-xl bg-emerald-500/5 border border-emerald-500/10 p-4 space-y-2">
                <div className="flex items-center gap-2 mb-3">
                  <div className="w-2 h-2 rounded-full bg-emerald-400" />
                  <p className="text-xs font-semibold text-emerald-400 uppercase tracking-wider">Yield Strategy</p>
                  <span className="ml-auto text-[10px] text-emerald-400/60 bg-emerald-500/10 px-1.5 py-0.5 rounded-full">Always Active</span>
                </div>
                <p className="text-[11px] text-white/40 leading-relaxed">
                  The vault deploys borrowed stablecoins into lending pools and LP positions.
                  Profits are converted back to wBTC and added to the vault, causing the
                  yBTC share price to rise over time.
                </p>
                <div className="pt-2 border-t border-white/6 flex justify-between">
                  <span className="text-[10px] text-white/30">Your earnings</span>
                  <span className="text-[11px] text-emerald-400 font-medium">
                    {`${bpsToPercent(displayApy)} APY`}
                    {yieldGainBTC > 0 && ` · +${yieldGainBTC.toFixed(6)} wBTC`}
                  </span>
                </div>
              </div>

              {/* Leverage track */}
              <div className={`rounded-xl p-4 space-y-2 ${
                isLeveraged
                  ? "bg-yellow-500/5 border border-yellow-500/10"
                  : "bg-white/2 border border-white/6"
              }`}>
                <div className="flex items-center gap-2 mb-3">
                  <div className={`w-2 h-2 rounded-full ${isLeveraged ? "bg-yellow-400" : "bg-white/20"}`} />
                  <p className={`text-xs font-semibold uppercase tracking-wider ${isLeveraged ? "text-yellow-400" : "text-white/30"}`}>
                    Leverage Strategy
                  </p>
                  <span className={`ml-auto text-[10px] px-1.5 py-0.5 rounded-full ${
                    isLeveraged
                      ? "text-yellow-400/60 bg-yellow-500/10"
                      : "text-white/20 bg-white/5"
                  }`}>
                    {isLeveraged ? `${(leverage_ / 100).toFixed(2)}× active` : "Inactive"}
                  </span>
                </div>
                <p className="text-[11px] text-white/40 leading-relaxed">
                  {isLeveraged
                    ? "The vault borrowed stablecoins to purchase additional BTC on your behalf. Your exposure is amplified — gains and losses are multiplied by your leverage factor."
                    : "Enable leverage to have the vault borrow stablecoins and buy more BTC for you. Amplifies gains and losses."
                  }
                </p>
                <div className="pt-2 border-t border-white/6 flex justify-between">
                  <span className="text-[10px] text-white/30">
                    {isLeveraged ? "Debt outstanding" : "Leverage"}
                  </span>
                  <span className={`text-[11px] font-medium ${isLeveraged ? "text-yellow-400" : "text-white/30"}`}>
                    {isLeveraged ? formatUSD(debtUSD) : "Not applied"}
                  </span>
                </div>
              </div>
            </div>
          </Card>
        </motion.div>

        {/* ── SECTION 4: Health + Liquidation ── */}
        {(isLeveraged || healthVal > 0) && (
          <motion.div {...FADE_UP(0.2)}>
            <Card glow={healthVal > 0 ? (healthVal >= 150 ? "green" : healthVal >= 120 ? undefined : "red") : undefined}>
              <CardTitle className="flex items-center gap-1.5 mb-4">
                <AlertTriangle className="w-3.5 h-3.5 text-orange-400" /> Position Health
              </CardTitle>
              <div className="grid grid-cols-1 md:grid-cols-3 gap-4 mb-4">
                <div>
                  <p className="text-xs text-white/40 mb-2">Health Factor</p>
                  {healthVal > 0
                    ? <HealthBadge health={healthVal} size="md" />
                    : <span className="text-sm text-white/30">No active position</span>
                  }
                  <p className="text-[10px] text-white/25 mt-1.5">
                    &lt;1.00 = liquidatable · 1.20 = caution · &gt;1.50 = safe
                  </p>
                </div>
                <div>
                  <p className="text-xs text-white/40 mb-2">Liquidation Price</p>
                  {liqPriceUSD > 0
                    ? <p className="text-xl font-bold font-mono text-orange-400">{formatUSD(liqPriceUSD)}</p>
                    : <p className="text-sm text-white/30">—</p>
                  }
                  {liqDistPct && (
                    <p className="text-[10px] text-white/30 mt-1">
                      BTC must drop <span className="text-orange-400">{liqDistPct}%</span> from current price
                    </p>
                  )}
                </div>
                <div>
                  <p className="text-xs text-white/40 mb-2">Current BTC Price</p>
                  <p className="text-xl font-bold font-mono text-white">
                    {btcPrice > 0 ? formatUSD(btcPrice) : "—"}
                  </p>
                  <p className="text-[10px] text-white/25 mt-1">Pragma oracle</p>
                </div>
              </div>
              {healthVal > 0 && healthVal < 130 && (
                <div className="flex items-start gap-3 bg-orange-500/8 border border-orange-500/15 rounded-xl px-3 py-2.5">
                  <AlertTriangle className="w-4 h-4 text-orange-400 shrink-0 mt-0.5" />
                  <p className="text-xs text-white/60">
                    <span className="text-orange-400 font-medium">Warning: </span>
                    Your health factor is below 1.30. The User Guardian agent will flag your position.
                    {healthVal < 110 && " Consider reducing leverage immediately to avoid liquidation."}
                  </p>
                </div>
              )}
            </Card>
          </motion.div>
        )}

        {/* ── SECTION 5: Active position actions + token refs ── */}
        <motion.div {...FADE_UP(0.24)} className="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <div>
            <h2 className="text-xs font-medium text-white/40 uppercase tracking-wider mb-3">Position Actions</h2>
            <PositionCard />
          </div>
          <div>
            <h2 className="text-xs font-medium text-white/40 uppercase tracking-wider mb-3">Token Addresses</h2>
            <Card glass>
              <div className="space-y-2">
                {[
                  { name: "wBTC (Mock)", addr: CONTRACTS.MockWBTC, href: EXPLORERS.MockWBTC, color: "text-orange-400" },
                  { name: "yBTC (Receipt)", addr: CONTRACTS.YBTCToken, href: EXPLORERS.YBTCToken, color: "text-emerald-400" },
                  { name: "BTCVault", addr: CONTRACTS.BTCVault, href: EXPLORERS.BTCVault, color: "text-blue-400" },
                ].map(({ name, addr, href, color }) => (
                  <a
                    key={name}
                    href={href}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="flex items-center justify-between p-3 rounded-xl bg-white/3 hover:bg-white/5 transition-colors group"
                  >
                    <div>
                      <p className={`text-sm font-semibold ${color}`}>{name}</p>
                      <p className="text-[10px] font-mono text-white/30 mt-0.5 break-all">{addr}</p>
                    </div>
                    <ExternalLink className="w-3.5 h-3.5 text-white/20 group-hover:text-white/50 shrink-0 ml-2" />
                  </a>
                ))}
              </div>
            </Card>
          </div>
        </motion.div>

      </div>
    </AppLayout>
  );
}
