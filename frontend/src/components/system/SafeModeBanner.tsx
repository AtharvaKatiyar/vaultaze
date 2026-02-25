"use client";

import { AlertTriangle } from "lucide-react";
import { motion } from "framer-motion";

export function SafeModeBanner() {
  return (
    <motion.div
      initial={{ opacity: 0, y: -16 }}
      animate={{ opacity: 1, y: 0 }}
      className="w-full bg-red-500/15 border-b border-red-500/30 px-4 py-3 flex items-center justify-center gap-3"
    >
      <AlertTriangle className="text-red-400 w-4 h-4 shrink-0" />
      <p className="text-red-300 text-sm font-medium">
        <span className="font-bold text-red-400">⚠ SAFE MODE ACTIVE</span>
        &nbsp;— Only withdrawals &amp; repayments are permitted until BTC health recovers.
      </p>
    </motion.div>
  );
}
