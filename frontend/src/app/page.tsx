"use client";

import { useAccount, useConnect } from "@starknet-react/core";
import { useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { motion, AnimatePresence } from "framer-motion";
import {
  Bitcoin,
  Shield,
  Zap,
  TrendingUp,
  ArrowRight,
  Wallet,
  Menu,
  X,
  ChevronRight,
  Lock,
  Activity,
  Layers,
  ExternalLink,
} from "lucide-react";

const fadeUp = (delay = 0) => ({
  initial: { opacity: 0, y: 28 },
  animate: { opacity: 1, y: 0 },
  transition: { duration: 0.55, delay, ease: [0.22, 1, 0.36, 1] },
});

const fadeIn = (delay = 0) => ({
  initial: { opacity: 0 },
  animate: { opacity: 1 },
  transition: { duration: 0.6, delay },
});

const NAV = [
  { label: "Features",     href: "#features" },
  { label: "How It Works", href: "#how-it-works" },
  { label: "Security",     href: "#security" },
];

const STATS = [
  { value: "12–18%",  label: "Target APY" },
  { value: "5×",      label: "Max Leverage" },
  { value: "< 1 sec", label: "Starknet Finality" },
  { value: "24 / 7",  label: "AI Risk Guards" },
];

const PARTNERS = ["Starknet", "Cairo", "Pragma Oracle", "Argent", "Braavos"];

const FEATURES = [
  {
    icon: Shield,
    color: "orange",
    tag: "SECURITY ROUTER",
    title: "Autonomous Risk Guards",
    desc: "The on-chain BTC Security Router monitors health factors in real time and auto-disables deposits or leverage before a cascade.",
  },
  {
    icon: Zap,
    color: "yellow",
    tag: "LEVERAGE ENGINE",
    title: "Up to 5× BTC Leverage",
    desc: "Amplify your BTC exposure with router-gated leverage. Positions are liquidated automatically when health drops below threshold.",
  },
  {
    icon: TrendingUp,
    color: "green",
    tag: "YIELD VAULT",
    title: "yBTC Yield-Bearing Shares",
    desc: "Deposit wBTC, receive yBTC shares. Yield accrues continuously to the share price — withdraw anytime for principal + earnings.",
  },
];

const STEPS = [
  { step: "01", title: "Bridge BTC",    desc: "Send BTC to Starknet via a bridge and receive wBTC 1:1." },
  { step: "02", title: "Deposit wBTC",  desc: "Deposit into the vault to receive yBTC yield-bearing shares." },
  { step: "03", title: "Earn Yield",    desc: "The vault deploys capital to DeFi strategies — yield accrues to share price." },
  { step: "04", title: "Withdraw Free", desc: "Burn yBTC anytime to redeem proportional wBTC principal + yield." },
];

export default function LandingPage() {
  const { isConnected } = useAccount();
  const { connect, connectAsync, connectors } = useConnect();
  const router = useRouter();

  const [walletOpen, setWalletOpen] = useState(false);
  const [mobileOpen, setMobileOpen] = useState(false);
  const walletRef = useRef<HTMLDivElement>(null);
  const heroWalletRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (isConnected) router.push("/dashboard");
  }, [isConnected, router]);

  useEffect(() => {
    function h(e: MouseEvent) {
      if (
        walletRef.current && !walletRef.current.contains(e.target as Node) &&
        heroWalletRef.current && !heroWalletRef.current.contains(e.target as Node)
      ) setWalletOpen(false);
    }
    if (walletOpen) document.addEventListener("mousedown", h);
    return () => document.removeEventListener("mousedown", h);
  }, [walletOpen]);

  return (
    <div className="min-h-screen bg-[#060810] text-white overflow-x-hidden">

      {/* ── NAVBAR ── */}
      <header className="fixed top-0 inset-x-0 z-50 border-b border-white/[0.06] bg-[#060810]/80 backdrop-blur-xl">
        <div className="max-w-7xl mx-auto px-6 h-16 flex items-center justify-between gap-8">
          <div className="flex items-center shrink-0">
            <span className="font-bold text-xl tracking-tight text-white">Vaultaze</span>
          </div>

          <nav className="hidden md:flex items-center gap-8">
            {NAV.map(({ label, href }) => (
              <a key={label} href={href} className="text-sm text-white/50 hover:text-white transition-colors tracking-wide uppercase">
                {label}
              </a>
            ))}
          </nav>

          <div className="flex items-center gap-3">
            <div className="relative hidden md:block" ref={walletRef}>
              <button
                onClick={() => setWalletOpen(!walletOpen)}
                className="flex items-center gap-2 bg-orange-500 hover:bg-orange-400 text-white text-sm font-semibold rounded-xl px-5 py-2.5 transition-all shadow-lg shadow-orange-500/25"
              >
                <Wallet className="w-4 h-4" />
                Connect Wallet
              </button>
              <AnimatePresence>
                {walletOpen && (
                  <motion.div
                    initial={{ opacity: 0, y: 6, scale: 0.96 }}
                    animate={{ opacity: 1, y: 0, scale: 1 }}
                    exit={{ opacity: 0, y: 6, scale: 0.96 }}
                    transition={{ duration: 0.15 }}
                    className="absolute right-0 mt-2 w-52 bg-[#0d0f17] border border-white/10 rounded-xl shadow-xl z-50 overflow-hidden"
                  >
                    <div className="p-3 border-b border-white/8">
                      <p className="text-xs text-white/50 uppercase tracking-wider">Choose Wallet</p>
                    </div>
                    {connectors.map((c) => (
                      <button
                        key={c.id}
                        onClick={() => { connectAsync({ connector: c }).catch(() => {}); setWalletOpen(false); }}
                        className="w-full flex items-center gap-3 px-4 py-3 text-sm text-white hover:bg-white/5 transition-colors"
                      >
                        <Wallet className="w-4 h-4 text-orange-400" />
                        {c.name}
                      </button>
                    ))}
                  </motion.div>
                )}
              </AnimatePresence>
            </div>
            <button
              className="md:hidden p-2 rounded-lg text-white/60 hover:bg-white/8 transition-colors"
              onClick={() => setMobileOpen(!mobileOpen)}
            >
              {mobileOpen ? <X className="w-5 h-5" /> : <Menu className="w-5 h-5" />}
            </button>
          </div>
        </div>
      </header>

      {/* Mobile menu */}
      <AnimatePresence>
        {mobileOpen && (
          <motion.div
            initial={{ opacity: 0, y: -10 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0, y: -10 }}
            className="fixed inset-0 top-16 z-40 bg-[#060810]/98 p-6 md:hidden flex flex-col gap-6"
          >
            <nav className="space-y-1">
              {NAV.map(({ label, href }) => (
                <a key={label} href={href} onClick={() => setMobileOpen(false)}
                  className="block px-4 py-3 rounded-xl text-white/70 hover:text-white hover:bg-white/5 transition-all text-base font-medium">
                  {label}
                </a>
              ))}
            </nav>
            <div className="pt-4 border-t border-white/8 space-y-2">
              {connectors.map((c) => (
                <button key={c.id} onClick={() => { connectAsync({ connector: c }).catch(() => {}); setMobileOpen(false); }}
                  className="w-full flex items-center justify-center gap-2 bg-orange-500 hover:bg-orange-400 text-white font-semibold rounded-xl px-5 py-3 transition-all">
                  <Wallet className="w-4 h-4" />
                  Connect with {c.name}
                </button>
              ))}
            </div>
          </motion.div>
        )}
      </AnimatePresence>

      {/* ── HERO ── */}
      <section className="relative min-h-screen flex items-center pt-16 overflow-hidden">
        <div className="pointer-events-none absolute inset-0">
          <div className="absolute top-1/4 right-1/3 w-[600px] h-[600px] bg-orange-500/[0.04] rounded-full blur-[120px]" />
          <div className="absolute bottom-1/4 left-1/4 w-[400px] h-[400px] bg-orange-500/[0.03] rounded-full blur-[100px]" />
        </div>

        <div className="relative max-w-7xl mx-auto px-6 w-full grid grid-cols-1 lg:grid-cols-2 gap-12 lg:gap-0 items-center py-20">
          {/* Left: Text */}
          <div className="flex flex-col gap-8 lg:pr-16">
            <motion.div {...fadeUp(0.1)}>
              <span className="inline-flex items-center gap-2 text-xs font-medium text-orange-400 bg-orange-500/10 border border-orange-500/20 rounded-full px-3.5 py-1.5 tracking-wide">
                <span className="w-1.5 h-1.5 rounded-full bg-orange-400 animate-pulse" />
                Built on Starknet · Powered by Autonomous AI
              </span>
            </motion.div>

            <motion.div {...fadeUp(0.15)}>
              <h1 className="text-[clamp(2.6rem,6vw,4.5rem)] font-extrabold leading-[1.06] tracking-tight">
                <span className="text-white">Earn Bitcoin</span>
                <br />
                <span className="text-white">Yield, Secured</span>
                <br />
                <span className="animate-gradient">
                  by Autonomy.
                </span>
              </h1>
            </motion.div>

            <motion.p {...fadeUp(0.2)} className="text-white/45 text-base leading-relaxed max-w-md">
              Vaultaze is a non-custodial Bitcoin yield vault on Starknet. Deposit wBTC,
              receive yBTC yield-bearing shares, and let the autonomous Security Router
              protect your capital 24/7.
            </motion.p>

            <motion.div {...fadeUp(0.25)} className="flex items-center gap-4 flex-wrap">
              <div className="relative" ref={heroWalletRef}>
                <button
                  onClick={() => setWalletOpen(!walletOpen)}
                  className="flex items-center gap-2 bg-orange-500 hover:bg-orange-400 text-white font-semibold rounded-xl px-7 py-3.5 text-base transition-all shadow-xl shadow-orange-500/25"
                >
                  <Wallet className="w-5 h-5" />
                  Get Started
                  <ChevronRight className="w-4 h-4" />
                </button>
              </div>
              <a href="#how-it-works"
                className="flex items-center gap-2 border border-white/15 hover:border-white/30 text-white/70 hover:text-white rounded-xl px-7 py-3.5 text-base font-medium transition-all">
                How It Works <ArrowRight className="w-4 h-4" />
              </a>
            </motion.div>

            <motion.div {...fadeUp(0.3)} className="flex items-center gap-8 pt-2 flex-wrap">
              {STATS.slice(0, 3).map(({ value, label }) => (
                <div key={label} className="flex flex-col">
                  <span className="text-2xl font-bold text-white">{value}</span>
                  <span className="text-xs text-white/35 mt-0.5">{label}</span>
                </div>
              ))}
            </motion.div>
          </div>

          {/* Right: Decorative */}
          <div className="relative flex items-center justify-center lg:justify-end h-[420px] lg:h-[520px]">
            {/* Outer glow rings */}
            <motion.div {...fadeIn(0.2)}
              className="absolute inset-0 flex items-center justify-center pointer-events-none">
              <div className="w-[300px] h-[300px] lg:w-[400px] lg:h-[400px] rounded-full border border-orange-500/12" />
            </motion.div>
            <motion.div {...fadeIn(0.25)}
              className="absolute inset-0 flex items-center justify-center pointer-events-none">
              <div className="w-[220px] h-[220px] lg:w-[300px] lg:h-[300px] rounded-full border border-orange-500/8" />
            </motion.div>

            {/* Dot grid backdrop */}
            <motion.div {...fadeIn(0.25)}
              className="absolute inset-0 flex items-center justify-center pointer-events-none">
              <div className="w-[220px] h-[220px] lg:w-[300px] lg:h-[300px]"
                style={{ backgroundImage: "radial-gradient(circle, rgba(251,146,60,0.18) 1px, transparent 1px)", backgroundSize: "18px 18px" }} />
            </motion.div>

            {/* Small accent circle top-right */}
            <motion.div
              initial={{ opacity: 0, scale: 0 }}
              animate={{ opacity: 1, scale: 1 }}
              transition={{ delay: 0.5, duration: 0.4 }}
              className="absolute right-6 top-10 w-9 h-9 rounded-full bg-orange-500/20 border border-orange-500/25 animate-float-tiny"
            />

            {/* Large Bitcoin icon – hero decoration, centered inside rings */}
            <motion.div
              initial={{ opacity: 0, scale: 0.75 }}
              animate={{ opacity: 1, scale: 1 }}
              transition={{ duration: 0.7, delay: 0.3, ease: [0.22, 1, 0.36, 1] }}
              className="absolute inset-0 z-10 flex items-center justify-center"
            >
              <div className="relative flex items-center justify-center animate-float">
                <div className="absolute w-[180px] h-[180px] lg:w-[240px] lg:h-[240px] bg-[#F7931A]/10 rounded-full blur-3xl" />
                <Bitcoin
                  className="relative w-32 h-32 lg:w-44 lg:h-44"
                  strokeWidth={1.75}
                  style={{
                    color: "#F7931A",
                    filter: "drop-shadow(0 0 24px rgba(247,147,26,0.55))",
                  }}
                />
              </div>
            </motion.div>

            {/* Callout card – overlapping just the bottom-left corner of the Bitcoin icon */}
            <motion.div
              initial={{ opacity: 0, x: -16, y: 16 }}
              animate={{ opacity: 1, x: 0, y: 0 }}
              transition={{ duration: 0.5, delay: 0.55 }}
              className="absolute bottom-[15%] left-4 z-30"
            >
              <div className="w-44 bg-[#0d0f17]/90 border border-white/10 rounded-2xl p-4 backdrop-blur-md animate-float-slow">
                <p className="text-[9px] font-bold text-white/30 uppercase tracking-widest mb-1">SECURITY ROUTER</p>
                <p className="text-xs font-medium text-white/50 mb-2">Auto-Rebalancing</p>
                <p className="text-xl font-bold text-white mb-0.5">12–18%</p>
                <p className="text-[10px] text-white/30 mb-3">Target APY</p>
                <a href="#features"
                  className="flex items-center gap-1 text-xs font-semibold text-orange-400 hover:text-orange-300 transition-colors">
                  Explore <ArrowRight className="w-3 h-3" />
                </a>
              </div>
            </motion.div>

          </div>
        </div>

        {/* Scroll hint */}
        <motion.div {...fadeIn(0.8)} className="absolute bottom-8 left-1/2 -translate-x-1/2 flex flex-col items-center gap-2">
          <span className="text-[10px] text-white/20 uppercase tracking-[0.2em]">Scroll</span>
          <div className="w-px h-12 bg-gradient-to-b from-white/20 to-transparent" />
        </motion.div>
      </section>

      {/* ── PARTNERS STRIP ── */}
      <section className="border-y border-white/[0.06] bg-white/[0.015] py-10">
        <div className="max-w-7xl mx-auto px-6">
          <p className="text-center text-[10px] font-bold text-white/25 uppercase tracking-[0.3em] mb-8">Collaborators</p>
          <div className="flex items-center justify-center gap-12 flex-wrap">
            {PARTNERS.map((name, i) => (
              <motion.span
                key={name}
                initial={{ opacity: 0, y: 10 }}
                whileInView={{ opacity: 1, y: 0 }}
                viewport={{ once: true }}
                transition={{ duration: 0.4, delay: i * 0.07 }}
                className="text-sm font-semibold text-white/25 hover:text-white/60 transition-colors tracking-wide uppercase cursor-default"
              >
                {name}
              </motion.span>
            ))}
          </div>
        </div>
      </section>

      {/* ── FEATURES ── */}
      <section id="features" className="py-28">
        <div className="max-w-7xl mx-auto px-6">
          <motion.div
            initial={{ opacity: 0, y: 20 }} whileInView={{ opacity: 1, y: 0 }} viewport={{ once: true }}
            transition={{ duration: 0.5 }} className="text-center mb-16"
          >
            <p className="text-xs font-bold text-orange-400/70 uppercase tracking-[0.3em] mb-4">Features</p>
            <h2 className="text-3xl lg:text-4xl font-bold text-white">Bitcoin DeFi, done right.</h2>
          </motion.div>

          <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
            {FEATURES.map(({ icon: Icon, color, tag, title, desc }, i) => (
              <motion.div key={tag}
                initial={{ opacity: 0, y: 32 }} whileInView={{ opacity: 1, y: 0 }} viewport={{ once: true }}
                transition={{ duration: 0.5, delay: i * 0.1 }}
                whileHover={{ y: -6, transition: { duration: 0.25, ease: "easeOut" } }}
                className="relative group bg-[#0f1117] border border-white/[0.07] rounded-2xl p-8 hover:border-white/[0.13] transition-colors cursor-default"
              >
                <Icon className={`w-7 h-7 mb-6 ${
                  color === "orange" ? "text-orange-400" :
                  color === "yellow" ? "text-yellow-400" : "text-emerald-400"
                }`} />
                <p className="text-[9px] font-bold uppercase tracking-[0.25em] text-white/25 mb-2">{tag}</p>
                <h3 className="text-lg font-bold text-white mb-3">{title}</h3>
                <p className="text-sm text-white/40 leading-relaxed">{desc}</p>
                <div className="mt-6 flex items-center gap-1.5 text-xs font-semibold text-white/25 group-hover:text-orange-400 transition-colors">
                  Learn more <ArrowRight className="w-3 h-3" />
                </div>
              </motion.div>
            ))}
          </div>
        </div>
      </section>

      {/* ── HOW IT WORKS ── */}
      <section id="how-it-works" className="pt-0 pb-0 bg-white/[0.015] border-y border-white/[0.06] relative overflow-hidden">

        <div className="max-w-7xl mx-auto px-6 py-28">
          <motion.div
            initial={{ opacity: 0, y: 20 }} whileInView={{ opacity: 1, y: 0 }} viewport={{ once: true }}
            transition={{ duration: 0.5 }} className="text-center mb-16"
          >
            <p className="text-xs font-bold text-orange-400/70 uppercase tracking-[0.3em] mb-4">Process</p>
            <h2 className="text-3xl lg:text-4xl font-bold text-white">Four steps to yield.</h2>
          </motion.div>

          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-8">
            {STEPS.map(({ step, title, desc }, i) => (
              <motion.div key={step}
                initial={{ opacity: 0, y: 24 }} whileInView={{ opacity: 1, y: 0 }} viewport={{ once: true }}
                transition={{ duration: 0.45, delay: i * 0.08 }}
                className="flex flex-col gap-4"
              >
                <div className="flex items-center gap-4">
                  <span className="text-orange-400 font-bold text-sm tracking-widest">{step}</span>
                  {i < STEPS.length - 1 && (
                    <div className="hidden lg:block flex-1 h-px bg-gradient-to-r from-orange-500/15 to-transparent" />
                  )}
                </div>
                <h3 className="text-base font-bold text-white">{title}</h3>
                <p className="text-sm text-white/40 leading-relaxed">{desc}</p>
              </motion.div>
            ))}
          </div>
        </div>

        {/* Wave divider */}
        <div className="relative mt-16 w-full leading-none">
          <svg
            viewBox="0 0 1440 160"
            xmlns="http://www.w3.org/2000/svg"
            preserveAspectRatio="none"
            className="w-full block"
            style={{ height: "160px" }}
          >
            {/* Solid fill under the wave */}
            <path
              d="M0,80 C180,140 360,20 540,80 C720,140 900,20 1080,80 C1260,140 1380,60 1440,80 L1440,160 L0,160 Z"
              fill="#F7931A"
            />
            {/* Slightly lighter crest highlight */}
            <path
              d="M0,80 C180,140 360,20 540,80 C720,140 900,20 1080,80 C1260,140 1380,60 1440,80"
              fill="none"
              stroke="#fbb040"
              strokeWidth="3"
            />
          </svg>
        </div>
      </section>

      {/* ── SECURITY ── */}
      <section id="security" className="py-28">
        <div className="max-w-7xl mx-auto px-6">
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-16 items-center">
            <motion.div
              initial={{ opacity: 0, x: -24 }} whileInView={{ opacity: 1, x: 0 }} viewport={{ once: true }}
              transition={{ duration: 0.55 }} className="space-y-6"
            >
              <p className="text-xs font-bold text-orange-400/70 uppercase tracking-[0.3em]">Security</p>
              <h2 className="text-3xl lg:text-4xl font-bold text-white leading-tight">
                The BTC Security<br />Router never sleeps.
              </h2>
              <p className="text-white/45 text-base leading-relaxed max-w-md">
                Our on-chain Security Router reads Pragma Oracle price feeds every block.
                When BTC health drops below safe thresholds, it auto-pauses deposits
                and leverage — protecting your capital without human intervention.
              </p>
              <div className="space-y-3">
                {[
                  { icon: Activity, label: "Real-time health monitoring every block" },
                  { icon: Lock,     label: "Auto-pause deposits in safe mode" },
                  { icon: Layers,   label: "Multi-strategy yield diversification" },
                  { icon: Shield,   label: "Non-custodial, on-chain enforcement" },
                ].map(({ icon: Icon, label }) => (
                  <div key={label} className="flex items-center gap-3">
                    <Icon className="w-4 h-4 text-orange-400 shrink-0" />
                    <span className="text-sm text-white/60">{label}</span>
                  </div>
                ))}
              </div>
            </motion.div>

            <motion.div
              initial={{ opacity: 0, x: 24 }} whileInView={{ opacity: 1, x: 0 }} viewport={{ once: true }}
              transition={{ duration: 0.55, delay: 0.1 }}
              className="grid grid-cols-2 gap-4"
            >
              {STATS.map(({ value, label }, i) => (
                <motion.div
                  key={label}
                  initial={{ opacity: 0, y: 20 }}
                  whileInView={{ opacity: 1, y: 0 }}
                  viewport={{ once: true }}
                  transition={{ duration: 0.4, delay: i * 0.08 }}
                  className="py-6 pl-2"
                >
                  <p className="text-3xl lg:text-4xl font-bold text-white mb-1.5">{value}</p>
                  <p className="text-xs text-white/35 uppercase tracking-widest">{label}</p>
                </motion.div>
              ))}
            </motion.div>
          </div>
        </div>
      </section>

      {/* ── CTA ── */}
      <section className="py-28 border-t border-white/[0.06]">
        <div className="max-w-4xl mx-auto px-6 text-center">
          <motion.div
            initial={{ opacity: 0, y: 24 }} whileInView={{ opacity: 1, y: 0 }} viewport={{ once: true }}
            transition={{ duration: 0.55 }} className="space-y-8"
          >
            <h2 className="text-4xl lg:text-5xl font-extrabold text-white leading-tight tracking-tight">
              Your Bitcoin,<br />
              <span className="bg-gradient-to-r from-orange-400 to-amber-400 bg-clip-text text-transparent">
                working for you.
              </span>
            </h2>
            <p className="text-white/45 text-base max-w-lg mx-auto leading-relaxed">
              Connect your wallet, deposit wBTC, and start earning yield protected
              by the most advanced autonomous risk system on Starknet.
            </p>
            <div className="flex items-center justify-center gap-4 flex-wrap">
              {connectors.map((c) => (
                <motion.button
                  key={c.id}
                  onClick={() => connectAsync({ connector: c }).catch(() => {})}
                  whileHover={{ scale: 1.03, transition: { duration: 0.2 } }}
                  whileTap={{ scale: 0.97 }}
                  className="flex items-center gap-2 bg-orange-500 hover:bg-orange-400 text-white font-semibold rounded-xl px-8 py-4 text-base transition-colors shadow-2xl shadow-orange-500/25"
                >
                  <Wallet className="w-5 h-5" />
                  Connect with {c.name}
                  <ChevronRight className="w-4 h-4" />
                </motion.button>
              ))}
            </div>
          </motion.div>
        </div>
      </section>

      {/* ── FOOTER ── */}
      <footer className="border-t border-white/[0.06] py-10">
        <div className="max-w-7xl mx-auto px-6 flex flex-col sm:flex-row items-center justify-between gap-4">
          <span className="font-bold text-base text-white/60">Vaultaze</span>
          <p className="text-xs text-white/20">Built on Starknet Sepolia. Non-custodial. Open source.</p>
          <a href="https://sepolia.voyager.online" target="_blank" rel="noopener noreferrer"
            className="text-xs text-white/30 hover:text-white/60 transition-colors flex items-center gap-1">
            Voyager <ExternalLink className="w-3 h-3" />
          </a>
        </div>
      </footer>
    </div>
  );
}
