"use client";

import { useState } from "react";
import { useAccount, useSendTransaction } from "@starknet-react/core";
import { uint256 } from "starknet";
import { Button } from "@/components/ui/Button";
import { useYBTCBalance, useUserDashboard, toBalance } from "@/lib/hooks/useUserPosition";
import { useSystemMetrics } from "@/lib/hooks/useRouterData";
import { formatBTC, formatUSD, pragmaToUSD } from "@/lib/utils/format";
import { CONTRACTS } from "@/lib/contracts/addresses";
import { TxState } from "@/types";
import { ArrowDown, CheckCircle2, XCircle, Flame, Info } from "lucide-react";
import { motion } from "framer-motion";

function parseBTCInput(val: string): bigint {
  const n = parseFloat(val);
  if (isNaN(n) || n <= 0) return 0n;
  return BigInt(Math.round(n * 1e8));
}

// "ybtc" mode: user types yBTC to burn → we show wBTC they receive (most transparent)
// "wbtc" mode: user types wBTC they want → we compute yBTC to burn
type InputMode = "ybtc" | "wbtc";

export function WithdrawForm() {
  const { address }           = useAccount();
  const { data: ybtcBalance } = useYBTCBalance();
  const { data: metrics }     = useSystemMetrics();
  const { data: dash }        = useUserDashboard();
  const { sendAsync }         = useSendTransaction({});

  const [inputMode, setInputMode] = useState<InputMode>("ybtc");
  const [inputVal, setInputVal]   = useState("");
  const [tx, setTx]               = useState<TxState>({ status: "idle" });

  const ybtcBal  = toBalance(ybtcBalance);
  const btcPrice = metrics ? pragmaToUSD(BigInt(metrics.btcUsdPrice)) : 95_000;

  // Prefer dashboard share price (same source as Portfolio page); fall back to system metrics
  const sharePriceRaw   = Number(dash?.sharePrice ?? metrics?.sharePrice ?? 1_000_000n);
  const sharePriceRatio = sharePriceRaw > 0 ? sharePriceRaw / 1_000_000 : 1;

  const inputSat = parseBTCInput(inputVal);

  // yBTC to pass to contract.withdraw(ybtc_amount)
  const ybtcToBurn: bigint =
    inputMode === "ybtc"
      ? inputSat
      : inputSat > 0n
        ? BigInt(Math.round(Number(inputSat) / sharePriceRatio))
        : 0n;

  // wBTC the user will receive
  const wbtcToReceive: bigint =
    inputMode === "wbtc"
      ? inputSat
      : ybtcToBurn > 0n
        ? BigInt(Math.round(Number(ybtcToBurn) * sharePriceRatio))
        : 0n;

  // Max helpers
  const maxYbtc        = ybtcBal;
  const maxWbtcReceive = ybtcBal > 0n
    ? BigInt(Math.round(Number(ybtcBal) * sharePriceRatio))
    : 0n;

  const usdToReceive   = wbtcToReceive > 0n ? (Number(wbtcToReceive) / 1e8) * btcPrice : 0;
  const exceedsBalance = ybtcToBurn > 0n && ybtcBal < ybtcToBurn;

  function handleMax() {
    setInputVal(formatBTC(inputMode === "ybtc" ? maxYbtc : maxWbtcReceive));
  }

  async function handleWithdraw() {
    if (!address || ybtcToBurn === 0n) return;
    setTx({ status: "pending" });
    try {
      const amountU256 = uint256.bnToUint256(ybtcToBurn);
      const { transaction_hash } = await sendAsync([{
        contractAddress: CONTRACTS.BTCVault,
        entrypoint: "withdraw",
        calldata: [amountU256.low.toString(), amountU256.high.toString()],
      }]);
      setTx({ status: "success", hash: transaction_hash });
      setInputVal("");
    } catch (e: any) {
      setTx({ status: "error", error: e.message });
    }
  }

  return (
    <div className="space-y-5">

      {/* Mode toggle */}
      <div className="flex items-center gap-1 p-1 bg-white/5 rounded-xl border border-white/8 w-fit text-xs">
        <button
          onClick={() => { setInputMode("ybtc"); setInputVal(""); }}
          className={`px-3 py-1.5 rounded-lg font-medium transition-all ${
            inputMode === "ybtc"
              ? "bg-emerald-500/20 text-emerald-400 border border-emerald-500/25"
              : "text-white/40 hover:text-white"
          }`}
        >
          Enter yBTC to burn
        </button>
        <button
          onClick={() => { setInputMode("wbtc"); setInputVal(""); }}
          className={`px-3 py-1.5 rounded-lg font-medium transition-all ${
            inputMode === "wbtc"
              ? "bg-orange-500/20 text-orange-400 border border-orange-500/25"
              : "text-white/40 hover:text-white"
          }`}
        >
          Enter wBTC to receive
        </button>
      </div>

      {/* Input */}
      <div>
        <label className="block text-xs text-white/50 uppercase tracking-wider mb-2">
          {inputMode === "ybtc" ? "yBTC Shares to Burn" : "wBTC Amount to Receive"}
        </label>
        <div className="relative">
          <input
            type="number"
            value={inputVal}
            onChange={(e) => setInputVal(e.target.value)}
            placeholder="0.00000000"
            className="w-full bg-white/5 border border-white/10 rounded-xl px-4 py-3 text-white text-lg font-mono placeholder:text-white/20 focus:outline-none focus:border-orange-500/50 pr-20"
          />
          <div className="absolute right-3 top-1/2 -translate-y-1/2">
            <span className={`font-semibold text-sm ${inputMode === "ybtc" ? "text-emerald-400" : "text-orange-400"}`}>
              {inputMode === "ybtc" ? "yBTC" : "wBTC"}
            </span>
          </div>
        </div>
        <div className="flex items-center justify-between mt-1.5">
          <span className="text-xs text-white/30">
            {usdToReceive > 0 ? `≈ ${formatUSD(usdToReceive)}` : ""}
          </span>
          <button className="text-xs text-orange-400 hover:text-orange-300" onClick={handleMax}>
            Max: {formatBTC(inputMode === "ybtc" ? maxYbtc : maxWbtcReceive)}{" "}
            {inputMode === "ybtc" ? "yBTC" : "wBTC"}
          </button>
        </div>
      </div>

      {/* Separator */}
      <div className="flex items-center justify-center">
        <ArrowDown className="w-5 h-5 text-white/30" />
      </div>

      {/* Summary: both sides of the swap */}
      <div className="bg-white/3 border border-white/8 rounded-xl px-4 py-3 space-y-3">
        <div className="flex items-center justify-between">
          <div>
            <p className="text-xs text-white/40 mb-1">yBTC burned</p>
            <p className={`text-xl font-mono ${ybtcToBurn > 0n ? "text-emerald-400" : "text-white/20"}`}>
              {ybtcToBurn > 0n ? formatBTC(ybtcToBurn) : "—"} yBTC
            </p>
            <p className="text-[10px] text-white/30 mt-0.5">
              Balance: {formatBTC(ybtcBal)} yBTC
            </p>
          </div>
          <Flame className="w-5 h-5 text-orange-400 opacity-60 shrink-0" />
        </div>
        <div className="border-t border-white/6 pt-3">
          <p className="text-xs text-white/40 mb-1">wBTC you receive</p>
          <p className={`text-xl font-mono ${wbtcToReceive > 0n ? "text-orange-400" : "text-white/20"}`}>
            {wbtcToReceive > 0n ? formatBTC(wbtcToReceive) : "—"} wBTC
          </p>
          {usdToReceive > 0 && (
            <p className="text-[10px] text-white/30 mt-0.5">{formatUSD(usdToReceive)}</p>
          )}
        </div>
      </div>

      {/* Share price info */}
      <div className="flex items-start gap-2 bg-white/2 rounded-xl px-3 py-2.5 text-xs text-white/40">
        <Info className="w-3.5 h-3.5 text-white/25 shrink-0 mt-0.5" />
        <div className="space-y-0.5">
          <p>
            <span className="text-white/60">Share price:</span>{" "}
            <span className="font-mono text-emerald-400/80">1 yBTC = {sharePriceRatio.toFixed(6)} wBTC</span>
            {sharePriceRatio > 1 && (
              <span className="ml-1.5 text-emerald-400/60">
                (+{((sharePriceRatio - 1) * 100).toFixed(4)}% yield)
              </span>
            )}
          </p>
          <p className="text-white/30">
            Each yBTC is worth more wBTC than when you deposited — this is your earned yield.
          </p>
        </div>
      </div>

      {/* Balance error */}
      {exceedsBalance && (
        <div className="flex items-center gap-2 bg-red-500/10 border border-red-500/20 rounded-xl px-3 py-2 text-xs text-red-300">
          <XCircle className="w-3.5 h-3.5 shrink-0" />
          Insufficient yBTC. You have {formatBTC(ybtcBal)} yBTC available.
        </div>
      )}

      {/* Submit */}
      <Button
        className="w-full"
        size="lg"
        variant={exceedsBalance ? "danger" : "primary"}
        disabled={!address || ybtcToBurn === 0n || exceedsBalance || tx.status === "pending"}
        loading={tx.status === "pending"}
        onClick={handleWithdraw}
      >
        {!address
          ? "Connect Wallet First"
          : exceedsBalance
          ? "Insufficient yBTC Balance"
          : tx.status === "pending"
          ? "Withdrawing…"
          : ybtcToBurn > 0n
          ? `Burn ${formatBTC(ybtcToBurn)} yBTC → Receive ${formatBTC(wbtcToReceive)} wBTC`
          : "Enter Amount"}
      </Button>

      {/* Success */}
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
              href={`https://sepolia.voyager.online/tx/${tx.hash}`}
              target="_blank"
              rel="noreferrer"
              className="text-xs text-emerald-400/70 hover:text-emerald-300 underline"
            >
              View on Voyager →
            </a>
          </div>
        </motion.div>
      )}

      {/* Error */}
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
