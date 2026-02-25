# BTC Security Infrastructure - Smart Contracts

A comprehensive Bitcoin yield and leverage system built on Starknet using Cairo.

## Overview

This project implements a decentralized infrastructure for Bitcoin security, leveraging, and yield generation on Starknet. It consists of four main contracts:

1. **BTC Security Router** - System-wide health monitoring and safety enforcement
2. **BTC Vault** - Main vault for deposits, leverage, and yield strategies
3. **yBTC Token** - ERC20 share token representing vault ownership
4. **Mock Strategy** - Demonstration yield strategy

## Architecture

```
┌─────────────────────────────────────────────────┐
│              BTC Security Router                 │
│  • Global health monitoring                      │
│  • Dynamic leverage caps                         │
│  • Safe mode enforcement                         │
└──────────────┬──────────────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────────────┐
│                BTC Vault                         │
│  • Deposit/Withdraw wBTC                         │
│  • Mint/Burn yBTC shares                         │
│  • Apply leverage                                │
│  • Deploy to strategies                          │
└──────┬──────────────────┬───────────────────────┘
       │                  │
       ▼                  ▼
┌─────────────┐    ┌──────────────┐
│ yBTC Token  │    │  Strategies  │
│  • ERC20    │    │  • Lending   │
│  • Shares   │    │  • LP pools  │
└─────────────┘    └──────────────┘
```

## Features

### BTC Security Router
- **Global Health Tracking**: Monitors BTC backing vs. exposure system-wide
- **Dynamic Safety Parameters**: Adjusts leverage and LTV caps based on health
- **Safe Mode**: Automatically restricts risky operations during stress
- **Protocol Registration**: Manages registered protocols and their exposures

### BTC Vault
- **Share-Based Accounting**: yBTC tokens represent proportional vault ownership
- **Leverage Execution**: Borrow against BTC collateral to amplify positions
- **Strategy Integration**: Deploy capital to yield-generating strategies
- **Yield Accrual**: Automatically compounds returns for all users

### yBTC Token
- **ERC20 Compatible**: Standard token interface for composability
- **Non-Pegged**: Value floats based on vault performance
- **Transferable**: Can be used in other DeFi protocols
- **Vault-Controlled**: Only vault can mint/burn

### Mock Strategy
- **Yield Simulation**: Demonstrates strategy yield accrual
- **Time-Based Returns**: Calculates returns based on APY and time
- **Capacity Management**: Enforces deployment limits
- **Withdrawal Support**: Returns principal plus accrued yield

## Key Concepts

### Health Factor

The global BTC health factor determines system safety:

```
Health = BTC Backing / BTC Exposure
```

| Health | Status | Max Leverage | Max LTV |
|--------|--------|--------------|---------|
| ≥ 1.5  | Healthy | 1.35x+ | 75% |
| 1.2-1.5 | Moderate | 1.1-1.35x | 65% |
| 1.0-1.2 | Warning | 1.0-1.1x | 50% |
| < 1.0  | Critical | Disabled | 0% |

### Share Price Calculation

```
Share Price = Total Vault Assets / Total yBTC Supply
```

When yield is earned, assets increase while supply stays constant, increasing share price.

### Leverage Mechanics

Leverage amplifies both gains and losses:

```
Return (leveraged) = L × Return (BTC) - (L - 1) × Borrow Cost
```

Example with 1.5x leverage:
- BTC gains 20%: Position gains 1.5 × 20% = 30%
- BTC loses 20%: Position loses 1.5 × 20% = 30%

## Contract Interfaces

### IBTCSecurityRouter

```cairo
fn get_btc_health() -> u128
fn is_safe_mode() -> bool
fn get_max_leverage() -> u128
fn get_max_ltv() -> u128
fn is_operation_allowed(operation_type, protocol, amount) -> bool
fn report_exposure(collateral, debt, leverage)
```

### IBTCVault

```cairo
fn deposit(amount) -> u256  // Returns yBTC minted
fn withdraw(ybtc_amount) -> u256  // Returns BTC received
fn apply_leverage(target_leverage)
fn deleverage()
fn get_share_price() -> u256
fn get_user_position(user) -> (ybtc_balance, btc_value, leverage)
```

### IYBTCToken

```cairo
// Standard ERC20
fn transfer(recipient, amount) -> bool
fn approve(spender, amount) -> bool
fn balance_of(account) -> u256

// Vault-controlled
fn mint(to, amount)  // Only vault
fn burn(from, amount)  // Only vault
```

### IStrategy

```cairo
fn deploy(amount)
fn withdraw(amount) -> u256
fn get_value() -> u256
fn get_apy() -> u128
```

## Usage Examples

### Deposit and Receive yBTC

```cairo
// User deposits 1 BTC (100,000,000 satoshis)
let ybtc_minted = vault.deposit(100_000_000);

// Check share price
let share_price = vault.get_share_price();

// View position
let (ybtc_balance, btc_value, leverage) = vault.get_user_position(user);
```

### Apply Leverage

```cairo
// Check max allowed leverage from router
let max_leverage = router.get_max_leverage();

// Apply 1.5x leverage (150)
vault.apply_leverage(150);
```

### Withdraw with Profit

```cairo
// After yield accrues, share price increases
// Withdraw all yBTC
let btc_received = vault.withdraw(ybtc_balance);
// btc_received > original_deposit due to yield
```

## Safety Mechanisms

### 1. Router-Enforced Limits
All vault operations check with router for approval based on system health.

### 2. Safe Mode
Automatically activates when health drops below threshold:
- ❌ New deposits blocked
- ❌ New leverage blocked
- ✅ Withdrawals allowed
- ✅ Deleveraging encouraged

### 3. Pause Functionality
Admin can pause vault in emergencies.

### 4. Minimum Deposit
First deposit must meet minimum to prevent share price manipulation.

### 5. Capacity Limits
Strategies enforce maximum deployment amounts.

## Mathematical Models

### Share Minting Formula

```
shares_minted = deposit_amount × total_supply / total_assets
```

First deposit: `shares = deposit` (1:1)

### Share Redemption Formula

```
btc_returned = shares_burned × total_assets / total_supply
```

### Health-Based Leverage Cap

```
max_leverage(H) = 
  0                           if H < 1.0
  1.0 + 0.5(H - 1.0)         if 1.0 ≤ H < 1.2
  1.1 + 0.83(H - 1.2)        if 1.2 ≤ H < 1.5
  1.35 + 1.3(H - 1.5)        if H ≥ 1.5
```

## Testing

The project includes comprehensive test coverage:

```bash
# Run all tests
scarb test

# Run specific test
scarb test test_router_health_calculation
```

Test categories:
- Router tests: Health calculation, safe mode, leverage caps
- Vault tests: Deposits, withdrawals, leverage, strategies
- yBTC tests: ERC20 functionality, authorization
- Strategy tests: Yield accrual, withdrawals
- Integration tests: Full user flows, multi-user scenarios
- Edge cases: Minimum deposits, rounding, zero supply

## Building

```bash
# Build all contracts
scarb build

# Format code
scarb fmt

# Run tests
scarb test
```

## Deployment

1. Deploy BTC Security Router
2. Deploy yBTC Token
3. Deploy BTC Vault (with router and yBTC addresses)
4. Deploy Mock Strategy (optional, for testing)
5. Register vault as protocol in router
6. Register strategy in vault

## Configuration

### Router Parameters
- `safe_mode_threshold`: 110 (1.1)
- `min_health_factor`: 100 (1.0)

### Vault Parameters
- `minimum_deposit`: 1,000,000 satoshis (0.01 BTC)
- First deposit minimum: 10,000,000 satoshis (0.1 BTC)

### Strategy Parameters
- `base_apy`: 1200 (12%)
- `risk_level`: 1-5 scale
- `capacity`: Max deployment amount

## Security Considerations

1. **Audits**: Contracts should be audited before mainnet deployment
2. **Gradual Rollout**: Start with low caps, increase over time
3. **Monitoring**: Deploy autonomous agents to monitor health
4. **Emergency Controls**: Admin functions for pause/unpause
5. **Upgrade Path**: Consider proxy patterns for upgradeability

## Documentation

For detailed documentation, see:
- [Project Overview](../docs/01-project-overview.md)
- [BTC Security Router](../docs/02-btc-security-router.md)
- [Token Economics](../docs/03-token-economics.md)
- [Leverage Mechanics](../docs/05-leverage-mechanics.md)
- [Yield Strategies](../docs/06-yield-strategies.md)
- [Mathematical Models](../docs/07-mathematical-models.md)
- [Risk Management](../docs/09-risk-management.md)
- [Implementation Guide](../docs/10-implementation-guide.md)

## License

MIT

## Contributing

Contributions welcome! Please read the documentation first to understand the system architecture.

## Disclaimer

This is experimental DeFi software. Use at your own risk. The contracts handle real value and should be thoroughly tested and audited before production use.
