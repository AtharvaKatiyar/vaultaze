"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { cn } from "@/lib/utils/cn";
import {
  LayoutDashboard,
  Vault,
  Briefcase,
  Zap,
  BarChart3,
  ExternalLink,
  Shield,
  Bitcoin,
  Droplets,
  FlaskConical,
} from "lucide-react";
import { EXPLORERS } from "@/lib/contracts/addresses";
import { useNetworkMode } from "@/contexts/NetworkMode";

const NAV = [
  { href: "/dashboard", label: "Dashboard",  icon: LayoutDashboard },
  { href: "/vault",     label: "Vault",      icon: Vault },
  { href: "/portfolio", label: "Portfolio",  icon: Briefcase },
  { href: "/leverage",  label: "Leverage",   icon: Zap },
  { href: "/analytics", label: "Analytics",  icon: BarChart3 },
  { href: "/faucet",    label: "Faucet",     icon: Droplets },
];

export function Sidebar() {
  const pathname = usePathname();
  const { mode } = useNetworkMode();

  return (
    <aside className="hidden lg:flex flex-col w-60 shrink-0 h-screen sticky top-0 border-r border-white/8 bg-[#080a0f] p-4">

      {/* Logo */}
      <div className="flex items-center gap-2.5 px-2 mb-8">
        <div className="flex-1 min-w-0">
          <span className="text-white font-bold text-base">Vaultaze</span>
          <div className="flex items-center gap-1.5 mt-0.5">
            {mode === "sepolia" ? (
              <>
                <FlaskConical className="w-2.5 h-2.5 text-orange-400/70" />
                <span className="text-[10px] text-orange-400/70 font-medium">Sepolia Testnet</span>
                <span className="w-1.5 h-1.5 rounded-full bg-emerald-400 animate-pulse" />
              </>
            ) : (
              <>
                <Bitcoin className="w-2.5 h-2.5 text-amber-400/70" />
                <span className="text-[10px] text-amber-400/70 font-medium">BTC Mainnet</span>
              </>
            )}
          </div>
        </div>
      </div>

      {/* Nav items */}
      <nav className="flex-1 space-y-1">
        {NAV.map(({ href, label, icon: Icon }) => {
          const active = pathname === href;
          return (
            <Link
              key={href}
              href={href}
              className={cn(
                "flex items-center gap-3 px-3 py-2.5 rounded-xl text-sm font-medium transition-all",
                active
                  ? "bg-orange-500/15 text-orange-400 border border-orange-500/20"
                  : "text-white/50 hover:text-white hover:bg-white/5"
              )}
            >
              <Icon className="w-4 h-4" />
              {label}
            </Link>
          );
        })}
      </nav>

      {/* Security Router badge */}
      <div className="mt-auto pt-4 border-t border-white/8">
        <div className="bg-white/3 rounded-xl p-3">
          <div className="flex items-center gap-2 mb-2">
            <Shield className="w-3.5 h-3.5 text-emerald-400" />
            <span className="text-xs font-medium text-white/60">Security Router</span>
          </div>
          <p className="text-[10px] text-white/30 mb-2 font-mono break-all">
            0x014c...2639
          </p>
          <a
            href={EXPLORERS.BTCVault}
            target="_blank"
            rel="noopener noreferrer"
            className="flex items-center gap-1 text-[10px] text-orange-400 hover:text-orange-300 transition-colors"
          >
            View on Voyager <ExternalLink className="w-2.5 h-2.5" />
          </a>
        </div>
      </div>
    </aside>
  );
}
