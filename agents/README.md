# BTC Vault — Autonomous Agents

Offchain Python services that continuously monitor Bitcoin risk and trigger
Starknet-enforced safety actions in real time.

> **Core principle**: Agents propose. Router validates. Router decides.
>
> Agents hold **zero special on-chain privileges** beyond the roles they need for
> their specific actions. A compromised or malfunctioning agent cannot steal funds,
> mint unbacked tokens, or override the router's safety logic.

---

## Architecture

```
┌──────────────────────────────────────────────────┐
│              Offchain World                      │
│  Binance / Coinbase / Kraken price APIs          │
│  Starknet RPC (events, view calls)               │
└──────────────┬───────────────────────────────────┘
               │
       ┌───────┴───────┐
       │  PriceFeed    │  Multi-exchange BTC/USD + rolling volatility
       └───────┬───────┘
               │
  ┌────────────┼──────────────────────────────────────────┐
  │            │          Agent Layer                     │
  │  ┌─────────▼──────────┐  ┌──────────────────────┐    │
  │  │  RiskSentinel      │  │  StrategyRebalancer  │    │
  │  │  (60 s interval)   │  │  (5 min interval)    │    │
  │  └─────────┬──────────┘  └──────────┬───────────┘    │
  │            │                        │                 │
  │  ┌─────────▼──────────────────────────────────────┐  │
  │  │             UserGuardian (30 s interval)        │  │
  │  └─────────┬──────────────────────────────────────┘  │
  └────────────┼──────────────────────────────────────────┘
               │ Public function calls
               ▼
  ┌────────────────────────────────────────┐
  │     BTCSecurityRouter (Starknet)       │
  │     BTCVault          (Starknet)       │
  └────────────────────────────────────────┘
```

---

## Agents

### 1. Risk Sentinel  `agents/risk_sentinel.py`

**Interval**: 60 seconds  
**Required roles**: `ROLE_GUARDIAN` (router), `ROLE_KEEPER` (router)

| Condition | Threshold | Action |
|-----------|-----------|--------|
| BTC price drop | > 10 % in last 1 h | `router.enter_safe_mode()` |
| 24-h annualised volatility | > 80 % | `router.enter_safe_mode()` |
| On-chain health | ≤ 115 (×100) | `router.enter_safe_mode()` |
| Pragma price stale | oracle not fresh | `router.refresh_btc_price()` |

---

### 2. Strategy Rebalancer  `agents/strategy_rebalancer.py`

**Interval**: 5 minutes  
**Required roles**: `ROLE_KEEPER` (vault + router)

| Task | Cadence | Action |
|------|---------|--------|
| Yield accrual | every 1 h | `vault.trigger_yield_accrual()` |
| Price refresh | when stale | `router.refresh_btc_price()` |
| Health monitoring | every tick | structured log + warning |

Computes the recommended leverage from the health-to-leverage mapping:

$$\text{lev}(H) = \begin{cases} 1.0 & H < 1.10 \\ 1.0 + 0.5\,\frac{H-1.10}{0.20} & 1.10 \le H < 1.30 \\ 1.1 + 0.4\,\frac{H-1.30}{0.20} & 1.30 \le H < 1.50 \\ \min\!\left(1.5 + 0.5\,(H-1.50),\, 2.0\right) & H \ge 1.50 \end{cases}$$

---

### 3. User Guardian  `agents/user_guardian.py`

**Interval**: 30 seconds  
**Required roles**: `ROLE_LIQUIDATOR` (vault)

| Condition | Health (×100) | Action |
|-----------|---------------|--------|
| Near liquidation | ≤ 130 | structured warning log |
| Liquidatable | ≤ 100 | `vault.liquidate(user)` |

Discovers users via on-chain event indexing (`Deposit`, `LeverageAdjusted`,
`PositionLiquidated` events from the vault).

---

## Directory Structure

```
agents/
├── main.py                      # Entry point — starts all agents
├── config.py                    # Pydantic-settings configuration
├── requirements.txt
├── .env.example                 # Copy to .env and fill in
│
├── core/
│   ├── starknet_client.py       # Contract calls (router + vault)
│   ├── price_feed.py            # Binance / Coinbase / Kraken + volatility
│   ├── event_indexer.py         # On-chain event → user set
│   └── logger.py                # Structured logging (structlog)
│
├── agents/
│   ├── base.py                  # BaseAgent lifecycle & error handling
│   ├── risk_sentinel.py
│   ├── strategy_rebalancer.py
│   └── user_guardian.py
│
└── tests/
    ├── conftest.py              # Shared fixtures (mocked client, feed, indexer)
    ├── test_price_feed.py
    ├── test_risk_sentinel.py
    ├── test_strategy_rebalancer.py
    └── test_user_guardian.py
```

---

## Quick Start

### 1. Prerequisites

- Python ≥ 3.11
- Compiled Starknet contracts (`cd vault && scarb build`)
- A Starknet account for each agent role (see _Wallet Setup_ below)

### 2. Install dependencies

```bash
cd agents/
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

### 3. Configure environment

```bash
cp .env.example .env
# Edit .env — fill in RPC URL, contract addresses, and wallet keys
```

### 4. Run all agents

```bash
python main.py
```

### 5. Run a single agent (useful for debugging)

```bash
python main.py --agent risk_sentinel
python main.py --agent rebalancer
python main.py --agent guardian
```

---

## Wallet Setup

Each agent needs its own Starknet account with the appropriate role granted
by the contract owner after deployment.

```
Role assignment (run once after deploying contracts):

  router.grant_role(ROLE_GUARDIAN, <risk_sentinel_address>)
  router.grant_role(ROLE_KEEPER,   <risk_sentinel_address>)
  router.grant_role(ROLE_KEEPER,   <rebalancer_address>)
  vault.grant_role(ROLE_KEEPER,    <rebalancer_address>)
  vault.grant_role(ROLE_LIQUIDATOR, <guardian_address>)
```

> **Security**: Use separate wallets for each agent. Fund each with enough
> STRK to cover gas for at least 100 transactions. Store private keys in a
> secrets manager or hardware wallet for production deployments.

---

## Configuration Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `STARKNET_NETWORK` | `sepolia` | `mainnet` or `sepolia` |
| `STARKNET_RPC_URL` | Nethermind Sepolia | JSON-RPC endpoint |
| `ROUTER_ADDRESS` | `0x0` | Deployed BTCSecurityRouter address |
| `VAULT_ADDRESS` | `0x0` | Deployed BTCVault address |
| `RISK_SENTINEL_INTERVAL` | `60` | Poll interval (seconds) |
| `REBALANCER_INTERVAL` | `300` | Poll interval (seconds) |
| `GUARDIAN_INTERVAL` | `30` | Poll interval (seconds) |
| `MAX_PRICE_DROP_PCT` | `10.0` | % drop in 1 h triggering safe mode |
| `MAX_VOLATILITY_24H` | `0.80` | Annualised σ threshold |
| `GUARDIAN_WARN_HEALTH` | `130` | Health×100 warning level |
| `LOG_FORMAT` | `json` | `json` (prod) or `console` (dev) |

---

## Running Tests

```bash
cd agents/
pytest tests/ -v
```

All tests are offline — no network calls are made. Exchange APIs and Starknet
RPC are mocked via `aioresponses` and `unittest.mock`.

---

## Security Properties

| Threat | Mitigation |
|--------|-----------|
| Compromised agent key | Agent can only call permissioned functions; router rejects invalid conditions |
| Price feed manipulation | Median of 3 independent sources; on-chain Pragma oracle is the final authority |
| Accidental safe-mode spam | Client-side 5-minute cooldown + router's own cooldown |
| Liquidation front-running | Contract checks health on-chain atomically; tx reverts if position recovered |
| Agent outage | System remains secure — router enforces safety without agents |

---

## Observability

All agents emit structured JSON logs (configurable to coloured console output
for development). Key log events:

| Event | Level | Meaning |
|-------|-------|---------|
| `risk_sentinel.safe_mode_trigger` | WARNING | About to call enter_safe_mode |
| `risk_sentinel.safe_mode_entered` | INFO | TX accepted |
| `risk_sentinel.safe_mode_rejected` | WARNING | Router rejected (conditions not met) |
| `strategy_rebalancer.yield_accrual_triggered` | INFO | Yield accrual TX accepted |
| `user_guardian.liquidation_attempt` | WARNING | About to liquidate a user |
| `user_guardian.liquidation_succeeded` | INFO | TX accepted |
| `user_guardian.near_liquidation` | WARNING | User health in warning band |
| `agent.tick_error` | ERROR | Unhandled error in tick() |
| `agent.backoff` | WARNING | Consecutive errors; backing off |

---

## Next Steps

- [ ] Add Prometheus metrics exporter (`ENABLE_METRICS=true`)
- [ ] Add alerting (PagerDuty / Telegram) for CRITICAL health events  
- [ ] Dockerise for production deployment
- [ ] Add a second agent instance per type for redundancy
- [ ] Explore incentivised keeper network (agents earn fees per action)
