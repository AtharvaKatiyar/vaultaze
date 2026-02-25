"use client";

import { useAccount, useConnect, useDisconnect } from "@starknet-react/core";
import { Button } from "@/components/ui/Button";
import { shortAddress, formatBTC } from "@/lib/utils/format";
import { toBalance, useWBTCBalance, useYBTCBalance } from "@/lib/hooks/useUserPosition";
import { Wallet, LogOut, ChevronDown, Bitcoin, Coins, Droplets, ExternalLink } from "lucide-react";
import { useState, useRef, useEffect } from "react";
import { motion, AnimatePresence } from "framer-motion";
import Link from "next/link";

const STARKSCAN = "https://sepolia.starkscan.co";

export function ConnectButton() {
  const { address, isConnected } = useAccount();
  const { connect, connectors }  = useConnect();
  const { disconnect }           = useDisconnect();
  const [open, setOpen]          = useState(false);
  const ref                      = useRef<HTMLDivElement>(null);

  const { data: rawWbtc } = useWBTCBalance();
  const { data: rawYbtc } = useYBTCBalance();

  const wbtcBal     = toBalance(rawWbtc);
  const ybtcBal     = toBalance(rawYbtc);
  const hasWbtc     = wbtcBal > 0n;
  const hasYbtc     = ybtcBal > 0n;
  const wbtcDisplay = formatBTC(wbtcBal, 6);
  const ybtcDisplay = formatBTC(ybtcBal, 6);

  // Close dropdown on outside click
  useEffect(() => {
    function handler(e: MouseEvent) {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    }
    if (open) document.addEventListener("mousedown", handler);
    return () => document.removeEventListener("mousedown", handler);
  }, [open]);

  // ── Connected ─────────────────────────────────────────────────────────────
  if (isConnected && address) {
    return (
      <div className="relative" ref={ref}>
        {/* Trigger */}
        <button
          onClick={() => setOpen(!open)}
          className="flex items-center gap-2 bg-white/[0.06] hover:bg-white/[0.09] border border-white/10 rounded-xl px-3 py-2 text-sm font-medium text-white transition-all"
        >
          <span className="w-2 h-2 rounded-full bg-emerald-400 animate-pulse shrink-0" />

          {/* wBTC chip */}
          {hasWbtc && (
            <span className="hidden sm:flex items-center gap-1 text-xs text-orange-300 bg-orange-500/10 rounded-lg px-1.5 py-0.5 border border-orange-500/15">
              <Bitcoin className="w-2.5 h-2.5" />
              {formatBTC(wbtcBal, 4)}
            </span>
          )}
          {/* yBTC chip */}
          {hasYbtc && (
            <span className="hidden md:flex items-center gap-1 text-xs text-emerald-300 bg-emerald-500/10 rounded-lg px-1.5 py-0.5 border border-emerald-500/15">
              <Coins className="w-2.5 h-2.5" />
              {formatBTC(ybtcBal, 4)}
            </span>
          )}

          <span className="text-white/50 font-mono text-xs">{shortAddress(address)}</span>
          <ChevronDown className={`w-3.5 h-3.5 text-white/30 transition-transform shrink-0 ${open ? "rotate-180" : ""}`} />
        </button>

        <AnimatePresence>
          {open && (
            <motion.div
              initial={{ opacity: 0, y: 6, scale: 0.96 }}
              animate={{ opacity: 1, y: 0, scale: 1 }}
              exit={{ opacity: 0, y: 6, scale: 0.96 }}
              transition={{ duration: 0.15 }}
              className="absolute right-0 mt-2 w-72 bg-[#0d0f17] border border-white/10 rounded-2xl shadow-2xl shadow-black/50 z-50 overflow-hidden"
            >
              {/* Address */}
              <div className="px-4 pt-4 pb-3 border-b border-white/8">
                <p className="text-[10px] text-white/30 uppercase tracking-wider mb-1.5">Connected wallet</p>
                <div className="flex items-center gap-2">
                  <p className="text-xs font-mono text-white/70 flex-1 truncate">{address}</p>
                  <a
                    href={`${STARKSCAN}/contract/${address}`}
                    target="_blank"
                    rel="noreferrer"
                    className="text-white/20 hover:text-blue-400 transition-colors shrink-0"
                    onClick={(e) => e.stopPropagation()}
                  >
                    <ExternalLink className="w-3 h-3" />
                  </a>
                </div>
              </div>

              {/* Token balances */}
              <div className="px-4 py-3 border-b border-white/8">
                <p className="text-[10px] text-white/30 uppercase tracking-wider mb-3">Your Balances</p>

                {/* Mock wBTC row */}
                <div className="flex items-center justify-between mb-2.5">
                  <div className="flex items-center gap-2.5">
                    <div className="w-8 h-8 rounded-xl bg-orange-500/12 border border-orange-500/20 flex items-center justify-center">
                      <Bitcoin className="w-4 h-4 text-orange-400" />
                    </div>
                    <div>
                      <p className="text-xs font-semibold text-white">Mock wBTC</p>
                      <p className="text-[10px] text-white/30">Sepolia testnet token</p>
                    </div>
                  </div>
                  <div className="text-right">
                    <p className={`text-xs font-mono font-semibold ${hasWbtc ? "text-white" : "text-white/30"}`}>
                      {wbtcDisplay}
                    </p>
                    <p className="text-[10px] text-white/30">wBTC</p>
                  </div>
                </div>

                {/* yBTC row */}
                <div className="flex items-center justify-between">
                  <div className="flex items-center gap-2.5">
                    <div className="w-8 h-8 rounded-xl bg-emerald-500/12 border border-emerald-500/20 flex items-center justify-center">
                      <Coins className="w-4 h-4 text-emerald-400" />
                    </div>
                    <div>
                      <p className="text-xs font-semibold text-white">yBTC</p>
                      <p className="text-[10px] text-white/30">Vault yield shares</p>
                    </div>
                  </div>
                  <div className="text-right">
                    <p className={`text-xs font-mono font-semibold ${hasYbtc ? "text-emerald-300" : "text-white/30"}`}>
                      {ybtcDisplay}
                    </p>
                    <p className="text-[10px] text-white/30">yBTC</p>
                  </div>
                </div>
              </div>

              {/* Faucet CTA – only when no wBTC */}
              {!hasWbtc && (
                <Link
                  href="/faucet"
                  onClick={() => setOpen(false)}
                  className="flex items-center justify-between px-4 py-2.5 text-xs border-b border-white/8 bg-blue-500/5 hover:bg-blue-500/10 transition-colors group"
                >
                  <div className="flex items-center gap-2 text-blue-400">
                    <Droplets className="w-3.5 h-3.5" />
                    <span>Get test wBTC from Faucet</span>
                  </div>
                  <span className="text-blue-400/40 group-hover:text-blue-400 transition-colors">→</span>
                </Link>
              )}

              {/* Quick nav */}
              <div className="px-4 py-2 border-b border-white/8 flex gap-2">
                <Link
                  href="/vault"
                  onClick={() => setOpen(false)}
                  className="flex-1 text-center text-xs py-1.5 rounded-lg bg-orange-500/10 hover:bg-orange-500/15 border border-orange-500/15 text-orange-300 transition-colors"
                >
                  Deposit
                </Link>
                <Link
                  href="/portfolio"
                  onClick={() => setOpen(false)}
                  className="flex-1 text-center text-xs py-1.5 rounded-lg bg-white/5 hover:bg-white/8 border border-white/10 text-white/50 transition-colors"
                >
                  Portfolio
                </Link>
              </div>

              {/* Disconnect */}
              <button
                onClick={() => { disconnect(); setOpen(false); }}
                className="w-full flex items-center gap-2 px-4 py-3 text-sm text-red-400 hover:bg-red-500/10 transition-colors"
              >
                <LogOut className="w-4 h-4" />
                Disconnect
              </button>
            </motion.div>
          )}
        </AnimatePresence>
      </div>
    );
  }

  // ── Disconnected ─────────────────────────────────────────────────────────
  return (
    <div className="relative" ref={ref}>
      <Button onClick={() => setOpen(!open)} className="gap-2">
        <Wallet className="w-4 h-4" />
        Connect Wallet
      </Button>

      <AnimatePresence>
        {open && (
          <motion.div
            initial={{ opacity: 0, y: 6, scale: 0.96 }}
            animate={{ opacity: 1, y: 0, scale: 1 }}
            exit={{ opacity: 0, y: 6, scale: 0.96 }}
            transition={{ duration: 0.15 }}
            className="absolute right-0 mt-2 w-56 bg-[#0d0f17] border border-white/10 rounded-xl shadow-xl z-50 overflow-hidden"
          >
            <div className="p-3 border-b border-white/8">
              <p className="text-xs text-white/60 font-medium uppercase tracking-wide">Choose Wallet</p>
            </div>
            {connectors.map((c) => (
              <button
                key={c.id}
                onClick={() => { connect({ connector: c }); setOpen(false); }}
                className="w-full flex items-center gap-3 px-4 py-3 text-sm text-white hover:bg-white/5 transition-colors"
              >
                <Wallet className="w-4 h-4 text-orange-400" />
                {c.name}
              </button>
            ))}
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}
