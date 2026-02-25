"use client";

import { useCallback } from "react";
import { formatLeverage } from "@/lib/utils/format";
import { cn } from "@/lib/utils/cn";
import { Zap } from "lucide-react";

interface LeverageSliderProps {
  value: number;       // × 100, e.g. 150 = 1.50x
  onChange: (v: number) => void;
  maxLeverage: number; // × 100
  minLeverage?: number;
}

export function LeverageSlider({
  value,
  onChange,
  maxLeverage,
  minLeverage = 100,
}: LeverageSliderProps) {
  const pct = ((value - minLeverage) / (maxLeverage - minLeverage)) * 100;

  const levelColor =
    value <= 120
      ? "from-emerald-500 to-emerald-400"
      : value <= 150
      ? "from-yellow-500 to-yellow-400"
      : "from-orange-500 to-red-500";

  const presets = [
    { label: "1.0x", val: 100 },
    { label: "1.3x", val: 130 },
    { label: "1.5x", val: 150 },
    { label: "1.8x", val: 180 },
  ].filter((p) => p.val <= maxLeverage);

  return (
    <div>
      <div className="flex items-center justify-between mb-2">
        <p className="text-xs text-white/50 uppercase tracking-wider flex items-center gap-1.5">
          <Zap className="w-3.5 h-3.5" /> Leverage
        </p>
        <span
          className={cn(
            "text-sm font-bold",
            value <= 120 ? "text-emerald-400" : value <= 150 ? "text-yellow-400" : "text-orange-400"
          )}
        >
          {formatLeverage(value)}
        </span>
      </div>

      {/* Slider track */}
      <div className="relative h-2 rounded-full bg-white/8 mb-3">
        <div
          className={cn("h-full rounded-full bg-gradient-to-r", levelColor)}
          style={{ width: `${pct}%` }}
        />
        <input
          type="range"
          min={minLeverage}
          max={maxLeverage}
          step={5}
          value={value}
          onChange={(e) => onChange(Number(e.target.value))}
          className="absolute inset-0 w-full opacity-0 cursor-pointer h-full"
        />
        {/* Thumb indicator */}
        <div
          className="absolute top-1/2 -translate-y-1/2 w-4 h-4 rounded-full bg-white shadow-lg border-2 border-orange-400"
          style={{ left: `calc(${pct}% - 8px)` }}
        />
      </div>

      {/* Presets */}
      <div className="flex gap-1.5">
        {presets.map(({ label, val }) => (
          <button
            key={val}
            onClick={() => onChange(val)}
            className={cn(
              "flex-1 py-1 rounded-lg text-xs font-medium transition-all",
              value === val
                ? "bg-orange-500/20 border border-orange-500/30 text-orange-400"
                : "bg-white/5 border border-white/8 text-white/40 hover:text-white hover:bg-white/8"
            )}
          >
            {label}
          </button>
        ))}
      </div>

      {/* Risk warning */}
      {value > 150 && (
        <p className="text-xs text-orange-400 mt-2 bg-orange-500/10 rounded-lg px-3 py-2">
          ⚠ High leverage increases liquidation risk. Ensure you understand the risks.
        </p>
      )}
    </div>
  );
}
