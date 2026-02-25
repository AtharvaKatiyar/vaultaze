"use client";

import { AppLayout } from "@/components/layout/AppLayout";
import { MetricsRow } from "@/components/system/MetricsRow";
import { Card, CardTitle } from "@/components/ui/Card";
import { Button } from "@/components/ui/Button";
import { HealthBadge } from "@/components/system/HealthBadge";
import { useSystemMetrics } from "@/lib/hooks/useRouterData";
import { formatBTC, formatUSD, pragmaToUSD, bpsToPercent, formatLeverage } from "@/lib/utils/format";
import { ArrowRight, Bitcoin, Shield, TrendingUp, Zap, ExternalLink, Activity, Lock } from "lucide-react";
import Link from "next/link";
import { motion } from "framer-motion";
import { EXPLORERS } from "@/lib/contracts/addresses";

const FADE_UP = (delay = 0) => ({
  initial: { opacity: 0, y: 20 },
  animate: { opacity: 1, y: 0 },
  transition: { duration: 0.4, delay },
});

export default function DashboardPage() {
  const { data: metrics } = useSystemMetrics();
  const btcPrice = metrics ? pragmaToUSD(BigInt(metrics.btcUsdPrice)) : 0;

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
                  <span className="text-sm text-white">{value ?? <span className="text-white/20 animate-pulse text-xs">Loading…</span>}</span>
                </div>
              ))}
            </div>
          </Card>
          <Card glass>
            <CardTitle className="flex items-center gap-1.5 mb-4"><Lock className="w-3.5 h-3.5" /> Deployed Contracts (Sepolia)</CardTitle>
            <div className="space-y-2">
              {[
                { name: "BTCVault", addr: "0x0047…6f08", href: EXPLORERS.BTCVault },
                { name: "BTCSecurityRouter", addr: "0x014c…2639", href: EXPLORERS.BTCSecurityRouter },
                { name: "YBTCToken", addr: "0x04ea…8166", href: EXPLORERS.YBTCToken },
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
          <Card glass>
            <CardTitle className="flex items-center gap-1.5 mb-5"><Shield className="w-3.5 h-3.5" /> How It Works</CardTitle>
            <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
              {[
                { step: "01", title: "Bridge BTC", desc: "Send BTC to Starknet via a bridge and receive wBTC 1:1." },
                { step: "02", title: "Deposit wBTC", desc: "Deposit into the vault to receive yBTC yield-bearing shares." },
                { step: "03", title: "Earn Yield", desc: "The vault deploys capital to DeFi strategies, yield accrues to share price." },
                { step: "04", title: "Withdraw Anytime", desc: "Burn yBTC to redeem proportional wBTC principal + yield." },
              ].map(({ step, title, desc }) => (
                <div key={step} className="flex flex-col gap-2">
                  <div className="w-7 h-7 rounded-lg bg-orange-500/15 text-orange-400 text-xs font-bold flex items-center justify-center">{step}</div>
                  <p className="text-sm font-semibold text-white">{title}</p>
                  <p className="text-xs text-white/40">{desc}</p>
                </div>
              ))}
            </div>
          </Card>
        </motion.div>
      </div>
    </AppLayout>
  );
}
