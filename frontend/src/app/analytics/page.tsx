"use client";

import { AppLayout } from "@/components/layout/AppLayout";
import { Card, CardTitle } from "@/components/ui/Card";
import { useSystemMetrics, useRouterBacking, useRouterExposure } from "@/lib/hooks/useRouterData";
import { formatBTC, formatUSD, pragmaToUSD, bpsToPercent, formatHealth, formatLeverage } from "@/lib/utils/format";
import { HealthBadge } from "@/components/system/HealthBadge";
import {
  AreaChart, Area, XAxis, YAxis, Tooltip,
  ResponsiveContainer, CartesianGrid, PieChart, Pie, Cell
} from "recharts";
import { CONTRACTS, EXPLORERS } from "@/lib/contracts/addresses";
import { ExternalLink, BarChart3, Eye, RefreshCw, UserCheck, ShieldAlert } from "lucide-react";
import { useAuthGuard } from "@/lib/hooks/useAuthGuard";

// Mock historical data for charts (replace with real indexer data in production)
const healthHistory = [
  { time: "Jan", health: 1.55 }, { time: "Feb", health: 1.48 }, { time: "Mar", health: 1.42 },
  { time: "Apr", health: 1.38 }, { time: "May", health: 1.44 }, { time: "Jun", health: 1.50 },
  { time: "Jul", health: 1.47 }, { time: "Aug", health: 1.42 },
];

const tvlHistory = [
  { time: "Jan", tvl: 0.2 }, { time: "Feb", tvl: 0.35 }, { time: "Mar", tvl: 0.48 },
  { time: "Apr", tvl: 0.42 }, { time: "May", tvl: 0.55 }, { time: "Jun", tvl: 0.6 },
  { time: "Jul", tvl: 0.52 }, { time: "Aug", tvl: 0.5 },
];

const apyHistory = [
  { time: "Jan", apy: 6.5 }, { time: "Feb", apy: 7.2 }, { time: "Mar", apy: 7.8 },
  { time: "Apr", apy: 6.9 }, { time: "May", apy: 8.1 }, { time: "Jun", apy: 8.5 },
  { time: "Jul", apy: 7.6 }, { time: "Aug", apy: 7.9 },
];

const CHART_TOOLTIP_STYLE = {
  backgroundColor: "#0f1117",
  border: "1px solid rgba(255,255,255,0.08)",
  borderRadius: "12px",
  fontSize: "12px",
  color: "#fff",
};

export default function AnalyticsPage() {
  useAuthGuard();
  const { data: metrics }   = useSystemMetrics();
  const { data: backing }   = useRouterBacking();
  const { data: exposure }  = useRouterExposure();

  const btcPrice   = metrics ? pragmaToUSD(BigInt(metrics.btcUsdPrice)) : 0;
  const backingBTC = backing  ? Number(BigInt(backing.toString())) / 1e8 : 0;
  const exposBTC   = exposure ? Number(BigInt(exposure.toString())) / 1e8 : 0;

  const utilizationPct = backingBTC > 0 ? ((exposBTC / backingBTC) * 100).toFixed(1) : "0";

  const PIE_DATA = [
    { name: "Backing",   value: backingBTC,         color: "#34d399" },
    { name: "Exposure",  value: exposBTC,            color: "#f97316" },
  ];

  return (
    <AppLayout>
      <div className="space-y-6">

        <div>
          <h1 className="text-2xl font-bold text-white">Analytics</h1>
          <p className="text-white/40 text-sm mt-1">System health, TVL and yield metrics.</p>
        </div>

        {/* Live metrics */}
        <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
          {[
            { label: "BTC Health",    value: metrics ? <HealthBadge health={metrics.btcHealth} size="sm" /> : null },
            { label: "BTC Price",     value: metrics ? formatUSD(btcPrice) : "—", mono: true },
            { label: "APY",           value: metrics ? bpsToPercent(metrics.apy) : "—", color: "text-emerald-400" },
            { label: "Max Leverage",  value: metrics ? formatLeverage(metrics.maxLeverage) : "—", color: "text-orange-400" },
          ].map(({ label, value, mono, color }) => (
            <Card key={label}>
              <p className="text-xs text-white/40 uppercase tracking-wider mb-2">{label}</p>
              {typeof value === "string"
                ? <p className={`text-xl font-bold ${color ?? "text-white"} ${mono ? "font-mono" : ""}`}>{value}</p>
                : <div className="mt-1">{value ?? <span className="animate-pulse text-white/20 text-xs">Loading…</span>}</div>
              }
            </Card>
          ))}
        </div>

        {/* Charts row */}
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">

          {/* BTC Health history */}
          <Card>
            <CardTitle className="mb-4 flex items-center gap-1.5">
              <BarChart3 className="w-3.5 h-3.5" /> BTC Health Factor (Historical)
            </CardTitle>
            <ResponsiveContainer width="100%" height={180}>
              <AreaChart data={healthHistory}>
                <defs>
                  <linearGradient id="hGrad" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="5%"  stopColor="#34d399" stopOpacity={0.3} />
                    <stop offset="95%" stopColor="#34d399" stopOpacity={0} />
                  </linearGradient>
                </defs>
                <CartesianGrid strokeDasharray="3 3" stroke="rgba(255,255,255,0.04)" />
                <XAxis dataKey="time" tick={{ fill: "rgba(255,255,255,0.3)", fontSize: 11 }} axisLine={false} tickLine={false} />
                <YAxis domain={[1.0, 2.0]} tick={{ fill: "rgba(255,255,255,0.3)", fontSize: 11 }} axisLine={false} tickLine={false} width={30} />
                <Tooltip contentStyle={CHART_TOOLTIP_STYLE} formatter={(v: number | undefined) => [(v ?? 0).toFixed(2) + "x", "Health"]} />
                <Area type="monotone" dataKey="health" stroke="#34d399" strokeWidth={2} fill="url(#hGrad)" dot={false} />
              </AreaChart>
            </ResponsiveContainer>
          </Card>

          {/* TVL history */}
          <Card>
            <CardTitle className="mb-4">TVL (BTC)</CardTitle>
            <ResponsiveContainer width="100%" height={180}>
              <AreaChart data={tvlHistory}>
                <defs>
                  <linearGradient id="tvlGrad" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="5%"  stopColor="#f97316" stopOpacity={0.3} />
                    <stop offset="95%" stopColor="#f97316" stopOpacity={0} />
                  </linearGradient>
                </defs>
                <CartesianGrid strokeDasharray="3 3" stroke="rgba(255,255,255,0.04)" />
                <XAxis dataKey="time" tick={{ fill: "rgba(255,255,255,0.3)", fontSize: 11 }} axisLine={false} tickLine={false} />
                <YAxis tick={{ fill: "rgba(255,255,255,0.3)", fontSize: 11 }} axisLine={false} tickLine={false} width={35} />
                <Tooltip contentStyle={CHART_TOOLTIP_STYLE} formatter={(v: number | undefined) => [(v ?? 0).toFixed(2) + " BTC", "TVL"]} />
                <Area type="monotone" dataKey="tvl" stroke="#f97316" strokeWidth={2} fill="url(#tvlGrad)" dot={false} />
              </AreaChart>
            </ResponsiveContainer>
          </Card>

        </div>

        {/* APY chart + Backing/Exposure */}
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">

          {/* APY History */}
          <Card>
            <CardTitle className="mb-4">APY History (%)</CardTitle>
            <ResponsiveContainer width="100%" height={180}>
              <AreaChart data={apyHistory}>
                <defs>
                  <linearGradient id="apyGrad" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="5%"  stopColor="#a78bfa" stopOpacity={0.3} />
                    <stop offset="95%" stopColor="#a78bfa" stopOpacity={0} />
                  </linearGradient>
                </defs>
                <CartesianGrid strokeDasharray="3 3" stroke="rgba(255,255,255,0.04)" />
                <XAxis dataKey="time" tick={{ fill: "rgba(255,255,255,0.3)", fontSize: 11 }} axisLine={false} tickLine={false} />
                <YAxis tick={{ fill: "rgba(255,255,255,0.3)", fontSize: 11 }} axisLine={false} tickLine={false} width={30} />
                <Tooltip contentStyle={CHART_TOOLTIP_STYLE} formatter={(v: number | undefined) => [(v ?? 0).toFixed(2) + "%", "APY"]} />
                <Area type="monotone" dataKey="apy" stroke="#a78bfa" strokeWidth={2} fill="url(#apyGrad)" dot={false} />
              </AreaChart>
            </ResponsiveContainer>
          </Card>

          {/* Backing vs Exposure */}
          <Card>
            <CardTitle className="mb-4">BTC Backing vs Exposure</CardTitle>
            <div className="flex items-center gap-6">
              <ResponsiveContainer width={140} height={140}>
                <PieChart>
                  <Pie data={PIE_DATA} cx="50%" cy="50%" innerRadius={40} outerRadius={60} paddingAngle={3} dataKey="value">
                    {PIE_DATA.map((entry, i) => <Cell key={i} fill={entry.color} />)}
                  </Pie>
                </PieChart>
              </ResponsiveContainer>
              <div className="space-y-3 flex-1">
                {PIE_DATA.map(({ name, value, color }) => (
                  <div key={name}>
                    <div className="flex items-center gap-2 mb-0.5">
                      <div className="w-2 h-2 rounded-full" style={{ backgroundColor: color }} />
                      <span className="text-xs text-white/50">{name}</span>
                    </div>
                    <p className="text-sm font-mono text-white">{value.toFixed(4)} BTC</p>
                  </div>
                ))}
                <div className="pt-2 border-t border-white/8">
                  <p className="text-xs text-white/40">Utilization</p>
                  <p className="text-sm font-bold text-orange-400">{utilizationPct}%</p>
                </div>
              </div>
            </div>
          </Card>

        </div>

        {/* Contract links */}
        <Card glass>
          <CardTitle className="mb-4">On-Chain References</CardTitle>
          <div className="grid grid-cols-1 md:grid-cols-2 gap-2">
            {[
              { name: "BTCVault",          href: EXPLORERS.BTCVault,          addr: CONTRACTS.BTCVault },
              { name: "BTCSecurityRouter", href: EXPLORERS.BTCSecurityRouter, addr: CONTRACTS.BTCSecurityRouter },
              { name: "YBTCToken",         href: EXPLORERS.YBTCToken,         addr: CONTRACTS.YBTCToken },
              { name: "Mock wBTC",         href: EXPLORERS.MockWBTC,          addr: CONTRACTS.MockWBTC },
            ].map(({ name, href, addr }) => (
              <a key={name} href={href} target="_blank" rel="noopener noreferrer"
                className="flex items-center justify-between px-3 py-2 rounded-lg bg-white/3 hover:bg-white/6 transition-colors group">
                <div>
                  <p className="text-xs font-medium text-white/70 group-hover:text-white">{name}</p>
                  <p className="text-[10px] font-mono text-white/25 break-all">{addr}</p>
                </div>
                <ExternalLink className="w-3 h-3 text-white/20 group-hover:text-orange-400 shrink-0 ml-2" />
              </a>
            ))}
          </div>
        </Card>

        {/* ── Autonomous Agents ── */}
        <Card glass>
          <CardTitle className="flex items-center gap-1.5 mb-2">
            Autonomous Agents
          </CardTitle>
          <p className="text-xs text-white/30 mb-5">
            Three off-chain bots run continuously, calling only public contract functions.
            They have no special permissions — they cannot drain funds or override user choices.
          </p>
          <div className="grid grid-cols-1 md:grid-cols-3 gap-4">

            {/* Risk Sentinel */}
            <div className="rounded-xl bg-red-500/5 border border-red-500/10 p-4 space-y-3">
              <div className="flex items-center gap-2">
                <div className="w-8 h-8 rounded-xl bg-red-500/15 flex items-center justify-center">
                  <Eye className="w-4 h-4 text-red-400" />
                </div>
                <div>
                  <p className="text-sm font-semibold text-white">Risk Sentinel</p>
                  <p className="text-[10px] text-white/30">BTC price &amp; volatility monitor</p>
                </div>
              </div>
              <div className="space-y-2 text-[11px]">
                <p className="text-white/50 leading-relaxed">
                  Polls BTC price across three exchanges every N seconds. If the 1-hour price
                  change exceeds <span className="text-white/70 font-medium">−10%</span> or
                  annualised volatility exceeds <span className="text-white/70 font-medium">80%</span>,
                  it calls <code className="text-red-400/80 bg-red-500/8 px-1 py-0.5 rounded">enter_safe_mode()</code> on
                  the security router.
                </p>
                <div className="pt-2 border-t border-red-500/10 space-y-1.5">
                  <div className="flex justify-between">
                    <span className="text-white/40">Trigger 1</span>
                    <span className="text-white/60">&gt;10% 1h drop</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-white/40">Trigger 2</span>
                    <span className="text-white/60">&gt;80% annualised vol.</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-white/40">Safe mode now</span>
                    <span className={metrics?.isSafeMode ? "text-red-400 font-medium" : "text-emerald-400"}>
                      {metrics ? (metrics.isSafeMode ? "Active ⚠" : "Inactive ✓") : "—"}
                    </span>
                  </div>
                </div>
              </div>
            </div>

            {/* Strategy Rebalancer */}
            <div className="rounded-xl bg-purple-500/5 border border-purple-500/10 p-4 space-y-3">
              <div className="flex items-center gap-2">
                <div className="w-8 h-8 rounded-xl bg-purple-500/15 flex items-center justify-center">
                  <RefreshCw className="w-4 h-4 text-purple-400" />
                </div>
                <div>
                  <p className="text-sm font-semibold text-white">Strategy Rebalancer</p>
                  <p className="text-[10px] text-white/30">Yield accrual &amp; leverage manager</p>
                </div>
              </div>
              <div className="space-y-2 text-[11px]">
                <p className="text-white/50 leading-relaxed">
                  Calls <code className="text-purple-400/80 bg-purple-500/8 px-1 py-0.5 rounded">trigger_yield_accrual()</code> hourly
                  and refreshes the Pragma oracle. Also computes recommended leverage
                  from the current system health and warns when users should de-risk.
                </p>
                <div className="pt-2 border-t border-purple-500/10 space-y-1.5">
                  <div className="flex justify-between">
                    <span className="text-white/40">Yield cycle</span>
                    <span className="text-white/60">Every hour</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-white/40">No-leverage threshold</span>
                    <span className="text-white/60">Health &lt;1.10</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-white/40">Reduce threshold</span>
                    <span className="text-white/60">Health &lt;1.20</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-white/40">Current APY</span>
                    <span className="text-emerald-400">{metrics ? bpsToPercent(metrics.apy) : "—"}</span>
                  </div>
                </div>
              </div>
            </div>

            {/* User Guardian */}
            <div className="rounded-xl bg-yellow-500/5 border border-yellow-500/10 p-4 space-y-3">
              <div className="flex items-center gap-2">
                <div className="w-8 h-8 rounded-xl bg-yellow-500/15 flex items-center justify-center">
                  <UserCheck className="w-4 h-4 text-yellow-400" />
                </div>
                <div>
                  <p className="text-sm font-semibold text-white">User Guardian</p>
                  <p className="text-[10px] text-white/30">Liquidation bot</p>
                </div>
              </div>
              <div className="space-y-2 text-[11px]">
                <p className="text-white/50 leading-relaxed">
                  Tracks every depositor address via the event indexer. Each cycle it batch-checks
                  health factors and calls <code className="text-yellow-400/80 bg-yellow-500/8 px-1 py-0.5 rounded">liquidate(user)</code> for
                  positions at or below 1.00, protecting the vault's solvency.
                </p>
                <div className="pt-2 border-t border-yellow-500/10 space-y-1.5">
                  <div className="flex justify-between">
                    <span className="text-white/40">Liquidate at</span>
                    <span className="text-white/60">Health ≤ 1.00</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-white/40">Warn at</span>
                    <span className="text-white/60">Health ≤ 1.30</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-white/40">Retry cooldown</span>
                    <span className="text-white/60">60 seconds</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-white/40">What's liquidated</span>
                    <span className="text-white/60">Debt repaid from collateral</span>
                  </div>
                </div>
              </div>
            </div>

          </div>
        </Card>

      </div>
    </AppLayout>
  );
}
