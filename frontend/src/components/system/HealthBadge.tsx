"use client";

import React from "react";
import { cn } from "@/lib/utils/cn";
import { HealthStatus } from "@/types";
import { formatHealth, healthBgColor, healthColor, healthToStatus } from "@/lib/utils/format";

interface HealthBadgeProps {
  health: number; // ×100, e.g. 142 = 1.42x. 999999 = ∞ (no exposure)
  size?: "sm" | "md" | "lg";
  showIcon?: boolean;
}

export function HealthBadge({ health, size = "md", showIcon = true }: HealthBadgeProps) {
  const status = healthToStatus(health) as HealthStatus;
  const isNoExposure = health >= 999999;
  const label = isNoExposure ? "No Exposure" : status.charAt(0).toUpperCase() + status.slice(1);

  const icons: Record<HealthStatus, string> = {
    healthy:  "🟢",
    moderate: "🟡",
    warning:  "🟠",
    critical: "🔴",
  };

  const sizes = { sm: "text-xs px-2 py-0.5", md: "text-sm px-3 py-1", lg: "text-base px-4 py-1.5" };

  return (
    <span
      className={cn(
        "inline-flex items-center gap-1.5 rounded-full border font-semibold",
        sizes[size],
        healthBgColor(status),
        healthColor(status)
      )}
    >
      {showIcon && <span className="text-xs">{icons[status]}</span>}
      <span>{formatHealth(health)}</span>
      <span className="opacity-70">({label})</span>
    </span>
  );
}
