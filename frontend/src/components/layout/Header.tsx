"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { Bitcoin, Menu, X } from "lucide-react";
import { ConnectButton } from "@/components/wallet/ConnectButton";
import { NetworkModeSwitcher } from "@/components/wallet/NetworkModeSwitcher";
import { cn } from "@/lib/utils/cn";
import { useState } from "react";
import { motion, AnimatePresence } from "framer-motion";

const MOBILE_NAV = [
  { href: "/",          label: "Dashboard" },
  { href: "/vault",     label: "Vault" },
  { href: "/portfolio", label: "Portfolio" },
  { href: "/leverage",  label: "Leverage" },
  { href: "/analytics", label: "Analytics" },
];

export function Header() {
  const pathname = usePathname();
  const [mobileOpen, setMobileOpen] = useState(false);

  return (
    <>
      <header className="sticky top-0 z-40 border-b border-white/8 bg-[#080a0f]/90 backdrop-blur-md">
        <div className="flex items-center justify-between h-14 px-4 lg:px-6 max-w-screen-2xl mx-auto">

          {/* Mobile logo */}
          <div className="flex items-center gap-2 lg:hidden">
            <div className="w-7 h-7 rounded-lg bg-orange-500/20 border border-orange-500/30 flex items-center justify-center">
              <Bitcoin className="w-3.5 h-3.5 text-orange-400" />
            </div>
            <span className="text-white font-bold text-sm">BTC Vault</span>
          </div>

          {/* Desktop breadcrumb */}
          <div className="hidden lg:flex items-center gap-2 text-sm text-white/40">
            <span>BTC Vault</span>
            <span>/</span>
            <span className="text-white capitalize">{pathname.slice(1) || "Dashboard"}</span>
          </div>

          <div className="flex items-center gap-2">
            <NetworkModeSwitcher />
            <ConnectButton />
            {/* Mobile menu toggle */}
            <button
              className="lg:hidden p-2 rounded-lg hover:bg-white/8 text-white/70"
              onClick={() => setMobileOpen(!mobileOpen)}
            >
              {mobileOpen ? <X className="w-5 h-5" /> : <Menu className="w-5 h-5" />}
            </button>
          </div>
        </div>
      </header>

      {/* Mobile drawer */}
      <AnimatePresence>
        {mobileOpen && (
          <motion.div
            initial={{ opacity: 0, x: -24 }}
            animate={{ opacity: 1, x: 0 }}
            exit={{ opacity: 0, x: -24 }}
            className="fixed inset-0 z-30 lg:hidden pt-14 bg-[#080a0f]/98"
          >
            <nav className="p-4 space-y-1">
              {MOBILE_NAV.map(({ href, label }) => (
                <Link
                  key={href}
                  href={href}
                  onClick={() => setMobileOpen(false)}
                  className={cn(
                    "flex items-center px-4 py-3 rounded-xl text-base font-medium transition-all",
                    pathname === href
                      ? "bg-orange-500/15 text-orange-400"
                      : "text-white/60 hover:text-white hover:bg-white/5"
                  )}
                >
                  {label}
                </Link>
              ))}
            </nav>
          </motion.div>
        )}
      </AnimatePresence>
    </>
  );
}
