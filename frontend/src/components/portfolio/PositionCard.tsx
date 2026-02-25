"use client";

import { useState } from "react";
import { useAccount, useSendTransaction } from "@starknet-react/core";
import { Card, CardTitle } from "@/components/ui/Card";
import { Button } from "@/components/ui/Button";
import { HealthBadge } from "@/components/system/HealthBadge";
import {
  useUserPosition,
  useUserHealth,
  useUserLiquidationPrice,
  useYBTCBalance,
  useUserClaimableYield,
  useRecommendedLeverage,
} from "@/lib/hooks/useUserPosition";
import { useSystemMetrics } from "@/lib/hooks/useRouterData";
import {
  formatBTC,
  formatUSD,
  formatLeverage,
  pragmaToUSD,
} from "@/lib/utils/format";
import { CONTRACTS } from "@/lib/contracts/addresses";
import { TxState } from "@/types";
import {
  Coins,
  TrendingUp,
  AlertTriangle,
  ChevronRight,
  Wallet,
  RefreshCw,
} from "lucide-react";
import { motion } from "framer-motion";

export function PositionCard() {
  const { address }              = useAccount();
  const { data: position }       = useUserPosition();
  const { data: health }         = useUserHealth();
  const { data: liquidPrice }    = useUserLiquidationPrice();
  const { data: ybtcBal }        = useYBTCBalance();
  const { data: claimable }      = useUserClaimableYield();
  const { data: recLeverage }    = useRecommendedLeverage();
  const { data: metrics }        = useSystemMetrics();
  const { sendAsync }            = useSendTransaction({});

  const [claimTx, setClaimTx]    = useState<TxState>({ status: "idle" });
  const [deleverTx, setDeleverTx] = useState<TxState>({ status: "idle" });

  if (!address) {
    return (
      <Card className="flex flex-col items-center justify-center py-16 gap-4 text-center">
        <Wallet className="w-10 h-10 text-white/20" />
        <p className="text-white/40 text-sm">Connect your wallet to view your position</p>
      </Card>
    );
  }

  const btcPrice   = metrics ? pragmaToUSD(BigInt(metrics.btcUsdPrice)) : 0;
  const ybtcBal_   = ybtcBal  ? BigInt(ybtcBal.toString())  : 0n;
  const claimable_ = claimable ? BigInt(claimable.toString()) : 0n;
  const healthVal  = health   ? Number(health.toString())   : 0;
  const leverage_  = position ? Number((position as any)[2] ?? 100) : 100;
  const liqPrice_  = liquidPrice ? Number(liquidPrice.toString()) : 0;
  const recLev_    = recLeverage ? Number(recLeverage.toString()) : 100;

  const sharePrice = metrics ? Number(metrics.sharePrice) / 1_000_000 : 1;
  const btcValue   = (Number(ybtcBal_) / 1e8) * sharePrice;
  const usdValue   = btcValue * btcPrice;
  const liqPriceUSD = liqPrice_ > 0 ? liqPrice_ / 1e8 : 0;

  async function handleClaimYield() {
    setClaimTx({ status: "pending" });
    try {
      const { transaction_hash } = await sendAsync([{
        contractAddress: CONTRACTS.BTCVault,
        entrypoint: "claim_yield",
        calldata: [],
      }]);
      setClaimTx({ status: "success", hash: transaction_hash });
    } catch (e: any) {
      setClaimTx({ status: "error", error: e.message });
    }
  }

  async function handleDeleverage() {
    setDeleverTx({ status: "pending" });
    try {
      const { transaction_hash } = await sendAsync([{
        contractAddress: CONTRACTS.BTCVault,
        entrypoint: "deleverage",
        calldata: [],
      }]);
      setDeleverTx({ status: "success", hash: transaction_hash });
    } catch (e: any) {
      setDeleverTx({ status: "error", error: e.message });
    }
  }

  return (
    <div className="space-y-4">

      {/* Main position */}
      <Card glow={healthVal > 0 ? (healthVal >= 150 ? "green" : healthVal >= 120 ? undefined : "red") : undefined}>
        <CardTitle className="mb-4">Your Position</CardTitle>

        <div className="grid grid-cols-2 gap-4">
          <div>
            <p className="text-xs text-white/40 mb-1">yBTC Balance</p>
            <p className="text-xl font-bold text-white font-mono">{formatBTC(ybtcBal_)} yBTC</p>
            <p className="text-xs text-white/30">{formatUSD(usdValue)}</p>
          </div>
          <div>
            <p className="text-xs text-white/40 mb-1">Current Value</p>
            <p className="text-xl font-bold text-white font-mono">{btcValue.toFixed(8)} wBTC</p>
            <p className="text-xs text-white/30">≈ {formatUSD(usdValue)}</p>
          </div>
          <div>
            <p className="text-xs text-white/40 mb-1">Health Factor</p>
            {healthVal > 0
              ? <HealthBadge health={healthVal} size="sm" />
              : <span className="text-xs text-white/30">No leverage</span>
            }
          </div>
          <div>
            <p className="text-xs text-white/40 mb-1">Leverage</p>
            <p className="text-lg font-bold text-orange-400">{formatLeverage(leverage_)}</p>
          </div>
        </div>

        {/* Liquidation price */}
        {liqPriceUSD > 0 && (
          <div className="mt-4 bg-orange-500/8 border border-orange-500/15 rounded-xl px-4 py-3 flex items-center gap-3">
            <AlertTriangle className="w-4 h-4 text-orange-400 shrink-0" />
            <div>
              <p className="text-xs text-white/50">Liquidation Price</p>
              <p className="text-sm font-semibold text-orange-400">{formatUSD(liqPriceUSD)}</p>
            </div>
            {btcPrice > 0 && (
              <div className="ml-auto">
                <p className="text-xs text-white/30">Distance</p>
                <p className="text-sm font-semibold text-white/60">
                  -{(((btcPrice - liqPriceUSD) / btcPrice) * 100).toFixed(1)}%
                </p>
              </div>
            )}
          </div>
        )}
      </Card>

      {/* Claimable yield */}
      {claimable_ > 0n && (
        <motion.div
          initial={{ opacity: 0, y: 8 }}
          animate={{ opacity: 1, y: 0 }}
        >
          <Card glow="green">
            <div className="flex items-center justify-between">
              <div>
                <CardTitle>Claimable Yield</CardTitle>
                <p className="text-2xl font-bold text-emerald-400 mt-1">
                  +{formatBTC(claimable_)} wBTC
                </p>
                <p className="text-xs text-white/30">{formatUSD((Number(claimable_) / 1e8) * btcPrice)}</p>
              </div>
              <Button
                variant="secondary"
                size="sm"
                loading={claimTx.status === "pending"}
                onClick={handleClaimYield}
              >
                <Coins className="w-3.5 h-3.5" />
                Claim
              </Button>
            </div>
          </Card>
        </motion.div>
      )}

      {/* Recommended leverage */}
      {recLev_ !== leverage_ && recLev_ > 0 && (
        <Card glass>
          <div className="flex items-center gap-3">
            <TrendingUp className="w-4 h-4 text-emerald-400 shrink-0" />
            <div className="flex-1">
              <p className="text-sm text-white/70">
                Recommended leverage for current conditions:
                <span className="text-emerald-400 font-bold ml-1">{formatLeverage(recLev_)}</span>
              </p>
            </div>
            <ChevronRight className="w-4 h-4 text-white/20" />
          </div>
        </Card>
      )}

      {/* Deleverage */}
      {leverage_ > 100 && (
        <Button
          variant="danger"
          className="w-full"
          loading={deleverTx.status === "pending"}
          onClick={handleDeleverage}
        >
          <RefreshCw className="w-4 h-4" />
          Remove Leverage
        </Button>
      )}
    </div>
  );
}
