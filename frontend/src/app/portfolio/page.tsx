"use client";

import { AppLayout } from "@/components/layout/AppLayout";
import { PositionCard } from "@/components/portfolio/PositionCard";
import { Card, CardTitle } from "@/components/ui/Card";
import { useAccount } from "@starknet-react/core";
import { useWBTCBalance, useYBTCBalance } from "@/lib/hooks/useUserPosition";
import { useSystemMetrics } from "@/lib/hooks/useRouterData";
import { formatBTC, formatUSD, pragmaToUSD, formatSharePrice } from "@/lib/utils/format";
import { EXPLORERS, CONTRACTS } from "@/lib/contracts/addresses";
import { ExternalLink, ArrowUpFromLine, ArrowDownToLine } from "lucide-react";
import Link from "next/link";
import { Button } from "@/components/ui/Button";

export default function PortfolioPage() {
  const { address }          = useAccount();
  const { data: wbtcBal }    = useWBTCBalance();
  const { data: ybtcBal }    = useYBTCBalance();
  const { data: metrics }    = useSystemMetrics();

  const btcPrice   = metrics ? pragmaToUSD(BigInt(metrics.btcUsdPrice)) : 0;
  const wbtcBal_   = wbtcBal  ? BigInt(wbtcBal.toString())  : 0n;
  const ybtcBal_   = ybtcBal  ? BigInt(ybtcBal.toString())  : 0n;
  const sharePrice = metrics  ? Number(metrics.sharePrice) / 1_000_000 : 1;
  const ybtcInBTC  = (Number(ybtcBal_) / 1e8) * sharePrice;
  const totalUSD   = (Number(wbtcBal_) / 1e8 + ybtcInBTC) * btcPrice;

  return (
    <AppLayout>
      <div className="space-y-6">
        <div className="flex items-start justify-between">
          <div>
            <h1 className="text-2xl font-bold text-white">Portfolio</h1>
            <p className="text-white/40 text-sm mt-1">Your positions, balances and claimable yield.</p>
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
        </div>

        {/* Total balance overview */}
        <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
          <Card glow="orange">
            <p className="text-xs text-white/40 uppercase tracking-wider mb-1">wBTC Balance</p>
            <p className="text-2xl font-bold font-mono text-white">{formatBTC(wbtcBal_)} wBTC</p>
            <p className="text-xs text-white/30 mt-0.5">{formatUSD((Number(wbtcBal_) / 1e8) * btcPrice)}</p>
          </Card>
          <Card glow="green">
            <p className="text-xs text-white/40 uppercase tracking-wider mb-1">yBTC Balance</p>
            <p className="text-2xl font-bold font-mono text-emerald-400">{formatBTC(ybtcBal_)} yBTC</p>
            <p className="text-xs text-white/30 mt-0.5">{formatUSD(ybtcInBTC * btcPrice)}</p>
          </Card>
          <Card>
            <p className="text-xs text-white/40 uppercase tracking-wider mb-1">Total Portfolio USD</p>
            <p className="text-2xl font-bold text-white">{totalUSD > 0 ? formatUSD(totalUSD) : "—"}</p>
            <p className="text-xs text-white/30 mt-0.5">Share price: {formatSharePrice(metrics?.sharePrice ?? 1_000_000n)}</p>
          </Card>
        </div>

        {/* Position */}
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <div>
            <h2 className="text-sm font-medium text-white/60 uppercase tracking-wider mb-3">Active Position</h2>
            <PositionCard />
          </div>

          {/* Token addresses */}
          <div>
            <h2 className="text-sm font-medium text-white/60 uppercase tracking-wider mb-3">Token Addresses</h2>
            <Card glass>
              <div className="space-y-3">
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
        </div>

      </div>
    </AppLayout>
  );
}
