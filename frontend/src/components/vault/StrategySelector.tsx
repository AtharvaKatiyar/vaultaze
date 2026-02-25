"use client";

import { StrategyMode, StrategyOption } from "@/types";
import { cn } from "@/lib/utils/cn";
import { ShieldCheck, Scale, Flame } from "lucide-react";

const STRATEGIES: StrategyOption[] = [
  {
    id: "conservative",
    label: "Conservative",
    description: "No leverage · Stable yield strategies · Low risk",
    leverageMin: 100,
    leverageMax: 100,
    apyRange: [6, 8],
    riskLevel: 1,
  },
  {
    id: "balanced",
    label: "Balanced",
    description: "Up to 1.3x leverage · Mixed strategies · Medium risk",
    leverageMin: 100,
    leverageMax: 130,
    apyRange: [10, 14],
    riskLevel: 3,
  },
  {
    id: "aggressive",
    label: "Aggressive",
    description: "Up to 1.8x leverage · Higher yield focus · Higher risk",
    leverageMin: 100,
    leverageMax: 180,
    apyRange: [15, 20],
    riskLevel: 5,
  },
];

const ICONS = {
  conservative: ShieldCheck,
  balanced: Scale,
  aggressive: Flame,
};

const ACCENT = {
  conservative: "border-emerald-500/40 bg-emerald-500/5",
  balanced:     "border-yellow-500/40 bg-yellow-500/5",
  aggressive:   "border-orange-500/40 bg-orange-500/5",
};

const ICON_COLOR = {
  conservative: "text-emerald-400",
  balanced:     "text-yellow-400",
  aggressive:   "text-orange-400",
};

interface StrategySelectorProps {
  value: StrategyMode;
  onChange: (s: StrategyMode) => void;
}

export function StrategySelector({ value, onChange }: StrategySelectorProps) {
  return (
    <div>
      <p className="text-xs text-white/50 uppercase tracking-wider mb-2">Strategy</p>
      <div className="grid grid-cols-3 gap-2">
        {STRATEGIES.map((s) => {
          const Icon = ICONS[s.id];
          const active = value === s.id;
          return (
            <button
              key={s.id}
              onClick={() => onChange(s.id)}
              className={cn(
                "flex flex-col items-start gap-1.5 rounded-xl border p-3 text-left transition-all",
                active
                  ? ACCENT[s.id]
                  : "border-white/8 bg-white/3 hover:border-white/20"
              )}
            >
              <Icon className={cn("w-4 h-4", active ? ICON_COLOR[s.id] : "text-white/30")} />
              <span className={cn("text-xs font-semibold", active ? "text-white" : "text-white/50")}>
                {s.label}
              </span>
              <span className="text-[10px] text-white/30">
                {s.apyRange[0]}–{s.apyRange[1]}% APY
              </span>
              {/* Risk dots */}
              <div className="flex gap-0.5 mt-0.5">
                {[1, 2, 3, 4, 5].map((i) => (
                  <span
                    key={i}
                    className={cn(
                      "w-1 h-1 rounded-full",
                      i <= s.riskLevel
                        ? active ? ICON_COLOR[s.id] : "bg-white/30"
                        : "bg-white/10"
                    )}
                    style={i <= s.riskLevel && active ? {
                      backgroundColor: s.id === "conservative" ? "#34d399" : s.id === "balanced" ? "#fbbf24" : "#f97316",
                    } : undefined}
                  />
                ))}
              </div>
            </button>
          );
        })}
      </div>
    </div>
  );
}
