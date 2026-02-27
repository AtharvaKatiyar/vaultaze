import type { Metadata } from "next";
import { Geist } from "next/font/google";
import "./globals.css";
import StarknetProvider from "@/providers/StarknetProvider";
import { NetworkModeProvider } from "@/contexts/NetworkMode";

const geist = Geist({ subsets: ["latin"], variable: "--font-geist" });

export const metadata: Metadata = {
  title: "Vaultaze — Autonomous Bitcoin Yield Vault on Starknet",
  description:
    "Earn yield on your BTC with Vaultaze. Non-custodial Bitcoin yield vault powered by the autonomous BTC Security Router on Starknet Sepolia.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className="dark">
      <body className={`${geist.variable} font-sans antialiased bg-[#060810] text-white`}>
        <StarknetProvider>
          <NetworkModeProvider>
            {children}
          </NetworkModeProvider>
        </StarknetProvider>
      </body>
    </html>
  );
}
