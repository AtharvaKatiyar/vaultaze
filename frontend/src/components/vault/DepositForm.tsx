"use client";

import { useState } from "react";
import { useAccount, useSendTransaction } from "@starknet-react/core";
import { Contract, uint256, shortString } from "starknet";
import { Card, CardTitle } from "@/components/ui/Card";
import { Button } from "@/components/ui/Button";
import { StrategySelector, STRATEGIES } from "./StrategySelector";
import { LeverageSlider } from "@/components/leverage/LeverageSlider";
import { useWBTCBalance, useWBTCAllowance, toBalance } from "@/lib/hooks/useUserPosition";
import { useSystemMetrics } from "@/lib/hooks/useRouterData";
import { CONTRACTS, MINIMUM_DEPOSIT, FIRST_DEPOSIT_MINIMUM } from "@/lib/contracts/addresses";
import { ERC20_ABI } from "@/lib/contracts/erc20-abi";
import { VAULT_ABI } from "@/lib/contracts/vault-abi";
import { formatBTC, formatUSD, pragmaToUSD, bpsToPercent } from "@/lib/utils/format";
import { StrategyMode, TxState } from "@/types";
import { ArrowDown, CheckCircle2, XCircle, Info, Droplets } from "lucide-react";
import { motion } from "framer-motion";
import Link from "next/link";

const BTC_DECIMALS = 8;
const SATOSHI = BigInt(1e8);

function parseBTCInput(val: string): bigint {
  const n = parseFloat(val);
  if (isNaN(n) || n <= 0) return 0n;
  return BigInt(Math.round(n * 1e8));
}

export function DepositForm() {
  const { address } = useAccount();
  const { data: wbtcBalance }   = useWBTCBalance();
  const { data: allowance }     = useWBTCAllowance();
  const { data: metrics }       = useSystemMetrics();
  const { sendAsync }           = useSendTransaction({});

  const [amount, setAmount]     = useState("");
  const [strategy, setStrategy] = useState<StrategyMode>("conservative");
  const [leverage, setLeverage] = useState(100);
  const [tx, setTx]             = useState<TxState>({ status: "idle" });

  // Derive strategy from leverage value — used when slider is dragged
  function leverageToStrategy(lev: number): StrategyMode {
    if (lev <= 100) return "conservative";
    if (lev <= 130) return "balanced";
    return "aggressive";
  }

  // Clicking a strategy card sets strategy AND snaps leverage to its default
  function handleStrategyChange(s: StrategyMode) {
    setStrategy(s);
    const st = STRATEGIES.find((x) => x.id === s)!;
    // Conservative → 1x; balanced → 1.1x (sensible default); aggressive → 1.5x
    const defaults: Record<StrategyMode, number> = {
      conservative: 100,
      balanced: 110,
      aggressive: 150,
    };
    setLeverage(defaults[s]);
  }

  // Moving the slider auto-updates the strategy badge
  function handleLeverageChange(lev: number) {
    setLeverage(lev);
    setStrategy(leverageToStrategy(lev));
  }

  const satoshiAmount  = parseBTCInput(amount);
  const wbtcBal        = toBalance(wbtcBalance);
  const allowanceBal   = toBalance(allowance);
  const hasBalance     = wbtcBal >= satoshiAmount;
  const needsApproval  = allowance !== undefined && allowanceBal < satoshiAmount;
  const btcPrice       = metrics ? pragmaToUSD(BigInt(metrics.btcUsdPrice)) : 0;
  const usdValue       = satoshiAmount > 0n ? (Number(satoshiAmount) / 1e8) * btcPrice : 0;
  const estimatedYBTC  = amount ? `≈ ${parseFloat(amount).toFixed(8)} yBTC` : "—";
  const wbtcBalBTC     = formatBTC(wbtcBal);

  const isSafeMode     = metrics?.isSafeMode;
  const tooSmall       = satoshiAmount > 0n && satoshiAmount < MINIMUM_DEPOSIT;

  async function handleApprove() {
    if (!address) return;
    setTx({ status: "approving" });
    try {
      const { transaction_hash } = await sendAsync([{
        contractAddress: CONTRACTS.MockWBTC,
        entrypoint: "approve",
        calldata: [
          CONTRACTS.BTCVault,
          ...uint256.bnToUint256(satoshiAmount * 10n).low.toString().split(""),
        ],
      }]);
      setTx({ status: "success", hash: transaction_hash });
    } catch (e: any) {
      setTx({ status: "error", error: e.message });
    }
  }

  async function handleDeposit() {
    if (!address) return;
    setTx({ status: "pending" });
    try {
      const amountU256 = uint256.bnToUint256(satoshiAmount);
      const { transaction_hash } = await sendAsync([
        // 1. Approve
        {
          contractAddress: CONTRACTS.MockWBTC,
          entrypoint: "approve",
          calldata: [CONTRACTS.BTCVault, amountU256.low.toString(), amountU256.high.toString()],
        },
        // 2. Deposit
        {
          contractAddress: CONTRACTS.BTCVault,
          entrypoint: "deposit",
          calldata: [amountU256.low.toString(), amountU256.high.toString()],
        },
        // 3. Apply leverage if > 1.0x
        ...(leverage > 100
          ? [{
              contractAddress: CONTRACTS.BTCVault,
              entrypoint: "apply_leverage",
              calldata: [leverage.toString()],
            }]
          : []),
      ]);
      setTx({ status: "success", hash: transaction_hash });
      setAmount("");
    } catch (e: any) {
      setTx({ status: "error", error: e.message });
    }
  }

  return (
    <div className="space-y-5">

      {/* Safe mode warning */}
      {isSafeMode && (
        <div className="flex items-start gap-2 bg-red-500/10 border border-red-500/20 rounded-xl px-4 py-3">
          <XCircle className="w-4 h-4 text-red-400 mt-0.5 shrink-0" />
          <p className="text-sm text-red-300">Deposits blocked — Safe Mode active. Only withdrawals allowed.</p>
        </div>
      )}

      {/* Amount input */}
      <div>
        <label className="block text-xs text-white/50 uppercase tracking-wider mb-2">Deposit Amount</label>
        <div className="relative">
          <input
            type="number"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            placeholder="0.00000000"
            className="w-full bg-white/5 border border-white/10 rounded-xl px-4 py-3 text-white text-lg font-mono placeholder:text-white/20 focus:outline-none focus:border-orange-500/50 pr-24"
          />
          <div className="absolute right-3 top-1/2 -translate-y-1/2 flex items-center gap-2">
            <span className="text-orange-400 font-semibold text-sm">wBTC</span>
          </div>
        </div>

        <div className="flex items-center justify-between mt-2">
          <span className="text-xs text-white/30">
            {usdValue > 0 ? `≈ ${formatUSD(usdValue)}` : ""}
          </span>
          <div className="flex items-center gap-3">
            {address && wbtcBal === 0n && (
              <Link
                href="/faucet"
                className="flex items-center gap-1 text-xs text-blue-400 hover:text-blue-300 transition-colors"
              >
                <Droplets className="w-3 h-3" />
                Get test wBTC
              </Link>
            )}
            <button
              className="text-xs text-orange-400 hover:text-orange-300"
              onClick={() => wbtcBal > 0n && setAmount(formatBTC(wbtcBal))}
            >
              Balance: {wbtcBalBTC} wBTC
            </button>
          </div>
        </div>

        {tooSmall && (
          <p className="text-xs text-orange-400 mt-1">
            Minimum deposit: 0.01 wBTC (0.1 wBTC for first deposit)
          </p>
        )}
      </div>

      {/* You receive */}
      <div className="flex items-center justify-center">
        <ArrowDown className="w-5 h-5 text-white/30" />
      </div>
      <div className="bg-white/3 rounded-xl px-4 py-3 flex items-center justify-between">
        <div>
          <p className="text-xs text-white/40 mb-1">You receive</p>
          <p className="text-lg font-mono text-emerald-400">{estimatedYBTC}</p>
        </div>
        <div className="text-right">
          <p className="text-xs text-white/40 mb-1">Token</p>
          <p className="text-sm font-semibold text-white">yBTC</p>
        </div>
      </div>

      {/* Strategy */}
      <StrategySelector value={strategy} onChange={handleStrategyChange} />

      {/* Leverage — only for non-conservative strategies; max capped to strategy bound */}
      {strategy !== "conservative" && (() => {
        const st = STRATEGIES.find((x) => x.id === strategy)!;
        return (
          <LeverageSlider
            value={leverage}
            onChange={handleLeverageChange}
            minLeverage={101}
            maxLeverage={st.leverageMax}
          />
        );
      })()}

      {/* APY estimate — use strategy ranges, not on-chain APY (which is 0 on testnet) */}
      {(() => {
        const st = STRATEGIES.find((x) => x.id === strategy)!;
        const levMultiplier = leverage / 100;
        const apyLow  = (st.apyRange[0] * levMultiplier).toFixed(1);
        const apyHigh = (st.apyRange[1] * levMultiplier).toFixed(1);
        const apyLabel = `${apyLow}–${apyHigh}%`;
        return (
          <div className="flex items-center gap-2 text-xs text-white/50 bg-white/3 rounded-lg px-3 py-2">
            <Info className="w-3.5 h-3.5 text-emerald-400 shrink-0" />
            Estimated APY:&nbsp;
            <span className="text-emerald-400 font-semibold">{apyLabel}</span>
            {leverage > 100 && (
              <span className="text-white/30">
                &nbsp;·&nbsp;{levMultiplier.toFixed(2)}× leverage
              </span>
            )}
          </div>
        );
      })()}

      {/* Action button */}
      <Button
        className="w-full"
        size="lg"
        disabled={!address || !amount || tooSmall || (satoshiAmount > 0n && !hasBalance) || isSafeMode}
        loading={tx.status === "pending" || tx.status === "approving"}
        onClick={handleDeposit}
      >
        {!address
          ? "Connect Wallet First"
          : isSafeMode
          ? "Deposits Disabled (Safe Mode)"
          : tx.status === "approving"
          ? "Approving wBTC..."
          : tx.status === "pending"
          ? "Depositing..."
          : `Approve & Deposit ${amount || "0"} wBTC`}
      </Button>

      {/* Tx status */}
      {tx.status === "success" && tx.hash && (
        <motion.div
          initial={{ opacity: 0, y: 8 }}
          animate={{ opacity: 1, y: 0 }}
          className="flex items-start gap-2 bg-emerald-500/10 border border-emerald-500/20 rounded-xl px-4 py-3"
        >
          <CheckCircle2 className="w-4 h-4 text-emerald-400 mt-0.5 shrink-0" />
          <div>
            <p className="text-sm text-emerald-300 font-medium">Deposit successful!</p>
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
          <XCircle className="w-4 h-4 text-red-400 mt-0.5 shrink-0" />
          <p className="text-sm text-red-300">{tx.error || "Transaction failed"}</p>
        </motion.div>
      )}
    </div>
  );
}
