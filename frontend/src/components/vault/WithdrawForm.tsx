"use client";

import { useState } from "react";
import { useAccount, useSendTransaction } from "@starknet-react/core";
import { uint256 } from "starknet";
import { Button } from "@/components/ui/Button";
import { useYBTCBalance, toBalance } from "@/lib/hooks/useUserPosition";
import { useSystemMetrics } from "@/lib/hooks/useRouterData";
import { CONTRACTS } from "@/lib/contracts/addresses";
import { formatBTC, formatUSD, pragmaToUSD } from "@/lib/utils/format";
import { TxState } from "@/types";
import { ArrowDown, CheckCircle2, XCircle, Flame } from "lucide-react";
import { motion } from "framer-motion";

function parseBTCInput(val: string): bigint {
  const n = parseFloat(val);
  if (isNaN(n) || n <= 0) return 0n;
  return BigInt(Math.round(n * 1e8));
}

export function WithdrawForm() {
  const { address }               = useAccount();
  const { data: ybtcBalance }     = useYBTCBalance();
  const { data: metrics }         = useSystemMetrics();
  const { sendAsync }             = useSendTransaction({});

  const [amount, setAmount]       = useState("");
  const [tx, setTx]               = useState<TxState>({ status: "idle" });

  const ybtcAmount    = parseBTCInput(amount);
  const ybtcBal       = toBalance(ybtcBalance);
  const ybtcBalBTC    = formatBTC(ybtcBal);
  const sharePrice    = metrics ? Number(metrics.sharePrice) / 1_000_000 : 1;
  const btcToReceive  = ybtcAmount > 0n ? (Number(ybtcAmount) / 1e8) * sharePrice : 0;
  const btcPrice      = metrics ? pragmaToUSD(BigInt(metrics.btcUsdPrice)) : 0;
  const usdToReceive  = btcToReceive * btcPrice;

  async function handleWithdraw() {
    if (!address) return;
    setTx({ status: "pending" });
    try {
      const amountU256 = uint256.bnToUint256(ybtcAmount);
      const { transaction_hash } = await sendAsync([{
        contractAddress: CONTRACTS.BTCVault,
        entrypoint: "withdraw",
        calldata: [amountU256.low.toString(), amountU256.high.toString()],
      }]);
      setTx({ status: "success", hash: transaction_hash });
      setAmount("");
    } catch (e: any) {
      setTx({ status: "error", error: e.message });
    }
  }

  const hasBalance = ybtcBal >= ybtcAmount;

  return (
    <div className="space-y-5">

      {/* yBTC input */}
      <div>
        <label className="block text-xs text-white/50 uppercase tracking-wider mb-2">yBTC to Burn</label>
        <div className="relative">
          <input
            type="number"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            placeholder="0.00000000"
            className="w-full bg-white/5 border border-white/10 rounded-xl px-4 py-3 text-white text-lg font-mono placeholder:text-white/20 focus:outline-none focus:border-orange-500/50 pr-20"
          />
          <div className="absolute right-3 top-1/2 -translate-y-1/2">
            <span className="text-emerald-400 font-semibold text-sm">yBTC</span>
          </div>
        </div>
        <div className="flex justify-end mt-1.5">
          <button
            className="text-xs text-orange-400 hover:text-orange-300"
            onClick={() => ybtcBal > 0n && setAmount(formatBTC(ybtcBal))}
          >
            Max: {ybtcBalBTC} yBTC
          </button>
        </div>
      </div>

      {/* Arrow */}
      <div className="flex items-center justify-center">
        <ArrowDown className="w-5 h-5 text-white/30" />
      </div>

      {/* You receive */}
      <div className="bg-white/3 rounded-xl px-4 py-3">
        <p className="text-xs text-white/40 mb-2">You receive</p>
        <div className="flex items-center justify-between">
          <div>
            <p className="text-xl font-mono text-white">
              {btcToReceive > 0 ? btcToReceive.toFixed(8) : "—"} wBTC
            </p>
            <p className="text-xs text-white/40 mt-0.5">
              {usdToReceive > 0 ? `≈ ${formatUSD(usdToReceive)}` : ""}
            </p>
          </div>
          <Flame className="w-5 h-5 text-orange-400 opacity-60" />
        </div>
      </div>

      {/* Share price */}
      {metrics && (
        <div className="text-xs text-white/40 text-center">
          1 yBTC = {sharePrice.toFixed(6)} wBTC &nbsp;·&nbsp; Share price
        </div>
      )}

      {/* Button */}
      <Button
        className="w-full"
        size="lg"
        variant={ybtcAmount > 0n && !hasBalance ? "danger" : "primary"}
        disabled={!address || !amount || ybtcAmount === 0n || !hasBalance}
        loading={tx.status === "pending"}
        onClick={handleWithdraw}
      >
        {!address
          ? "Connect Wallet First"
          : !hasBalance && ybtcAmount > 0n
          ? "Insufficient yBTC Balance"
          : tx.status === "pending"
          ? "Withdrawing..."
          : `Withdraw ${amount || "0"} yBTC`}
      </Button>

      {/* Tx status */}
      {tx.status === "success" && tx.hash && (
        <motion.div
          initial={{ opacity: 0, y: 8 }}
          animate={{ opacity: 1, y: 0 }}
          className="flex items-start gap-2 bg-emerald-500/10 border border-emerald-500/20 rounded-xl px-4 py-3"
        >
          <CheckCircle2 className="w-4 h-4 text-emerald-400 mt-0.5" />
          <div>
            <p className="text-sm text-emerald-300 font-medium">Withdrawal successful!</p>
            <a
              href={`https://sepolia.starkscan.co/tx/${tx.hash}`}
              target="_blank"
              className="text-xs text-emerald-400/70 hover:text-emerald-300 underline"
            >
              View on Starkscan →
            </a>
          </div>
        </motion.div>
      )}

      {tx.status === "error" && (
        <motion.div
          initial={{ opacity: 0, y: 8 }}
          animate={{ opacity: 1, y: 0 }}
          className="flex items-start gap-2 bg-red-500/10 border border-red-500/20 rounded-xl px-4 py-3"
        >
          <XCircle className="w-4 h-4 text-red-400 mt-0.5" />
          <p className="text-sm text-red-300">{tx.error || "Transaction failed"}</p>
        </motion.div>
      )}
    </div>
  );
}
