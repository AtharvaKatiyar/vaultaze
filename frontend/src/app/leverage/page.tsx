"use client";

import { useState, useEffect } from "react";
import { useAccount, useSendTransaction } from "@starknet-react/core";
import { AppLayout } from "@/components/layout/AppLayout";
import { Card, CardTitle } from "@/components/ui/Card";
import { Button } from "@/components/ui/Button";
import { LeverageSlider } from "@/components/leverage/LeverageSlider";
import { HealthBadge } from "@/components/system/HealthBadge";
import { useSystemMetrics } from "@/lib/hooks/useRouterData";
import { useUserPosition, useRecommendedLeverage, useYBTCBalance, useUserDashboard } from "@/lib/hooks/useUserPosition";
import { formatLeverage, formatUSD, pragmaToUSD, formatBTC } from "@/lib/utils/format";
import { CONTRACTS } from "@/lib/contracts/addresses";
import { TxState } from "@/types";
import { useAuthGuard } from "@/lib/hooks/useAuthGuard";
import {
  Zap, AlertTriangle, TrendingUp, TrendingDown,
  CheckCircle2, XCircle, Info, Wallet
} from "lucide-react";
import { motion } from "framer-motion";

export default function LeveragePage() {
  useAuthGuard();
  const { address }            = useAccount();
  const { data: metrics }      = useSystemMetrics();
  const { data: position }     = useUserPosition();
  const { data: recLeverage }  = useRecommendedLeverage();
  const { data: ybtcBal }      = useYBTCBalance();
  const { sendAsync }          = useSendTransaction({});

  const { data: dash }        = useUserDashboard();

  // Prefer dashboard data (authoritative) over raw position tuple
  const currentLeverage  = dash ? dash.currentLeverage : (position ? Number((position as any)[2] ?? 100) : 100);
  const debtUSD          = dash ? Number(dash.userDebtUsd) / 1e8 : 0;
  // Ghost leverage: router stored leverage but oracle was 0 → no debt borrowed
  const ghostLeverage    = currentLeverage > 100 && debtUSD === 0;
  // Use || so that a maxLeverage of 0 (not yet set on-chain) also falls back to 200
  const maxLeverage      = metrics?.maxLeverage || 200;
  const recLev_          = recLeverage ? Number(recLeverage.toString()) : 100;
  const btcPrice         = metrics ? pragmaToUSD(BigInt(metrics.btcUsdPrice)) : 95_000;
  const ybtcBal_         = ybtcBal ? BigInt(ybtcBal.toString()) : 0n;

  const [targetLeverage, setTargetLeverage] = useState(100);
  const [tx, setTx] = useState<TxState>({ status: "idle" });

  // Sync slider to actual on-chain position leverage once it loads
  useEffect(() => {
    if (position) {
      const lev = Number((position as any)[2] ?? 100);
      setTargetLeverage(lev > 0 ? lev : 100);
    }
  }, [position]);

  const sharePrice  = metrics ? Number(metrics.sharePrice) / 1_000_000 : 1;
  const positionBTC = (Number(ybtcBal_) / 1e8) * sharePrice;
  const effectiveAPY = metrics
    ? ((Number(metrics.apy) / 100) * (targetLeverage / 100)).toFixed(2)
    : "—";
  const liqDropPct = targetLeverage > 100
    ? ((1 - 1 / (targetLeverage / 100)) * 100 * 0.8).toFixed(1)
    : null;

  async function handleApplyLeverage() {
    if (!address) return;
    setTx({ status: "pending" });
    try {
      const { transaction_hash } = await sendAsync([{
        contractAddress: CONTRACTS.BTCVault,
        entrypoint: "apply_leverage",
        calldata: [targetLeverage.toString()],
      }]);
      setTx({ status: "success", hash: transaction_hash });
    } catch (e: any) {
      setTx({ status: "error", error: e.message });
    }
  }

  async function handleDeleverage() {
    if (!address) return;
    setTx({ status: "pending" });
    try {
      const { transaction_hash } = await sendAsync([{
        contractAddress: CONTRACTS.BTCVault,
        entrypoint: "deleverage",
        calldata: [],
      }]);
      setTx({ status: "success", hash: transaction_hash });
    } catch (e: any) {
      setTx({ status: "error", error: e.message });
    }
  }

  if (!address) {
    return (
      <AppLayout>
        <div className="max-w-xl mx-auto pt-16 text-center space-y-4">
          <Wallet className="w-10 h-10 text-white/20 mx-auto" />
          <p className="text-white/40">Connect your wallet to manage leverage.</p>
        </div>
      </AppLayout>
    );
  }

  return (
    <AppLayout>
      <div className="max-w-xl mx-auto space-y-6">

        <div>
          <h1 className="text-2xl font-bold text-white">Leverage Manager</h1>
          <p className="text-white/40 text-sm mt-1">
            Adjust your position leverage. Router max: {formatLeverage(maxLeverage)}.
          </p>
        </div>

        {/* Current state */}
        <div className="grid grid-cols-2 gap-4">
          <Card>
            <p className="text-xs text-white/40 uppercase tracking-wider mb-1">Current Leverage</p>
            <p className="text-2xl font-bold text-orange-400">{formatLeverage(currentLeverage)}</p>
          </Card>
          <Card>
            <p className="text-xs text-white/40 uppercase tracking-wider mb-1">BTC Health</p>
            {metrics
              ? <HealthBadge health={metrics.btcHealth} size="sm" />
              : <span className="text-xs text-white/30">Loading…</span>
            }
          </Card>
        </div>

        {/* Ghost leverage banner — leverage recorded but oracle was 0 at apply time */}
        {ghostLeverage && (
          <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }}>
            <Card className="border-yellow-500/20 bg-yellow-500/5">
              <div className="flex items-start gap-3">
                <AlertTriangle className="w-4 h-4 text-yellow-400 mt-0.5 shrink-0" />
                <div>
                  <p className="text-sm font-semibold text-yellow-300">
                    Leverage not funded — re-apply required
                  </p>
                  <p className="text-xs text-white/50 mt-1">
                    Your leverage was recorded as {formatLeverage(currentLeverage)} but the BTC oracle
                    was unavailable at that moment, so no stablecoins were borrowed. Re-apply your
                    target leverage below to activate the full position.
                  </p>
                </div>
              </div>
            </Card>
          </motion.div>
        )}

        {/* Recommended */}
        {recLev_ > 0 && recLev_ !== currentLeverage && (
          <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }}>
            <Card glass>
              <div className="flex items-center gap-3">
                <TrendingUp className="w-4 h-4 text-emerald-400 shrink-0" />
                <p className="text-sm text-white/70 flex-1">
                  Recommended leverage for current market conditions:
                  <button
                    className="ml-1.5 text-emerald-400 font-bold hover:text-emerald-300"
                    onClick={() => setTargetLeverage(recLev_)}
                  >
                    {formatLeverage(recLev_)} →
                  </button>
                </p>
              </div>
            </Card>
          </motion.div>
        )}

        {/* Slider */}
        <Card glow="orange">
          <CardTitle className="mb-5">Set Target Leverage</CardTitle>
          <LeverageSlider
            value={targetLeverage}
            onChange={setTargetLeverage}
            maxLeverage={maxLeverage}
          />
        </Card>

        {/* Effect preview */}
        <Card glass>
          <CardTitle className="mb-4">Position Preview</CardTitle>
          <div className="space-y-3">
            <div className="flex justify-between">
              <span className="text-sm text-white/50">Position Size</span>
              <span className="text-sm text-white font-mono">
                {positionBTC > 0
                  ? `${(positionBTC * (targetLeverage / 100)).toFixed(6)} BTC`
                  : "Deposit first"
                }
              </span>
            </div>
            {positionBTC > 0 && (
              <div className="flex justify-between">
                <span className="text-sm text-white/50">USD Exposure</span>
                <span className="text-sm text-white font-mono">
                  {formatUSD((positionBTC * (targetLeverage / 100)) * btcPrice)}
                </span>
              </div>
            )}
            <div className="flex justify-between">
              <span className="text-sm text-white/50">Effective APY</span>
              <span className="text-sm text-emerald-400 font-semibold">{effectiveAPY}%</span>
            </div>
            {liqDropPct && (
              <div className="flex justify-between">
                <span className="text-sm text-white/50">Liquidation if BTC drops</span>
                <span className="text-sm text-orange-400 font-semibold">-{liqDropPct}%</span>
              </div>
            )}
            <div className="flex justify-between">
              <span className="text-sm text-white/50">Max Allowed (Router)</span>
              <span className="text-sm text-white">{formatLeverage(maxLeverage)}</span>
            </div>
          </div>

          {targetLeverage > 150 && (
            <div className="mt-4 flex items-start gap-2 bg-orange-500/10 rounded-xl p-3 border border-orange-500/20">
              <AlertTriangle className="w-4 h-4 text-orange-400 shrink-0 mt-0.5" />
              <p className="text-xs text-orange-300">
                High leverage amplifies both gains and losses. A {liqDropPct}% BTC price drop could trigger liquidation.
              </p>
            </div>
          )}
        </Card>

        {/* Actions */}
        <div className="flex gap-3">
          <Button
            className="flex-1"
            size="lg"
            disabled={targetLeverage === currentLeverage || !metrics}
            loading={tx.status === "pending"}
            onClick={handleApplyLeverage}
          >
            <Zap className="w-4 h-4" />
            {targetLeverage > currentLeverage ? "Increase Leverage" : "Reduce Leverage"}
          </Button>
          {currentLeverage > 100 && (
            <Button
              variant="danger"
              size="lg"
              loading={tx.status === "pending"}
              onClick={handleDeleverage}
            >
              <TrendingDown className="w-4 h-4" />
              Remove All
            </Button>
          )}
        </div>

        {/* Tx status */}
        {tx.status === "success" && tx.hash && (
          <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }}
            className="flex items-start gap-2 bg-emerald-500/10 border border-emerald-500/20 rounded-xl px-4 py-3">
            <CheckCircle2 className="w-4 h-4 text-emerald-400 mt-0.5 shrink-0" />
            <div>
              <p className="text-sm text-emerald-300 font-medium">Leverage updated!</p>
              <a href={`https://sepolia.voyager.online/tx/${tx.hash}`} target="_blank"
                className="text-xs text-emerald-400/70 hover:text-emerald-300 underline">
                View on Voyager →
              </a>
            </div>
          </motion.div>
        )}
        {tx.status === "error" && (
          <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }}
            className="flex items-start gap-2 bg-red-500/10 border border-red-500/20 rounded-xl px-4 py-3">
            <XCircle className="w-4 h-4 text-red-400 mt-0.5 shrink-0" />
            <p className="text-sm text-red-300">{tx.error || "Transaction failed"}</p>
          </motion.div>
        )}

        {/* Info */}
        <Card glass>
          <div className="flex gap-3">
            <Info className="w-4 h-4 text-white/30 shrink-0 mt-0.5" />
            <div className="space-y-1 text-xs text-white/40">
              <p>Maximum leverage increase per transaction: 1.00x (router enforced).</p>
              <p>Leverage is adjusted by borrowing stablecoins against your BTC collateral and deploying them to yield strategies.</p>
              <p>The router may reduce max leverage dynamically based on BTC volatility and system health.</p>
            </div>
          </div>
        </Card>

      </div>
    </AppLayout>
  );
}
