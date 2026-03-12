"use client";

import { useAuthGuard } from "@/lib/hooks/useAuthGuard";
import { AppLayout } from "@/components/layout/AppLayout";
import { MetricsRow } from "@/components/system/MetricsRow";
import { Card, CardTitle } from "@/components/ui/Card";
import { Button } from "@/components/ui/Button";
import { HealthBadge } from "@/components/system/HealthBadge";
import { useSystemMetrics } from "@/lib/hooks/useRouterData";
import { useWBTCBalance, useYBTCBalance, useUserPosition, useUserHealth, useUserDashboard, toBalance } from "@/lib/hooks/useUserPosition";
import { formatBTC, formatUSD, pragmaToUSD, bpsToPercent, formatLeverage, formatSharePrice } from "@/lib/utils/format";
import {
  ArrowRight, Bitcoin, TrendingUp, Zap, ExternalLink, Activity, Lock,
  CheckCircle2, Circle, Eye, RefreshCw, UserCheck, AlertTriangle,
  ShieldAlert, Cpu, Coins, Gift
} from "lucide-react";
import Link from "next/link";
import { motion } from "framer-motion";
import { EXPLORERS } from "@/lib/contracts/addresses";

const FADE_UP = (delay = 0) => ({
  initial: { opacity: 0, y: 20 },
  animate: { opacity: 1, y: 0 },
  transition: { duration: 0.4, delay },
});

export default function DashboardPage() {
  useAuthGuard();
  const { data: metrics }   = useSystemMetrics();
  const { data: wbtcBal }   = useWBTCBalance();
  const { data: ybtcBal }   = useYBTCBalance();
  const { data: position }  = useUserPosition();
  const { data: health }    = useUserHealth();
  const { data: dash }      = useUserDashboard();

  const FALLBACK_BTC_PRICE = 95_000;
  const rawBtcPrice  = metrics ? pragmaToUSD(BigInt(metrics.btcUsdPrice)) : 0;
  const btcPrice     = rawBtcPrice > 0 ? rawBtcPrice : (metrics ? FALLBACK_BTC_PRICE : 0);
  const hasWBTC     = wbtcBal   ? BigInt(wbtcBal.toString())  > 0n : false;
  const hasYBTC     = ybtcBal   ? BigInt(ybtcBal.toString())  > 0n : false;
  const hasLeverage = position  ? Number((position as any)[2] ?? 100) > 100 : false;
  const healthVal   = health    ? Number(health.toString()) : 0;

  // Derived dashboard values
  const yBal           = toBalance(ybtcBal);
  const sharePriceRaw  = Number(dash?.sharePrice ?? metrics?.sharePrice ?? 1_000_000n);
  const sharePriceRatio = sharePriceRaw > 0 ? sharePriceRaw / 1_000_000 : 1;
  const vaultValueBTC  = (Number(yBal) / 1e8) * sharePriceRatio;
  const vaultValueUSD  = vaultValueBTC * btcPrice;
  const yieldGainBTC   = (Number(yBal) / 1e8) * (sharePriceRatio - 1);
  const claimableYield = dash?.claimableYieldSat ?? 0n;
  const leverage_      = dash?.currentLeverage ?? 100;
  const isLeveraged    = leverage_ > 100;

  return (
    <AppLayout>
      <div className="space-y-8">
        <motion.div {...FADE_UP()} className="pt-2">
          <h1 className="text-3xl font-bold text-white mb-2">
            Bitcoin Yield Vault
            <span className="ml-3 inline-flex items-center text-xs font-normal bg-orange-500/15 text-orange-400 border border-orange-500/20 rounded-full px-2.5 py-0.5">
              Starknet Sepolia
            </span>
          </h1>
          <p className="text-white/40 text-sm max-w-xl">
            Earn yield on your BTC secured by the autonomous BTC Security Router.
            Deposits and leverage are gated by real-time global health factors.
          </p>
        </motion.div>

        <motion.div {...FADE_UP(0.05)}><MetricsRow /></motion.div>

        {/* ─── Position Summary ─────────────────────────────────────── */}
        {hasYBTC && (
          <motion.div {...FADE_UP(0.08)}>
            <Card glass className="border-emerald-500/20 bg-emerald-950/10">
              <div className="flex flex-wrap items-center justify-between gap-4">
                <div>
                  <p className="text-xs text-emerald-400/60 uppercase tracking-wider mb-1">Your Vault Position</p>
                  <div className="flex items-baseline gap-2">
                    <span className="text-2xl font-bold text-white font-mono">{vaultValueBTC.toFixed(6)}</span>
                    <span className="text-sm text-white/40">wBTC value</span>
                    <span className="text-sm text-white/30">({formatUSD(vaultValueUSD)})</span>
                  </div>
                </div>
                <div className="flex flex-wrap gap-3">
                  {/* Share price gain */}
                  {sharePriceRatio > 1 && (
                    <div className="flex items-center gap-2 bg-emerald-500/10 border border-emerald-500/20 rounded-xl px-3 py-2">
                      <TrendingUp className="w-3.5 h-3.5 text-emerald-400" />
                      <div>
                        <p className="text-[10px] text-emerald-400/70">Share price</p>
                        <p className="text-sm font-mono font-semibold text-emerald-300">
                          {formatSharePrice(dash?.sharePrice ?? metrics?.sharePrice)}
                          <span className="ml-1 text-xs text-emerald-400">(+{((sharePriceRatio - 1) * 100).toFixed(4)}%)</span>
                        </p>
                      </div>
                    </div>
                  )}
                  {/* Yield gained */}
                  {yieldGainBTC > 0 && (
                    <div className="flex items-center gap-2 bg-emerald-500/8 border border-emerald-500/15 rounded-xl px-3 py-2">
                      <Coins className="w-3.5 h-3.5 text-emerald-400" />
                      <div>
                        <p className="text-[10px] text-emerald-400/70">Yield earned</p>
                        <p className="text-sm font-mono font-semibold text-emerald-300">+{yieldGainBTC.toFixed(8)} BTC</p>
                      </div>
                    </div>
                  )}
                  {/* Claimable yield */}
                  {claimableYield > 0n && (
                    <Link href="/portfolio">
                      <div className="flex items-center gap-2 bg-emerald-500/15 border border-emerald-400/30 rounded-xl px-3 py-2 cursor-pointer hover:bg-emerald-500/20 transition-colors">
                        <Gift className="w-3.5 h-3.5 text-emerald-300" />
                        <div>
                          <p className="text-[10px] text-emerald-300/80">Claimable yield ↗</p>
                          <p className="text-sm font-mono font-bold text-emerald-300">+{formatBTC(claimableYield)} wBTC</p>
                        </div>
                      </div>
                    </Link>
                  )}
                  {/* Leverage */}
                  <div className={`flex items-center gap-2 border rounded-xl px-3 py-2 ${
                    isLeveraged
                      ? "bg-yellow-500/10 border-yellow-500/20"
                      : "bg-white/5 border-white/10"
                  }`}>
                    <Zap className={`w-3.5 h-3.5 ${isLeveraged ? "text-yellow-400" : "text-white/30"}`} />
                    <div>
                      <p className={`text-[10px] ${isLeveraged ? "text-yellow-400/70" : "text-white/30"}`}>Leverage</p>
                      <p className={`text-sm font-semibold ${isLeveraged ? "text-yellow-300" : "text-white/30"}`}>
                        {isLeveraged ? formatLeverage(leverage_) : "None"}
                      </p>
                    </div>
                  </div>
                </div>
              </div>
            </Card>
          </motion.div>
        )}

        <motion.div {...FADE_UP(0.1)} className="grid grid-cols-1 md:grid-cols-3 gap-4">
          <Link href="/vault">
            <Card glow="orange" className="cursor-pointer hover:border-orange-500/30 transition-all group">
              <div className="flex items-start justify-between">
                <div>
                  <CardTitle className="flex items-center gap-1.5"><Bitcoin className="w-3.5 h-3.5 text-orange-400" /> Deposit wBTC</CardTitle>
                  <p className="text-white/50 text-xs mt-2">Convert wBTC → yBTC yield-bearing shares. Min 0.01 BTC.</p>
                </div>
                <ArrowRight className="w-4 h-4 text-white/20 group-hover:text-orange-400 transition-colors mt-1" />
              </div>
              <div className="mt-4"><Button size="sm" className="pointer-events-none">Deposit Now</Button></div>
            </Card>
          </Link>
          <Link href="/leverage">
            <Card glow="yellow" className="cursor-pointer hover:border-yellow-500/30 transition-all group">
              <div className="flex items-start justify-between">
                <div>
                  <CardTitle className="flex items-center gap-1.5"><Zap className="w-3.5 h-3.5 text-yellow-400" /> Apply Leverage</CardTitle>
                  <p className="text-white/50 text-xs mt-2">Amplify returns up to {metrics ? formatLeverage(metrics.maxLeverage) : "—"} (router max).</p>
                </div>
                <ArrowRight className="w-4 h-4 text-white/20 group-hover:text-yellow-400 transition-colors mt-1" />
              </div>
              <div className="mt-4"><Button size="sm" variant="secondary" className="pointer-events-none">Manage Leverage</Button></div>
            </Card>
          </Link>
          <Link href="/portfolio">
            <Card glow="green" className="cursor-pointer hover:border-emerald-500/30 transition-all group">
              <div className="flex items-start justify-between">
                <div>
                  <CardTitle className="flex items-center gap-1.5"><TrendingUp className="w-3.5 h-3.5 text-emerald-400" /> My Portfolio</CardTitle>
                  <p className="text-white/50 text-xs mt-2">Track your yBTC balance, PnL, yield and position health.</p>
                </div>
                <ArrowRight className="w-4 h-4 text-white/20 group-hover:text-emerald-400 transition-colors mt-1" />
              </div>
              <div className="mt-4"><Button size="sm" variant="secondary" className="pointer-events-none">View Portfolio</Button></div>
            </Card>
          </Link>
        </motion.div>

        <motion.div {...FADE_UP(0.15)} className="grid grid-cols-1 md:grid-cols-2 gap-4">
          <Card glass>
            <CardTitle className="flex items-center gap-1.5 mb-4"><Activity className="w-3.5 h-3.5" /> System Status</CardTitle>
            <div className="space-y-3">
              {[
                { label: "BTC Health", value: metrics ? <HealthBadge health={metrics.btcHealth} size="sm" /> : null },
                { label: "Safe Mode", value: metrics ? <span className={metrics.isSafeMode ? "text-red-400" : "text-emerald-400"}>{metrics.isSafeMode ? "Active ⚠" : "Inactive ✓"}</span> : null },
                { label: "BTC / USD", value: metrics ? <span className="font-mono">{formatUSD(btcPrice)}</span> : null },
                { label: "Price Feed", value: metrics ? <span className={metrics.isPriceFresh ? "text-emerald-400" : "text-orange-400"}>{metrics.isPriceFresh ? "✓ Fresh" : "⚠ Stale"}</span> : null },
                { label: "Total Assets", value: metrics ? <span className="font-mono">{formatBTC(metrics.totalAssets, 4)} BTC</span> : null },
              ].map(({ label, value }) => (
                <div key={label} className="flex items-center justify-between">
                  <span className="text-sm text-white/50">{label}</span>
                  <span className="text-sm text-white">{value ?? <span className="text-white/40 animate-pulse text-xs">Loading…</span>}</span>
                </div>
              ))}
            </div>
          </Card>
          <Card glass>
            <CardTitle className="flex items-center gap-1.5 mb-4"><Lock className="w-3.5 h-3.5" /> Deployed Contracts (Sepolia)</CardTitle>
            <div className="space-y-2">
              {[
                { name: "BTCVault", addr: "0x6e33…166", href: EXPLORERS.BTCVault },
                { name: "BTCSecurityRouter", addr: "0x6e07…8a5", href: EXPLORERS.BTCSecurityRouter },
                { name: "YBTCToken", addr: "0x0310…b8a", href: EXPLORERS.YBTCToken },
                { name: "Mock wBTC", addr: "0x0129…b446", href: EXPLORERS.MockWBTC },
              ].map(({ name, addr, href }) => (
                <a key={name} href={href} target="_blank" rel="noopener noreferrer"
                  className="flex items-center justify-between px-3 py-2 rounded-lg bg-white/3 hover:bg-white/6 transition-colors group">
                  <div>
                    <p className="text-xs font-medium text-white/80 group-hover:text-white">{name}</p>
                    <p className="text-[10px] font-mono text-white/30">{addr}</p>
                  </div>
                  <ExternalLink className="w-3 h-3 text-white/20 group-hover:text-orange-400 transition-colors" />
                </a>
              ))}
            </div>
          </Card>
        </motion.div>

        <motion.div {...FADE_UP(0.2)}>
          {/* ── Safe-mode banner ── */}
          {metrics?.isSafeMode && (
            <div className="mb-4 flex items-start gap-3 bg-red-500/10 border border-red-500/25 rounded-xl px-4 py-3">
              <ShieldAlert className="w-5 h-5 text-red-400 shrink-0 mt-0.5" />
              <div>
                <p className="text-sm font-semibold text-red-400">Safe Mode Active</p>
                <p className="text-xs text-white/50 mt-0.5">
                  BTC dropped &gt;10% in the last hour or volatility exceeded 80%.
                  New deposits, leveraging and withdrawals are paused. Yield continues accruing.
                </p>
              </div>
            </div>
          )}

          {/* ── Your Journey ── */}
          <Card glass className="mb-4">
            <CardTitle className="flex items-center gap-1.5 mb-5">
              <TrendingUp className="w-3.5 h-3.5 text-orange-400" /> Your BTC Journey
            </CardTitle>
            <div className="relative">
              {/* connector line */}
              <div className="absolute left-3 top-4 bottom-4 w-px bg-white/8 hidden sm:block" />
              <div className="space-y-5">
                {[
                  {
                    done: true,
                    label: "Connect Wallet",
                    desc: "Your wallet is connected to Starknet Sepolia.",
                    action: null,
                  },
                  {
                    done: hasWBTC,
                    label: "Get wBTC",
                    desc: hasWBTC
                      ? `You have ${formatBTC(BigInt(wbtcBal!.toString()))} wBTC in your wallet.`
                      : "Bridge BTC from mainnet or use the Sepolia faucet to get test wBTC.",
                    action: !hasWBTC ? { label: "Open Faucet", href: "/faucet" } : null,
                  },
                  {
                    done: hasYBTC,
                    label: "Deposit wBTC → Mint yBTC",
                    desc: hasYBTC
                      ? `You hold yBTC shares. Yield is accruing to the share price.`
                      : "Deposit wBTC into the vault to receive yBTC yield-bearing shares.",
                    action: !hasYBTC ? { label: "Deposit Now", href: "/vault" } : null,
                  },
                  {
                    done: hasYBTC,
                    label: "Choose Your Strategy",
                    desc: hasLeverage
                      ? "Leverage active. The vault borrowed stablecoins to buy more BTC for you."
                      : hasYBTC
                        ? "Yield strategy running. Set leverage on the Leverage page to amplify returns."
                        : "After depositing, pick yield (auto) or leverage (manual) to grow your position.",
                    action: hasYBTC && !hasLeverage
                      ? { label: "Set Leverage", href: "/leverage" }
                      : null,
                  },
                  {
                    done: hasYBTC,
                    label: "Track Your Profits",
                    desc: "Monitor your deposited wBTC, borrowed stablecoins, yield earnings and leverage PnL.",
                    action: hasYBTC ? { label: "Open Portfolio", href: "/portfolio" } : null,
                  },
                ].map(({ done, label, desc, action }, i) => (
                  <div key={i} className="flex items-start gap-4 pl-0 sm:pl-8 relative">
                    <div className="absolute left-0 top-0 hidden sm:flex w-6 h-6 rounded-full items-center justify-center shrink-0 z-10"
                         style={{ background: done ? "rgba(52,211,153,0.15)" : "rgba(255,255,255,0.05)" }}>
                      {done
                        ? <CheckCircle2 className="w-4 h-4 text-emerald-400" />
                        : <Circle className="w-4 h-4 text-white/20" />
                      }
                    </div>
                    <div className="flex-1 min-w-0">
                      <div className="flex items-center gap-2 flex-wrap">
                        <p className={`text-sm font-semibold ${done ? "text-white" : "text-white/40"}`}>{label}</p>
                        {done && <span className="text-[10px] text-emerald-400 bg-emerald-400/10 px-1.5 py-0.5 rounded-full font-medium">Done</span>}
                      </div>
                      <p className="text-xs text-white/40 mt-0.5">{desc}</p>
                    </div>
                    {action && (
                      <Link href={action.href}>
                        <Button size="sm" variant="secondary" className="shrink-0 text-xs">
                          {action.label} <ArrowRight className="w-3 h-3" />
                        </Button>
                      </Link>
                    )}
                  </div>
                ))}
              </div>
            </div>
          </Card>

          {/* ── Autonomous Agents ── */}
          <Card glass>
            <CardTitle className="flex items-center gap-1.5 mb-5">
              <Cpu className="w-3.5 h-3.5 text-orange-400" /> Autonomous Agents
              <span className="ml-auto text-[10px] text-white/30 font-normal">Running off-chain · call public contract functions only</span>
            </CardTitle>
            <div className="grid grid-cols-1 md:grid-cols-3 gap-3">

              {/* Risk Sentinel */}
              <div className="rounded-xl bg-white/3 border border-white/6 p-4 space-y-3">
                <div className="flex items-center gap-2">
                  <div className="w-7 h-7 rounded-lg bg-red-500/15 flex items-center justify-center">
                    <Eye className="w-4 h-4 text-red-400" />
                  </div>
                  <div>
                    <p className="text-xs font-semibold text-white">Risk Sentinel</p>
                    <p className="text-[10px] text-white/30">Price monitor</p>
                  </div>
                  <span className={`ml-auto text-[10px] font-medium px-1.5 py-0.5 rounded-full ${
                    metrics?.isSafeMode
                      ? "bg-red-500/15 text-red-400"
                      : "bg-emerald-500/15 text-emerald-400"
                  }`}>
                    {metrics?.isSafeMode ? "Safe Mode ON" : "Monitoring"}
                  </span>
                </div>
                <div className="space-y-1.5 text-[11px] text-white/40">
                  <p className="flex justify-between"><span>Watches</span><span className="text-white/60">3 exchanges</span></p>
                  <p className="flex justify-between"><span>Triggers on</span><span className="text-white/60">&gt;10% 1h drop</span></p>
                  <p className="flex justify-between"><span>Or volatility</span><span className="text-white/60">&gt;80% annualised</span></p>
                  <p className="flex justify-between"><span>Safe Mode now</span>
                    <span className={metrics?.isSafeMode ? "text-red-400" : "text-emerald-400"}>
                      {metrics ? (metrics.isSafeMode ? "Active ⚠" : "Inactive ✓") : "—"}
                    </span>
                  </p>
                </div>
              </div>

              {/* Strategy Rebalancer */}
              <div className="rounded-xl bg-white/3 border border-white/6 p-4 space-y-3">
                <div className="flex items-center gap-2">
                  <div className="w-7 h-7 rounded-lg bg-purple-500/15 flex items-center justify-center">
                    <RefreshCw className="w-4 h-4 text-purple-400" />
                  </div>
                  <div>
                    <p className="text-xs font-semibold text-white">Strategy Rebalancer</p>
                    <p className="text-[10px] text-white/30">Yield & leverage</p>
                  </div>
                  <span className="ml-auto text-[10px] font-medium px-1.5 py-0.5 rounded-full bg-purple-500/15 text-purple-400">
                    Active
                  </span>
                </div>
                <div className="space-y-1.5 text-[11px] text-white/40">
                  <p className="flex justify-between"><span>Yield accrual</span><span className="text-white/60">Hourly</span></p>
                  <p className="flex justify-between"><span>Oracle refresh</span><span className="text-white/60">Each cycle</span></p>
                  <p className="flex justify-between"><span>Lev. reduced at</span><span className="text-white/60">Health &lt;1.20</span></p>
                  <p className="flex justify-between"><span>Current APY</span>
                    <span className="text-emerald-400">
                      {metrics ? bpsToPercent(metrics.apy) : "—"}
                    </span>
                  </p>
                </div>
              </div>

              {/* User Guardian */}
              <div className="rounded-xl bg-white/3 border border-white/6 p-4 space-y-3">
                <div className="flex items-center gap-2">
                  <div className="w-7 h-7 rounded-lg bg-yellow-500/15 flex items-center justify-center">
                    <UserCheck className="w-4 h-4 text-yellow-400" />
                  </div>
                  <div>
                    <p className="text-xs font-semibold text-white">User Guardian</p>
                    <p className="text-[10px] text-white/30">Liquidation bot</p>
                  </div>
                  <span className="ml-auto text-[10px] font-medium px-1.5 py-0.5 rounded-full bg-yellow-500/15 text-yellow-400">
                    Watching
                  </span>
                </div>
                <div className="space-y-1.5 text-[11px] text-white/40">
                  <p className="flex justify-between"><span>Liquidates at</span><span className="text-white/60">Health ≤ 1.00</span></p>
                  <p className="flex justify-between"><span>Warns at</span><span className="text-white/60">Health ≤ 1.30</span></p>
                  <p className="flex justify-between"><span>Retry cooldown</span><span className="text-white/60">60 seconds</span></p>
                  <p className="flex justify-between"><span>Your health</span>
                    <span className={healthVal > 0
                      ? healthVal >= 150 ? "text-emerald-400"
                        : healthVal >= 130 ? "text-yellow-400"
                          : "text-red-400"
                      : "text-white/40"
                    }>
                      {healthVal > 0 ? (healthVal / 100).toFixed(2) + "x" : "No leverage"}
                    </span>
                  </p>
                </div>
              </div>

            </div>
          </Card>
        </motion.div>
      </div>
    </AppLayout>
  );
}
