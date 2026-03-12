"use client";

import React, { useState, useEffect } from "react";
import { useAuthGuard } from "@/lib/hooks/useAuthGuard";
import { AppLayout } from "@/components/layout/AppLayout";
import { Card, CardTitle } from "@/components/ui/Card";
import { Button } from "@/components/ui/Button";
import {
  Droplets,
  RefreshCw,
  CheckCircle2,
  XCircle,
  Copy,
  ExternalLink,
  Info,
  Bitcoin,
  Wallet,
  Rocket,
  Clock,
  Wifi,
  WifiOff,
} from "lucide-react";
import { useAccount } from "@starknet-react/core";
import { shortAddress, formatBTC } from "@/lib/utils/format";
import { CONTRACTS } from "@/lib/contracts/addresses";
import { motion, AnimatePresence } from "framer-motion";

// ─── Config ──────────────────────────────────────────────────────────────────

const FAUCET_API =
  process.env.NEXT_PUBLIC_FAUCET_API_URL ?? "http://localhost:8400";
const STARKSCAN  = "https://sepolia.voyager.online";

const AMOUNT_PRESETS = [
  { label: "0.1 wBTC", satoshi: 10_000_000  },
  { label: "0.5 wBTC", satoshi: 50_000_000  },
  { label: "1 wBTC",   satoshi: 100_000_000 },
  { label: "5 wBTC",   satoshi: 500_000_000 },
];

// ─── Small helpers ────────────────────────────────────────────────────────────

function CopyButton({ text }: { text: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <button
      onClick={() => { navigator.clipboard.writeText(text); setCopied(true); setTimeout(() => setCopied(false), 1500); }}
      className="ml-1 opacity-50 hover:opacity-100 transition-opacity"
      title="Copy"
    >
      {copied ? <CheckCircle2 className="w-3.5 h-3.5 text-emerald-400" /> : <Copy className="w-3.5 h-3.5" />}
    </button>
  );
}

// ─── Types ────────────────────────────────────────────────────────────────────

type FaucetStatus = "checking" | "online" | "offline";

interface ApiMintResult {
  tx_hash: string;
  amount_btc: number;
  message: string;
}

interface ApiError {
  detail?: { error: string; message: string; retry_after_seconds?: number };
}

// ─── Faucet Page ─────────────────────────────────────────────────────────────

export default function FaucetPage() {
  useAuthGuard();
  const { address, isConnected } = useAccount();

  // ── Amount selection
  const [selectedIdx,  setSelectedIdx]  = useState(2); // default 1 wBTC
  const [customBtc,    setCustomBtc]    = useState("");
  const [recipient,    setRecipient]    = useState("");

  // ── API faucet state
  const [faucetStatus, setFaucetStatus] = useState<FaucetStatus>("checking");
  const [apiPending,   setApiPending]   = useState(false);
  const [apiResult,    setApiResult]    = useState<ApiMintResult | null>(null);
  const [apiError,     setApiError]     = useState<string | null>(null);
  const [rateLimitMsg, setRateLimitMsg] = useState<string | null>(null);

  // Auto-fill recipient when wallet connects
  useEffect(() => { if (address && !recipient) setRecipient(address); }, [address, recipient]);

  // Check if faucet API is reachable on mount
  useEffect(() => {
    setFaucetStatus("checking");
    fetch(`${FAUCET_API}/health`, { signal: AbortSignal.timeout(4000) })
      .then(r => setFaucetStatus(r.ok ? "online" : "offline"))
      .catch(() => setFaucetStatus("offline"));
  }, []);

  // Derived values
  const satoshiAmount = customBtc
    ? Math.round(parseFloat(customBtc) * 1e8)
    : AMOUNT_PRESETS[selectedIdx]?.satoshi ?? 100_000_000;
  const btcDisplay = (satoshiAmount / 1e8).toFixed(satoshiAmount >= 1e8 ? 2 : 4);
  const recipientAddr = recipient || address || "";

  // ── API mint (any user) ───────────────────────────────────────────────────
  async function handleApiMint() {
    if (!recipientAddr) return;
    setApiPending(true);
    setApiResult(null);
    setApiError(null);
    setRateLimitMsg(null);

    try {
      const res = await fetch(`${FAUCET_API}/faucet/mint`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ address: recipientAddr, amount_satoshi: satoshiAmount }),
      });

      const json = await res.json();

      if (res.status === 429) {
        const d = (json as ApiError).detail;
        setRateLimitMsg(d?.message ?? "Rate limited. Try again later.");
      } else if (!res.ok) {
        const d = (json as ApiError).detail;
        setApiError(d?.message ?? json?.detail ?? "Mint failed");
      } else {
        setApiResult(json as ApiMintResult);
      }
    } catch (e: unknown) {
      setApiError((e as Error).message ?? "Network error");
    } finally {
      setApiPending(false);
    }
  }

  return (
    <AppLayout>
      <div className="max-w-2xl mx-auto space-y-5">

        {/* ── Header */}
        <div>
          <h1 className="text-2xl font-bold text-white flex items-center gap-2.5">
            <Droplets className="w-6 h-6 text-blue-400" />
            Testnet Faucet
          </h1>
          <p className="text-white/40 text-sm mt-1">
            Get test wBTC on Starknet Sepolia — works like a real BTC faucet.
          </p>
        </div>

        {/* ── Faucet status badge */}
        <div className="flex items-center gap-2 text-xs">
          {faucetStatus === "checking" && (
            <span className="flex items-center gap-1.5 text-white/30 animate-pulse">
              <RefreshCw className="w-3 h-3 animate-spin" /> Checking faucet…
            </span>
          )}
          {faucetStatus === "online" && (
            <span className="flex items-center gap-1.5 text-emerald-400 bg-emerald-500/10 border border-emerald-500/20 rounded-full px-3 py-1">
              <Wifi className="w-3 h-3" /> Faucet server online — open to all wallets
            </span>
          )}
          {faucetStatus === "offline" && (
            <span className="flex items-center gap-1.5 text-orange-400 bg-orange-500/10 border border-orange-500/20 rounded-full px-3 py-1">
              <WifiOff className="w-3 h-3" /> Faucet server offline — use deployer method below
            </span>
          )}
        </div>

        {/* ── Hero card: API faucet (any user) */}
        {faucetStatus !== "offline" && (
          <Card className="border-blue-500/20 bg-blue-500/[0.03]">
            <div className="flex items-center gap-3 mb-5">
              <div className="w-10 h-10 rounded-xl bg-orange-500/15 border border-orange-500/25 flex items-center justify-center">
                <Bitcoin className="w-5 h-5 text-orange-400" />
              </div>
              <div>
                <p className="text-sm font-semibold text-white">Request Test wBTC</p>
                <p className="text-xs text-white/40">
                  Any wallet · up to 5 wBTC · once per 24 h
                </p>
              </div>
            </div>

            {/* Amount presets */}
            <label className="text-xs text-white/40 uppercase tracking-wider block mb-2">Amount</label>
            <div className="grid grid-cols-4 gap-2 mb-2">
              {AMOUNT_PRESETS.map((p, i) => (
                <button
                  key={p.satoshi}
                  onClick={() => { setSelectedIdx(i); setCustomBtc(""); }}
                  className={`py-2.5 rounded-xl text-sm font-semibold border transition-all ${
                    selectedIdx === i && !customBtc
                      ? "bg-orange-500/20 border-orange-500/50 text-orange-300"
                      : "bg-white/5 border-white/8 text-white/50 hover:bg-white/8 hover:text-white/70"
                  }`}
                >
                  {p.label}
                </button>
              ))}
            </div>
            <div className="relative mb-5">
              <input
                type="number"
                value={customBtc}
                onChange={e => { setCustomBtc(e.target.value); setSelectedIdx(-1); }}
                placeholder="Custom amount…"
                className="w-full bg-white/5 border border-white/10 rounded-xl px-4 py-2.5 text-sm text-white font-mono placeholder:text-white/20 focus:outline-none focus:border-orange-500/40"
              />
              <span className="absolute right-3 top-1/2 -translate-y-1/2 text-xs text-orange-400 font-semibold">wBTC</span>
            </div>

            {/* Recipient */}
            <label className="text-xs text-white/40 uppercase tracking-wider block mb-2">Recipient</label>
            <div className="flex gap-2 mb-5">
              <input
                value={recipient}
                onChange={e => setRecipient(e.target.value)}
                placeholder="0x… your Starknet address"
                className="flex-1 bg-white/5 border border-white/10 rounded-xl px-4 py-2.5 text-sm text-white font-mono placeholder:text-white/20 focus:outline-none focus:border-orange-500/40"
              />
              {address && recipient !== address && (
                <button
                  onClick={() => setRecipient(address)}
                  className="shrink-0 flex items-center gap-1.5 text-xs bg-white/5 hover:bg-white/10 border border-white/10 rounded-xl px-3 py-2 text-white/50 transition-colors"
                >
                  <Wallet className="w-3.5 h-3.5" /> Me
                </button>
              )}
            </div>

            {/* CTA */}
            {!isConnected ? (
              <div className="w-full flex items-center justify-center gap-2 py-3 rounded-xl bg-white/4 border border-white/8 text-white/30 text-sm">
                <Wallet className="w-4 h-4" /> Connect wallet to auto-fill address
              </div>
            ) : (
              <Button
                onClick={handleApiMint}
                disabled={apiPending || !recipientAddr || faucetStatus === "checking"}
                loading={apiPending}
                className="w-full"
                size="lg"
              >
                <Rocket className="w-4 h-4" />
                {apiPending
                  ? "Waiting for confirmation…"
                  : `Get ${btcDisplay} wBTC`}
              </Button>
            )}

            {/* API result states */}
            {apiPending && (
              <p className="mt-3 text-xs text-orange-400/70 text-center animate-pulse">
                Transaction submitted — waiting for Starknet confirmation (~15 s)
              </p>
            )}

            {apiResult && (
              <motion.div
                initial={{ opacity: 0, y: 6 }}
                animate={{ opacity: 1, y: 0 }}
                className="mt-4 p-4 rounded-xl bg-emerald-500/10 border border-emerald-500/20"
              >
                <div className="flex items-start gap-2 mb-2">
                  <CheckCircle2 className="w-4 h-4 text-emerald-400 shrink-0 mt-0.5" />
                  <div>
                    <p className="text-sm font-semibold text-emerald-300">
                      {apiResult.amount_btc.toFixed(4)} wBTC sent to your wallet!
                    </p>
                    <p className="text-xs text-emerald-400/60 mt-0.5">
                      Oracle price updated + router cache synced + wBTC minted.
                    </p>
                  </div>
                </div>
                <a
                  href={`${STARKSCAN}/tx/${apiResult.tx_hash}`}
                  target="_blank"
                  rel="noreferrer"
                  className="flex items-center gap-1.5 text-xs text-blue-400 hover:text-blue-300 mt-1"
                >
                  <ExternalLink className="w-3 h-3" />
                  View transaction on Voyager
                </a>
                <div className="mt-3 pt-3 border-t border-emerald-500/15 flex gap-2">
                  <a href="/vault" className="flex-1 text-center text-xs py-1.5 rounded-lg bg-orange-500/15 hover:bg-orange-500/20 border border-orange-500/20 text-orange-300 transition-colors">
                    → Deposit in Vault
                  </a>
                  <a href="/portfolio" className="flex-1 text-center text-xs py-1.5 rounded-lg bg-white/5 hover:bg-white/8 border border-white/8 text-white/50 transition-colors">
                    → View Portfolio
                  </a>
                </div>
              </motion.div>
            )}

            {rateLimitMsg && (
              <motion.div
                initial={{ opacity: 0, y: 6 }}
                animate={{ opacity: 1, y: 0 }}
                className="mt-3 flex items-center gap-2 p-3 rounded-xl bg-orange-500/10 border border-orange-500/20 text-sm text-orange-300"
              >
                <Clock className="w-4 h-4 shrink-0" />
                {rateLimitMsg}
              </motion.div>
            )}

            {apiError && (
              <motion.div
                initial={{ opacity: 0, y: 6 }}
                animate={{ opacity: 1, y: 0 }}
                className="mt-3 flex items-start gap-2 p-3 rounded-xl bg-red-500/10 border border-red-500/20 text-sm text-red-300"
              >
                <XCircle className="w-4 h-4 shrink-0 mt-0.5" />
                <span>{apiError}</span>
              </motion.div>
            )}
          </Card>
        )}

        {/* ── Offline fallback notice */}
        {faucetStatus === "offline" && (
          <Card className="border-orange-500/25 bg-orange-500/[0.04]">
            <div className="flex gap-3">
              <WifiOff className="w-5 h-5 text-orange-400 shrink-0 mt-0.5" />
              <div className="space-y-1.5 text-sm">
                <p className="text-orange-300 font-semibold">Faucet server not running</p>
                <p className="text-white/50 text-xs">
                  The faucet API at <code className="bg-white/5 px-1 rounded">{FAUCET_API}</code> is
                  unreachable. The deployer can start it with:
                </p>
                <div className="bg-black/40 rounded-lg px-3 py-2 text-xs font-mono text-emerald-400">
                  cd agents &amp;&amp; uvicorn faucet_server:app --port 8400
                </div>
                <p className="text-white/40 text-xs">
                  Ask the project admin to start the faucet server.
                </p>
              </div>
            </div>
          </Card>
        )}

        {/* ── How it works */}
        <Card>
          <CardTitle className="mb-3 flex items-center gap-2">
            <Info className="w-3.5 h-3.5" /> How This Faucet Works
          </CardTitle>
          <div className="space-y-3 text-xs text-white/50">
            <div className="flex gap-3">
              <span className="w-6 h-6 shrink-0 rounded-lg bg-orange-500/15 border border-orange-500/20 flex items-center justify-center text-orange-400 font-bold text-[10px]">1</span>
              <div>
                <p className="text-white/70 font-medium">Connect your Starknet wallet</p>
                <p>Argent X or Braavos. Your address is auto-filled as recipient.</p>
              </div>
            </div>
            <div className="flex gap-3">
              <span className="w-6 h-6 shrink-0 rounded-lg bg-blue-500/15 border border-blue-500/20 flex items-center justify-center text-blue-400 font-bold text-[10px]">2</span>
              <div>
                <p className="text-white/70 font-medium">Click "Get wBTC"</p>
                <p>The faucet server (deployer-run) mints test wBTC directly to your address on Sepolia. Oracle price is sourced from live Pragma (read-only on testnet).</p>
              </div>
            </div>
            <div className="flex gap-3">
              <span className="w-6 h-6 shrink-0 rounded-lg bg-emerald-500/15 border border-emerald-500/20 flex items-center justify-center text-emerald-400 font-bold text-[10px]">3</span>
              <div>
                <p className="text-white/70 font-medium">Deposit in the Vault</p>
                <p>Head to the Vault page and deposit your wBTC to start earning yield. Leverage is available too.</p>
              </div>
            </div>
          </div>
        </Card>

        {/* ── Contract addresses */}
        <Card>
          <CardTitle className="mb-3">Deployed Contracts (Sepolia)</CardTitle>
          <div className="space-y-2 text-sm">
            {[
              { label: "BTCSecurityRouter", addr: CONTRACTS.BTCSecurityRouter },
              { label: "BTCVault",          addr: CONTRACTS.BTCVault },
              { label: "MockWBTC",          addr: CONTRACTS.MockWBTC },
              { label: "YBTCToken",         addr: CONTRACTS.YBTCToken },
            ].map(({ label, addr }) => (
              <div key={addr} className="flex items-center justify-between">
                <span className="text-white/50">{label}</span>
                <div className="flex items-center gap-2">
                  <code className="text-white/40 font-mono text-xs">{shortAddress(addr)}</code>
                  <CopyButton text={addr} />
                  <a href={`${STARKSCAN}/contract/${addr}`} target="_blank" rel="noreferrer" className="text-blue-400 hover:text-blue-300">
                    <ExternalLink className="w-3.5 h-3.5" />
                  </a>
                </div>
              </div>
            ))}
          </div>
        </Card>

      </div>
    </AppLayout>
  );
}

