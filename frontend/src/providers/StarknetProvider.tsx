"use client";

import React from "react";
import { StarknetConfig, jsonRpcProvider, argent, braavos } from "@starknet-react/core";
import { sepolia } from "@starknet-react/chains";
import type { Chain } from "@starknet-react/chains";

const connectors = [argent(), braavos()];

// Use env-configured RPC or fall back to Alchemy demo (confirmed working on Sepolia)
const RPC_URL =
  process.env.NEXT_PUBLIC_RPC_URL ||
  "https://starknet-sepolia.g.alchemy.com/starknet/version/rpc/v0_7/demo";

const provider = jsonRpcProvider({
  rpc: (_chain: Chain) => ({ nodeUrl: RPC_URL }),
});

export default function StarknetProvider({ children }: { children: React.ReactNode }) {
  return (
    <StarknetConfig
      chains={[sepolia]}
      provider={provider}
      connectors={connectors}
      autoConnect
    >
      {children}
    </StarknetConfig>
  );
}
