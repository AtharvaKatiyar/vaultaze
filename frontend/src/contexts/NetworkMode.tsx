"use client";

import React, { createContext, useContext, useState } from "react";

export type NetworkMode = "sepolia" | "btc";

interface NetworkModeContextValue {
  mode: NetworkMode;
  setMode: (m: NetworkMode) => void;
  isSepolia: boolean;
}

const NetworkModeContext = createContext<NetworkModeContextValue>({
  mode: "sepolia",
  setMode: () => {},
  isSepolia: true,
});

export function NetworkModeProvider({ children }: { children: React.ReactNode }) {
  const [mode, setMode] = useState<NetworkMode>("sepolia");
  return (
    <NetworkModeContext.Provider value={{ mode, setMode, isSepolia: mode === "sepolia" }}>
      {children}
    </NetworkModeContext.Provider>
  );
}

export function useNetworkMode() {
  return useContext(NetworkModeContext);
}
