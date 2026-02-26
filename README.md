# Vaultaze — Autonomous BTC Yield & Security Infrastructure on Starknet

<p align="center">
  <img src="https://img.shields.io/badge/Network-Starknet%20Sepolia-8b5cf6?style=flat-square" />
  <img src="https://img.shields.io/badge/Language-Cairo%201.0-orange?style=flat-square" />
  <img src="https://img.shields.io/badge/Frontend-Next.js%2016-black?style=flat-square" />
  <img src="https://img.shields.io/badge/Status-Testnet%20Live-22c55e?style=flat-square" />
</p>

> **Vaultaze** is a shared onchain Bitcoin yield and security infrastructure built on Starknet. It ingests wrapped BTC, generates yield by borrowing stablecoins and deploying them into DeFi strategies, tokenizes yield-bearing positions as **yBTC**, and enforces system-wide safety through an autonomous **BTC Security Router** — protecting every user and every vault simultaneously.

---

## 🛡️ Security Infrastructure — Not Just a Vault

Vaultaze goes beyond a single yield product. The **BTC Security Router** is designed as **shared, composable security infrastructure** for all BTC DeFi on Starknet:

- **Single source of truth** for system-wide Bitcoin health — any protocol can query it
- **Execution gating** — no operation (deposit, leverage, borrow) executes unless the router approves
- **Safe Mode** — automatically triggered when the global health factor drops below 110%, halting new risky activity system-wide
- **Autonomous enforcement** — three offchain agents (Risk Sentinel, Strategy Rebalancer, User Guardian) continuously monitor and call the router, requiring zero manual intervention
- **No custody** — the router never holds funds; it only defines and enforces rules

> The BTC Security Router is to Bitcoin safety what Chainlink is to price data — infrastructure that every BTC protocol on Starknet can plug into.

---

## Architecture

```
┌─────────────────────────────────────────┐
│     Bitcoin World (Price, Reserves)     │
└──────────────┬──────────────────────────┘
               │ Monitoring (24/7)
               ▼
┌─────────────────────────────────────────┐
│      Autonomous Agents (Offchain)       │
│   ├─ Risk Sentinel                      │
│   ├─ Strategy Rebalancer                │
│   └─ User Guardian                      │
└──────────────┬──────────────────────────┘
               │ Calls public contract functions
               ▼
┌─────────────────────────────────────────┐
│   BTC Security Router (Starknet Core)   │  ← Shared Security Infrastructure
│   ├─ Global BTC Health Factor           │
│   ├─ Dynamic Leverage & LTV Caps        │
│   └─ Execution Gating / Safe Mode       │
└──────────────┬──────────────────────────┘
               │ Governs
               ▼
┌─────────────────────────────────────────┐
│  Vaultaze — BTC Vault + Strategies      │
│   ├─ Deposit wBTC → mint yBTC           │
│   ├─ Borrow stables, deploy to DeFi     │
│   ├─ Leverage looping                   │
│   └─ Yield distribution via share price │
└─────────────────────────────────────────┘
```

**Core design principle**: Agents propose. The router validates. The router decides. Agents hold zero special onchain permissions.

---

## Smart Contracts

All contracts written in **Cairo 1.0**, deployed to Starknet.

### BTC Security Router (`vault/src/router.cairo`)
The shared security primitive. Tracks `btc_backing` vs `btc_exposure`, computes the global health factor, enforces dynamic leverage and LTV caps, and gates every vault operation.

Key functions: `get_btc_health()` · `get_max_leverage()` · `get_max_ltv()` · `is_operation_allowed()` · `report_exposure()` · `enter_safe_mode()` · `exit_safe_mode()`

### BTC Vault (`vault/src/vault.cairo`)
User-facing vault. Handles deposits, withdrawals, leverage, strategy deployment, and yield accounting. Every write function queries the router before execution.

Key functions: `deposit()` · `withdraw()` · `apply_leverage()` · `deleverage()` · `deploy_to_strategy()` · `get_share_price()` · `get_user_position()`

### yBTC Token (`vault/src/ybtc_token.cairo`)
Full ERC20 vault share token. Mint/burn is restricted to the vault. Freely transferable and composable.

### Mock Strategy (`vault/src/mock_strategy.cairo`)
Simulated yield strategy with time-based APY accrual and capacity limits. Demonstrates the strategy interface on testnet.

### Mock Pragma Oracle (`vault/src/mock_pragma_oracle.cairo`)
Simulates BTC/USD price feeds for testnet. Replaced by live [Pragma Oracle](https://www.pragmaoracle.com/) feeds on mainnet.

---

## Token Economics

```
Bitcoin L1                    Starknet
    │
    │  Bridge (lock BTC)
    ▼
┌─────────┐               ┌─────────┐
│   BTC   │ ───────────▶  │  wBTC   │  (1:1 bridged ERC20)
│ (native)│               └────┬────┘
└─────────┘                    │  Deposit to Vaultaze
                               ▼
                          ┌─────────┐
                          │  yBTC   │  (yield-bearing share token)
                          └─────────┘
```

| Token | Layer | Type | Description |
|---|---|---|---|
| **BTC** | Bitcoin L1 | Native | Real Bitcoin, must be bridged first |
| **wBTC** | Starknet | ERC20 | 1:1 bridged BTC, usable in Starknet DeFi |
| **yBTC** | Starknet | ERC20 Share | Vault ownership token — price rises as yield accrues |

The share price is monotonically increasing as long as the vault generates positive net yield. Depositors never need to claim or compound — appreciation is automatic.

---

## Yield Strategy Flow

BTC generates no native yield. Vaultaze solves this:

```
1. User deposits wBTC
        │
        ▼
2. Vault uses wBTC as collateral
        │
        ▼
3. Vault borrows stablecoins (USDC / USDT)
        │
        ▼
4. Stablecoins deployed to:
   ├─ Lending protocols  (supply liquidity, earn interest)
   ├─ Liquidity pools    (earn swap fees)
   └─ Fixed-rate vaults  (predictable APY)
        │
        ▼
5. Yield earned − borrow cost = Net profit
        │
        ▼
6. Net profit reflected in rising yBTC share price
```

Estimated APY: **5–15%** depending on strategy allocation and DeFi market conditions.

---

## Leverage Looping

$$\text{Leverage Ratio} = \frac{\text{Total Position Value}}{\text{Equity (Collateral)}}$$

**Single loop example (1.5x):**
```
Deposit:   1 wBTC  ($100k)
Borrow:    $50k USDC  (50% LTV)
Buy:       0.5 wBTC with stablecoins
Exposure:  1.5 wBTC total
```

**Dynamic safety caps enforced by the router:**

| BTC Volatility | Max Leverage Allowed |
|---|---|
| < 50% | 2.0x |
| 60% | 1.4x |
| 90% | 1.2x |
| ≥ 120% | 1.0x (leverage disabled) |

When the system enters **Safe Mode** (health factor < 110%), new leverage applications are blocked onchain — regardless of what the frontend says.

---

## Autonomous Agents

Three Python agents run offchain and continuously enforce safety by calling public contract functions.

### Risk Sentinel
Monitors BTC price, 24h volatility, and bridge reserves.

| Trigger | Threshold | Onchain Action |
|---|---|---|
| Price drop | > 10% in 1 hour | `enter_safe_mode()` |
| Volatility spike | > 80% annualized | `reduce_max_leverage()` |
| Bridge reserves low | < 105% backing | Safe mode + alert |

### Strategy Rebalancer
Monitors per-strategy APY and reallocates capital to maximise net yield within risk limits set by the router.

### User Guardian
Monitors individual position health factors and auto-deleverages positions approaching liquidation thresholds.

Agents are containerized (see `agents/Dockerfile`) and deployed to **Railway**.

---

## Risk Management

| Risk | Mitigation |
|---|---|
| **Market Risk** | Dynamic leverage caps, Safe Mode, 95% VaR monitoring |
| **Liquidation Risk** | Router health checks before every operation, User Guardian agent |
| **Smart Contract Risk** | Cairo 1.0 contracts, pausable vault, Scarb test suite |
| **Oracle Risk** | Pragma Oracle feeds with staleness and deviation checks |
| **Bridge Risk** | Reserve ratio monitoring, safe mode trigger on low backing |

**Global BTC Health Factor signal:**

- $H \geq 1.5$ → 🟢 **Healthy** — all operations permitted
- $1.1 \leq H < 1.5$ → 🟡 **Caution** — leverage caps tightened
- $H < 1.1$ → 🔴 **Safe Mode** — new leverage and deposits blocked

---

## Frontend

**Next.js 16** app connecting to Starknet Sepolia via `@starknet-react/core`.

| Route | Description |
|---|---|
| `/` | Dashboard — system health, BTC price, TVL |
| `/vault` | Deposit wBTC / withdraw to yBTC |
| `/leverage` | Apply or remove leverage on BTC positions |
| `/portfolio` | Personal positions, P&L, share price history |
| `/analytics` | System-wide metrics and health factor chart |
| `/faucet` | Testnet wBTC faucet |

**Stack:** Next.js 16 · React 19 · TypeScript · Tailwind CSS v4 · `@starknet-react/core` v3 · `starknet.js` v6 · Recharts · Framer Motion · Zustand

---

## Deployed Contracts — Starknet Sepolia

> Deployed: February 24, 2026

| Contract | Address |
|---|---|
| **BTCVault** ⭐ | [`0x0047970c...`](https://sepolia.starkscan.co/contract/0x0047970cfbf8de94f268f2416c9e5cbaef520dae7b5eae0fd6476a41b7266f08) |
| **BTCSecurityRouter** | [`0x014c306f...`](https://sepolia.starkscan.co/contract/0x014c306f04fd602c1a06f61367de622af2558972c7eead39600b5d99fd1e2639) |
| **yBTC Token** | [`0x04ea131f...`](https://sepolia.starkscan.co/contract/0x04ea131f51c071ce677482a4eeb1f9ac31e9188b2a92de13cb7043f9f21c8166) |
| **Mock wBTC** | [`0x0129f01b...`](https://sepolia.starkscan.co/contract/0x0129f01b63b9eb403e07c9da8e69e2bed648a5fbc81fddb0b27768ee323bf446) |
| **MockPragmaOracle** | [`0x06d1c9aa...`](https://sepolia.starkscan.co/contract/0x06d1c9aa3cb65003c51a4b360c8ac3a23a9724530246031ba92ff0b2461f7e74) |

---

## Repository Structure

```
vaultaze/
├── vault/                  # Cairo smart contracts (Scarb)
│   ├── src/
│   │   ├── router.cairo          # BTC Security Router
│   │   ├── vault.cairo           # BTC Vault (main contract)
│   │   ├── ybtc_token.cairo      # yBTC ERC20 share token
│   │   ├── mock_strategy.cairo   # Mock yield strategy
│   │   ├── mock_pragma_oracle.cairo
│   │   └── interfaces.cairo      # Shared interfaces
│   ├── tests/
│   ├── Scarb.toml
│   └── deployments.txt           # Live Sepolia contract addresses
│
├── frontend/               # Next.js 16 web application
│   ├── src/
│   │   ├── app/                  # App router pages
│   │   │   ├── page.tsx          # Dashboard
│   │   │   ├── vault/
│   │   │   ├── leverage/
│   │   │   ├── portfolio/
│   │   │   ├── analytics/
│   │   │   └── faucet/
│   │   ├── components/           # UI components
│   │   ├── lib/
│   │   │   ├── contracts/        # ABIs & contract addresses
│   │   │   ├── hooks/            # React hooks (reads/writes)
│   │   │   └── utils/            # Formatting utilities
│   │   └── providers/            # Starknet wallet provider
│   ├── vercel.json
│   └── package.json
│
└── agents/                 # Python autonomous agents
    ├── agents/
    │   ├── risk_sentinel.py
    │   ├── strategy_rebalancer.py
    │   └── user_guardian.py
    ├── core/
    │   ├── starknet_client.py
    │   ├── price_feed.py
    │   └── event_indexer.py
    ├── Dockerfile
    └── requirements.txt
```

---

## Local Development

### Prerequisites
- Node.js 20+
- Python 3.11+
- [Scarb](https://docs.swmansion.com/scarb/) (Cairo package manager)
- [Argent X](https://www.argent.xyz/) or [Braavos](https://braavos.app/) wallet (Sepolia)

### Frontend

```bash
cd frontend
npm install
npm run dev
```

Opens at [http://localhost:3000](http://localhost:3000). Connects to Starknet Sepolia by default — no environment variables required.

### Agents

```bash
cd agents
pip install -r requirements.txt
python main.py
```

### Smart Contracts

```bash
cd vault
scarb build
scarb test
```

---

## Deploying the Frontend to Vercel

### Option 1 — Vercel CLI

```bash
npm i -g vercel
cd frontend
vercel --prod
```

### Option 2 — GitHub Integration

1. Push this repo to GitHub
2. Go to [vercel.com/new](https://vercel.com/new) and import the repo
3. Set **Root Directory** → `frontend`
4. Framework auto-detected as **Next.js**
5. Click **Deploy** — no environment variables needed

> All contract addresses and ABIs are bundled at build time from `src/lib/contracts/`. The app is fully static and requires no backend or secrets.

---

## License

MIT
