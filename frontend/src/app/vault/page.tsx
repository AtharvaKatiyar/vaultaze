"use client";

import { AppLayout } from "@/components/layout/AppLayout";
import { DepositForm } from "@/components/vault/DepositForm";
import { WithdrawForm } from "@/components/vault/WithdrawForm";
import { Card, CardTitle } from "@/components/ui/Card";
import { useState } from "react";
import { cn } from "@/lib/utils/cn";
import { ArrowDownToLine, ArrowUpFromLine, Info } from "lucide-react";
import { motion } from "framer-motion";

type Tab = "deposit" | "withdraw";

export default function VaultPage() {
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

      </div>
    </AppLayout>
  );
}
