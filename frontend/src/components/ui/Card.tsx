"use client";

import React from "react";
import { cn } from "@/lib/utils/cn";

interface CardProps extends React.HTMLAttributes<HTMLDivElement> {
  glass?: boolean;
  glow?: "orange" | "green" | "red" | "yellow";
}

export function Card({ className, glass, glow, children, ...props }: CardProps) {
  return (
    <div
      className={cn(
        "rounded-2xl border p-6",
        glass
          ? "bg-white/5 border-white/10 backdrop-blur-sm"
          : "bg-[#0f1117] border-white/8",
        glow === "orange" && "shadow-[0_0_24px_rgba(251,146,60,0.08)]",
        glow === "green"  && "shadow-[0_0_24px_rgba(52,211,153,0.08)]",
        glow === "red"    && "shadow-[0_0_24px_rgba(239,68,68,0.08)]",
        glow === "yellow" && "shadow-[0_0_24px_rgba(251,191,36,0.08)]",
        className
      )}
      {...props}
    >
      {children}
    </div>
  );
}

export function CardHeader({ className, children, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return (
    <div className={cn("mb-4", className)} {...props}>
      {children}
    </div>
  );
}

export function CardTitle({ className, children, ...props }: React.HTMLAttributes<HTMLHeadingElement>) {
  return (
    <h3 className={cn("text-sm font-medium text-white/60 uppercase tracking-wider", className)} {...props}>
      {children}
    </h3>
  );
}

export function CardValue({ className, children, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return (
    <div className={cn("text-2xl font-bold text-white mt-1", className)} {...props}>
      {children}
    </div>
  );
}
