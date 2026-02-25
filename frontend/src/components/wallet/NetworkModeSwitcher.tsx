"use client";

import React, { useRef, useState, useEffect } from "react";
import { motion, AnimatePresence } from "framer-motion";
import { Bitcoin, FlaskConical, Lock, Sparkles, ArrowRight } from "lucide-react";
import { cn } from "@/lib/utils/cn";
import { useNetworkMode, type NetworkMode } from "@/contexts/NetworkMode";

// ─────────────────────────────────────────────────────────────────────────────
//  NetworkModeSwitcher
//  A split-pill button: [ 🧪 Sepolia | ₿ BTC ]
//  Sepolia is the default / active testnet mode (mock wBTC, no real funds).
//  BTC opens a "coming soon" popover – mainnet support is not yet live.
// ─────────────────────────────────────────────────────────────────────────────

interface SegmentProps {
  active: boolean;
  onClick: () => void;
  children: React.ReactNode;
  className?: string;
}

function Segment({ active, onClick, children, className }: SegmentProps) {
  return (
    <button
      onClick={onClick}
      className={cn(
        "relative flex items-center gap-1.5 px-3 py-1.5 text-xs font-semibold transition-all duration-200 select-none",
        active
          ? "text-orange-300"
          : "text-white/40 hover:text-white/70",
        className
      )}
    >
      {children}
    </button>
  );
}

export function NetworkModeSwitcher() {
  const { mode, setMode } = useNetworkMode();
  const [btcPopoverOpen, setBtcPopoverOpen] = useState(false);
  const popoverRef = useRef<HTMLDivElement>(null);

  // Close popover on outside click
  useEffect(() => {
    function handleClick(e: MouseEvent) {
      if (popoverRef.current && !popoverRef.current.contains(e.target as Node)) {
        setBtcPopoverOpen(false);
      }
    }
    if (btcPopoverOpen) document.addEventListener("mousedown", handleClick);
    return () => document.removeEventListener("mousedown", handleClick);
  }, [btcPopoverOpen]);

  function handleSepoliaClick() {
    setMode("sepolia");
    setBtcPopoverOpen(false);
  }

  function handleBtcClick() {
    // BTC mainnet not live — open informational popover instead
    setBtcPopoverOpen((v) => !v);
  }

  return (
    <div className="relative" ref={popoverRef}>
      {/* ── Split pill container ── */}
      <div className="flex items-center bg-white/[0.04] border border-white/10 rounded-xl overflow-hidden">

        {/* Sliding active indicator */}
        <div className="absolute inset-0 rounded-xl pointer-events-none">
          <motion.div
            layout
            layoutId="network-active-bg"
            className={cn(
              "absolute top-0 bottom-0 rounded-[10px] transition-colors",
              mode === "sepolia"
                ? "bg-orange-500/12 border border-orange-500/20 left-0 w-1/2"
                : "bg-amber-500/10 border border-amber-500/20 left-1/2 w-1/2"
            )}
            transition={{ type: "spring", stiffness: 400, damping: 35 }}
          />
        </div>

        {/* Sepolia segment */}
        <Segment active={mode === "sepolia"} onClick={handleSepoliaClick}>
          <FlaskConical
            className={cn(
              "w-3 h-3 transition-colors",
              mode === "sepolia" ? "text-orange-400" : "text-white/30"
            )}
          />
          <span>Sepolia</span>
          {mode === "sepolia" && (
            <span className="w-1.5 h-1.5 rounded-full bg-emerald-400 animate-pulse" />
          )}
        </Segment>

        {/* Divider */}
        <div className="w-px h-4 bg-white/10 shrink-0" />

        {/* BTC segment */}
        <Segment active={mode === "btc"} onClick={handleBtcClick}>
          <Bitcoin
            className={cn(
              "w-3 h-3 transition-colors",
              mode === "btc" ? "text-amber-400" : "text-white/30"
            )}
          />
          <span>BTC</span>
          <Lock className="w-2.5 h-2.5 text-white/20 ml-0.5" />
        </Segment>
      </div>

      {/* ── BTC Coming-Soon Popover ── */}
      <AnimatePresence>
        {btcPopoverOpen && (
          <motion.div
            initial={{ opacity: 0, y: 8, scale: 0.95 }}
            animate={{ opacity: 1, y: 0, scale: 1 }}
            exit={{ opacity: 0, y: 8, scale: 0.95 }}
            transition={{ duration: 0.18 }}
            className="absolute right-0 mt-2 w-72 bg-[#0d0f17] border border-white/10 rounded-2xl shadow-2xl shadow-black/60 z-50 overflow-hidden"
          >
            {/* Header gradient strip */}
            <div className="h-1 w-full bg-gradient-to-r from-amber-500 via-orange-400 to-amber-600" />

            <div className="p-4">
              {/* Title row */}
              <div className="flex items-center gap-2 mb-3">
                <div className="w-8 h-8 rounded-xl bg-amber-500/15 border border-amber-500/20 flex items-center justify-center">
                  <Bitcoin className="w-4 h-4 text-amber-400" />
                </div>
                <div>
                  <p className="text-sm font-semibold text-white">Bitcoin Mainnet</p>
                  <p className="text-[11px] text-white/40">Real BTC — coming soon</p>
                </div>
                <span className="ml-auto flex items-center gap-1 text-[10px] font-semibold text-amber-400 bg-amber-500/10 border border-amber-500/20 rounded-full px-2 py-0.5">
                  <Sparkles className="w-2.5 h-2.5" />
                  Soon
                </span>
              </div>

              <p className="text-xs text-white/50 leading-relaxed mb-4">
                Mainnet support will let you deposit real BTC via a trustless Starknet bridge.
                Until then, use <span className="text-orange-400 font-medium">Sepolia</span> to
                test all vault features with mock wBTC — no real funds required.
              </p>

              {/* Feature list */}
              <div className="space-y-2 mb-4">
                {[
                  { icon: "🧪", text: "Sepolia — test all features now (mock wBTC)" },
                  { icon: "⛓️", text: "Native BTC bridge via Starkgate" },
                  { icon: "🔐", text: "Non-custodial, fully on-chain" },
                  { icon: "⚡", text: "Same vault logic, real collateral" },
                ].map(({ icon, text }) => (
                  <div key={text} className="flex items-start gap-2 text-xs text-white/50">
                    <span className="text-sm leading-none mt-0.5">{icon}</span>
                    <span>{text}</span>
                  </div>
                ))}
              </div>

              {/* CTA — stay on Sepolia */}
              <button
                onClick={() => { handleSepoliaClick(); }}
                className="w-full flex items-center justify-between px-3 py-2.5 rounded-xl bg-orange-500/10 hover:bg-orange-500/15 border border-orange-500/20 transition-colors group"
              >
                <div className="flex items-center gap-2">
                  <FlaskConical className="w-3.5 h-3.5 text-orange-400" />
                  <span className="text-xs font-semibold text-orange-300">Continue on Sepolia</span>
                </div>
                <ArrowRight className="w-3.5 h-3.5 text-orange-400/60 group-hover:text-orange-400 transition-colors" />
              </button>
            </div>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}
