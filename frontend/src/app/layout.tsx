import type { Metadata } from "next";
import { Geist } from "next/font/google";
import "./globals.css";
import StarknetProvider from "@/providers/StarknetProvider";
import { NetworkModeProvider } from "@/contexts/NetworkMode";

const geist = Geist({ subsets: ["latin"], variable: "--font-geist" });

export const metadata: Metadata = {
  title: "BTC Vault — Autonomous BTC Security Infrastructure on Starknet",
  description:
    "Earn yield on your BTC with autonomous risk management, powered by the BTC Security Router on Starknet Sepolia.",
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
