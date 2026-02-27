"use client";

import { AppLayout } from "@/components/layout/AppLayout";
import { DepositForm } from "@/components/vault/DepositForm";
import { WithdrawForm } from "@/components/vault/WithdrawForm";
import { Card, CardTitle } from "@/components/ui/Card";
import { useState } from "react";
import { cn } from "@/lib/utils/cn";
import { ArrowDownToLine, ArrowUpFromLine, Info, ArrowRight, TrendingUp, Zap } from "lucide-react";
import { motion } from "framer-motion";
import { useAuthGuard } from "@/lib/hooks/useAuthGuard";
import Link from "next/link";
import { Button } from "@/components/ui/Button";

type Tab = "deposit" | "withdraw";

export default function VaultPage() {
  useAuthGuard();
  const [tab, setTab] = useState<Tab>("deposit");

  return (
    <AppLayout>
      <div className="max-w-xl mx-auto space-y-6">

        <div>
          <h1 className="text-2xl font-bold text-white">Vault</h1>
          <p className="text-white/40 text-sm mt-1">
            Deposit wBTC to mint yBTC shares and start earning yield.
          </p>
        </div>

        {/* Tab switcher */}
        <div className="flex gap-1 p-1 bg-white/5 rounded-xl border border-white/8 w-fit">
          {(["deposit", "withdraw"] as Tab[]).map((t) => (
            <button
              key={t}
              onClick={() => setTab(t)}
              className={cn(
                "flex items-center gap-1.5 px-5 py-2 rounded-lg text-sm font-medium transition-all capitalize",
                tab === t
                  ? "bg-orange-500/20 text-orange-400 border border-orange-500/20"
                  : "text-white/40 hover:text-white"
              )}
            >
              {t === "deposit"
                ? <ArrowDownToLine className="w-3.5 h-3.5" />
                : <ArrowUpFromLine className="w-3.5 h-3.5" />
              }
              {t}
            </button>
          ))}
        </div>

        {/* Form card */}
        <motion.div
          key={tab}
          initial={{ opacity: 0, y: 10 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.2 }}
        >
          <Card glow={tab === "deposit" ? "orange" : undefined}>
            <CardTitle className="mb-5">
              {tab === "deposit" ? "Deposit wBTC → yBTC" : "Withdraw yBTC → wBTC"}
            </CardTitle>
            {tab === "deposit" ? <DepositForm /> : <WithdrawForm />}
          </Card>
        </motion.div>

        {/* Info box */}
        <Card glass>
          <div className="flex gap-3">
            <Info className="w-4 h-4 text-orange-400 shrink-0 mt-0.5" />
            <div className="space-y-1.5 text-xs text-white/50">
              <p>
                <span className="text-white/70 font-medium">Minimum deposit:</span>{" "}
                0.01 wBTC (0.1 wBTC for first-ever deposit)
              </p>
              <p>
                <span className="text-white/70 font-medium">Share price:</span>{" "}
                yBTC value increases as yield accrues — 1 yBTC ≥ 1 wBTC over time.
              </p>
              <p>
                <span className="text-white/70 font-medium">Router gate:</span>{" "}
                Deposits are rejected when Safe Mode is active or global BTC health falls below 1.00.
              </p>
              <p>
                <span className="text-white/70 font-medium">Transaction flow:</span>{" "}
                Approve wBTC allowance, then deposit in one batched multicall.
              </p>
            </div>
          </div>
        </Card>

        {/* What happens next */}
        {tab === "deposit" && (
          <motion.div
            initial={{ opacity: 0, y: 8 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.3, delay: 0.1 }}
          >
            <Card glass>
              <CardTitle className="mb-4">What happens after you deposit?</CardTitle>
              <p className="text-xs text-white/40 mb-4">
                Once your wBTC enters the vault, it becomes collateral. The vault borrows stablecoins against it
                and deploys them using one or both of the strategies below. You choose.
              </p>

              <div className="space-y-3">
                {/* Yield path */}
                <div className="rounded-xl bg-emerald-500/5 border border-emerald-500/10 p-3.5 flex items-start gap-3">
                  <div className="w-8 h-8 rounded-xl bg-emerald-500/15 flex items-center justify-center shrink-0">
                    <TrendingUp className="w-4 h-4 text-emerald-400" />
                  </div>
                  <div className="flex-1 min-w-0">
                    <p className="text-xs font-semibold text-emerald-400 mb-1">Yield Strategy (automatic)</p>
                    <p className="text-[11px] text-white/40 leading-relaxed">
                      Borrowed stablecoins go into lending pools and LP positions. Profits are converted
                      back to wBTC and added to the vault — your yBTC shares become worth more wBTC over time
                      (share price rises). You don't need to do anything.
                    </p>
                  </div>
                </div>

                {/* Leverage path */}
                <div className="rounded-xl bg-yellow-500/5 border border-yellow-500/10 p-3.5 flex items-start gap-3">
                  <div className="w-8 h-8 rounded-xl bg-yellow-500/15 flex items-center justify-center shrink-0">
                    <Zap className="w-4 h-4 text-yellow-400" />
                  </div>
                  <div className="flex-1 min-w-0">
                    <p className="text-xs font-semibold text-yellow-400 mb-1">Leverage Strategy (optional)</p>
                    <p className="text-[11px] text-white/40 leading-relaxed">
                      Set a leverage multiplier and the vault uses borrowed stablecoins to buy
                      more BTC on your behalf. If BTC price rises, your gains are amplified. If it falls,
                      losses are amplified too — watch your health factor. Can be removed at any time.
                    </p>
                  </div>
                </div>
              </div>

              {/* Flow arrow */}
              <div className="mt-4 flex items-center gap-2 text-[10px] text-white/25 flex-wrap">
                <span className="text-orange-400/70 font-medium">wBTC deposit</span>
                <ArrowRight className="w-3 h-3" />
                <span>vault borrows stables</span>
                <ArrowRight className="w-3 h-3" />
                <span className="text-emerald-400/70">yield accrues to share price</span>
                <span className="text-white/15">+</span>
                <span className="text-yellow-400/70">leverage buys more BTC</span>
              </div>

              <div className="mt-4 pt-4 border-t border-white/6 flex items-center justify-between">
                <p className="text-[11px] text-white/30">
                  Track everything from your portfolio page.
                </p>
                <div className="flex gap-2">
                  <Link href="/leverage">
                    <Button size="sm" variant="secondary" className="text-xs">
                      <Zap className="w-3 h-3" /> Set Leverage
                    </Button>
                  </Link>
                  <Link href="/portfolio">
                    <Button size="sm" variant="outline" className="text-xs">
                      <TrendingUp className="w-3 h-3" /> Portfolio
                    </Button>
                  </Link>
                </div>
              </div>
            </Card>
          </motion.div>
        )}

      </div>
    </AppLayout>
  );
}
