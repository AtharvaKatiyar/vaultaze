use starknet::ContractAddress;

// =====================================
// Role Constants (felt252 identifiers)
// =====================================
//
// Access-control model:
//   OWNER   — supreme authority; can grant/revoke all roles; 2-step ownership transfer.
//   ADMIN   — sensitive config changes that go through the timelock.
//   GUARDIAN— emergency powers: pause vault, enter safe-mode. No timelock required.
//             Cannot unpause or exit safe-mode (those require ADMIN + timelock).
//   KEEPER  — operational keepers: refresh oracle price, trigger yield accrual.
//   LIQUIDATOR — may call liquidate() on under-collateralised positions.
pub const ROLE_ADMIN: felt252       = 'ROLE_ADMIN';
pub const ROLE_GUARDIAN: felt252    = 'ROLE_GUARDIAN';
pub const ROLE_KEEPER: felt252      = 'ROLE_KEEPER';
pub const ROLE_LIQUIDATOR: felt252  = 'ROLE_LIQUIDATOR';

// Timelock delay in seconds (2 days).
pub const TIMELOCK_DELAY: u64 = 172_800;
/// Maximum time window (seconds) during which a queued operation remains executable.
/// An op queued at time T with ETA E expires at E + GRACE_PERIOD (E + 14 days).
/// After expiry it must be re-queued, protecting against stale governance ops
/// executing without fresh consent.
pub const GRACE_PERIOD: u64 = 1_209_600; // 14 days

// =====================================
// Access Control + Timelock Interface
// =====================================
//
// Both BTCVault and BTCSecurityRouter implement this interface.
// A single selector hashes op_id = hash(selector, target, calldata_hash, nonce).
// For simplicity we use a felt252 op_id supplied by the caller (off-chain computed).
#[starknet::interface]
pub trait IAccessControl<TContractState> {
    // ── Role queries ──────────────────────────────────────────────────────────
    fn has_role(self: @TContractState, role: felt252, account: ContractAddress) -> bool;
    fn get_owner(self: @TContractState) -> ContractAddress;
    /// Returns the address nominated via transfer_ownership() that has not yet
    /// called accept_ownership(). Returns zero when no transfer is pending.
    fn get_pending_owner(self: @TContractState) -> ContractAddress;
    /// Returns the admin-role whose holders can grant/revoke `role`.
    /// A return value of 0 means only the contract owner may manage this role.
    fn get_role_admin(self: @TContractState, role: felt252) -> felt252;
    /// Compute op_id = Poseidon(selector ++ params) — the hash that must be passed
    /// to queue_operation() and to the target timelocked function.
    /// Use this off-chain or via a view call to derive the correct op_id.
    fn hash_operation(self: @TContractState, selector: felt252, params: Span<felt252>) -> felt252;

    // ── Role management ───────────────────────────────────────────────────────
    /// Grant a role.  Caller must be the owner, or must hold the role's admin-role
    /// (see get_role_admin).  Roles with admin = 0 are owner-only.
    fn grant_role(ref self: TContractState, role: felt252, account: ContractAddress);
    fn revoke_role(ref self: TContractState, role: felt252, account: ContractAddress);
    /// Caller renounces their own role. Cannot remove someone else's role.
    fn renounce_role(ref self: TContractState, role: felt252);

    // ── Two-step ownership transfer ──────────────────────────────────────────
    fn transfer_ownership(ref self: TContractState, new_owner: ContractAddress);
    fn accept_ownership(ref self: TContractState);

    // ── Timelock ─────────────────────────────────────────────────────────────
    /// Queue a timelocked operation.
    /// op_id must equal hash_operation(selector, params) for the intended call —
    /// this binds the queued slot to exact calldata, preventing parameter-swapping.
    /// eta must be >= now + TIMELOCK_DELAY; the op expires at eta + GRACE_PERIOD.
    fn queue_operation(ref self: TContractState, op_id: felt252, eta: u64);
    /// Cancel a queued operation (owner or ADMIN).
    fn cancel_operation(ref self: TContractState, op_id: felt252);
    /// Mark a standalone queued operation executed.
    fn execute_operation(ref self: TContractState, op_id: felt252);
    /// View: returns eta of a queued op (0 = not queued or already executed).
    fn get_operation_eta(self: @TContractState, op_id: felt252) -> u64;
}

// =====================================
// Pragma Oracle Types & Interfaces
// =====================================

/// BTC/USD pair identifier for the Pragma oracle (felt252 encoding of "BTC/USD").
pub const BTC_USD_PRAGMA_KEY: felt252 = 'BTC/USD';

/// Live Pragma V2 oracle address on Starknet Mainnet.
/// Pass this to the BTCSecurityRouter constructor (or set via set_oracle_address)
/// when deploying on mainnet.
pub const PRAGMA_ORACLE_MAINNET: felt252 =
    0x2a85bd616f912537c50a49a4076db02c00b29b2cdc8a197ce92ed1837fa875b;

/// Live Pragma V2 oracle address on Starknet Sepolia testnet.
/// Use this for testnet deployments instead of MockPragmaOracle.
/// The BTCSecurityRouter already calls get_data_median() with BTC_USD_PRAGMA_KEY
/// — no code changes are needed, only point oracle_address here.
pub const PRAGMA_ORACLE_SEPOLIA: felt252 =
    0x36031daa264c24520b11d93af622c848b2499b66b41d611bac95e13cfca131a;

/// Identifies the type of price data to query from the Pragma oracle.
/// Use SpotEntry with BTC_USD_PRAGMA_KEY for the real-time BTC/USD spot price.
#[derive(Serde, Drop, Copy)]
pub enum DataType {
    SpotEntry: felt252,           // felt252 pair ID, e.g. BTC_USD_PRAGMA_KEY
    FutureEntry: (felt252, u64),  // (pair_id, expiry_timestamp)
    GenericEntry: felt252,        // generic data key
}

/// Price response returned by the Pragma oracle for price queries.
/// For BTC/USD: decimals = 8, so $95,000.00 → price = 9_500_000_000_000.
#[derive(Serde, Drop, Copy)]
pub struct PragmaPricesResponse {
    pub price: u128,                        // price * 10^decimals
    pub decimals: u32,                      // decimal places (8 for BTC/USD)
    pub last_updated_timestamp: u64,        // unix timestamp of the last update
    pub num_sources_aggregated: u32,        // number of data sources aggregated
    pub expiration_timestamp: Option<u64>,  // Some for futures; None for spot entries
}

/// Interface matching the live Pragma oracle ABI on Starknet.
/// MockPragmaOracle (in mock_pragma_oracle.cairo) provides a settable
/// implementation for unit tests.
#[starknet::interface]
pub trait IPragmaOracle<TContractState> {
    fn get_data_median(self: @TContractState, data_type: DataType) -> PragmaPricesResponse;
}

/// Test-only interface for controlling the MockPragmaOracle price.
#[starknet::interface]
pub trait IMockPragmaOracle<TContractState> {
    fn set_price(ref self: TContractState, new_price: u128);
    fn get_price(self: @TContractState) -> u128;
}

// =====================================
// User Mode & Dashboard Types
// =====================================

/// User-selected operating mode.
/// Determines which features are active for that user and what warnings apply.
///
/// - None     : deposited only, no leverage, no yield strategy selected.
/// - YieldOnly: user's collateral is deployed to a yield strategy.
///              Leverage is BLOCKED for this user.
/// - LeverageOnly: user has an open leveraged position.
///              Yield strategy deployment is BLOCKED for this user.
/// - Combined : both yield strategy AND leverage active simultaneously.
///              Carries the highest risk — requires explicit warning acceptance.
#[derive(Drop, Copy, Serde, PartialEq)]
pub enum UserMode {
    None,
    YieldOnly,
    LeverageOnly,
    Combined,
}

/// Complete per-user dashboard snapshot.
/// Returned by get_user_dashboard(user) — single on-chain call gives the frontend
/// every number it needs to render the user's position page.
#[derive(Drop, Serde)]
pub struct UserDashboard {
    // ── Holdings ────────────────────────────────────────────────────────────
    /// User's yBTC share balance (8 decimals, same as BTC).
    pub ybtc_balance: u256,
    /// BTC value of those shares at current share price (satoshis).
    pub btc_value_sat: u256,
    /// USD value of those shares at current oracle price (8-decimal USD, 0 if price stale).
    pub btc_value_usd: u256,

    // ── Leverage ────────────────────────────────────────────────────────────
    /// User's current leverage (100 = 1.0x, 150 = 1.5x).  0 means no position.
    pub current_leverage: u128,
    /// User's outstanding USD debt (8 decimals, Pragma scale).
    pub user_debt_usd: u256,
    /// Health factor ×100 (>150 safe, 120-150 warning, ≤100 liquidatable).
    /// u128::MAX when the user has no debt.
    pub health_factor: u128,
    /// BTC/USD price (8 dec) at which this user becomes liquidatable.
    /// 0 when user has no debt.
    pub liquidation_price_usd: u128,

    // ── Yield ───────────────────────────────────────────────────────────────
    /// Claimable yield accrued to this user (satoshis of wBTC).
    pub claimable_yield_sat: u256,
    /// Address of the yield strategy this user is enrolled in (zero = none).
    pub yield_strategy: ContractAddress,

    // ── User preferences ────────────────────────────────────────────────────
    /// Current operating mode.
    pub mode: UserMode,
    /// Custom leverage cap the user set (100-based, e.g. 120 = 1.2x).
    /// 0 means "use system max".
    pub custom_leverage_cap: u128,
    /// Custom maximum yield allocation (basis points, e.g. 5000 = 50% of collateral).
    /// 0 means "use system default".
    pub custom_yield_bps: u16,
    /// True when the user has explicitly accepted the custom-settings risk warning.
    pub warning_accepted: bool,
    /// Block timestamp of the user's first deposit.
    pub deposit_timestamp: u64,

    // ── Vault-level context ──────────────────────────────────────────────────
    /// Current vault share price (SCALE = 1_000_000 means 1.0).
    pub share_price: u256,
    /// Vault APY estimate in basis points (1000 = 10.00%).
    pub vault_apy: u128,
    /// True when the oracle price is fresh (< 3600 s old).
    pub price_is_fresh: bool,
    /// True when the router is in safe mode.
    pub is_safe_mode: bool,
    /// Recommended leverage cap the protocol suggests for this user's collateral.
    pub recommended_leverage: u128,
    /// Protocol-recommended lowest-risk active strategy address (zero = none available).
    pub recommended_strategy: ContractAddress,
    /// True when deposits are currently accepted.
    pub can_deposit: bool,
    /// True when new leverage can be applied.
    pub can_leverage: bool,
}

// =====================================
// BTC Security Router Interface
// =====================================

#[starknet::interface]
pub trait IBTCSecurityRouter<TContractState> {
    // View functions
    fn get_btc_health(self: @TContractState) -> u128;
    fn is_safe_mode(self: @TContractState) -> bool;
    fn get_max_leverage(self: @TContractState) -> u128;
    fn get_max_ltv(self: @TContractState) -> u128;
    fn get_btc_backing(self: @TContractState) -> u256;
    fn get_btc_exposure(self: @TContractState) -> u256;
    
    // Operation checks
    fn is_operation_allowed(
        self: @TContractState,
        operation_type: felt252,
        protocol: ContractAddress,
        amount: u256
    ) -> bool;
    
    // State updates
    fn update_btc_backing(ref self: TContractState, new_backing: u256);
    fn report_exposure(
        ref self: TContractState,
        collateral: u256,
        debt: u256,
        leverage: u128
    );
    
    // Safe mode
    fn enter_safe_mode(ref self: TContractState);
    
    // Protocol management
    fn register_protocol(
        ref self: TContractState,
        protocol: ContractAddress,
        protocol_type: felt252
    );

    // Oracle integration — BTC/USD price feed via Pragma
    fn get_btc_usd_price(self: @TContractState) -> u128;
    fn get_price_last_updated(self: @TContractState) -> u64;
    /// Returns true when a price has been fetched AND is within MAX_PRICE_AGE seconds.
    fn is_price_fresh(self: @TContractState) -> bool;
    fn refresh_btc_price(ref self: TContractState);
    /// Admin override: set BTC/USD price directly without calling Pragma.
    /// Callable by owner only. Useful on testnets where Pragma data is stale.
    /// Price uses 8 decimal places (Pragma convention): $95,000 = 9_500_000_000_000.
    fn admin_set_btc_price(ref self: TContractState, price: u128);

    // Timelocked admin functions
    fn set_oracle_address(ref self: TContractState, op_id: felt252, oracle: ContractAddress);
    fn set_safe_mode_threshold_timelocked(ref self: TContractState, op_id: felt252, threshold: u128);
    fn exit_safe_mode(ref self: TContractState, op_id: felt252);
}

// =====================================
// BTC Vault Interface
// =====================================

#[starknet::interface]
pub trait IBTCVault<TContractState> {
    // Core functions
    fn deposit(ref self: TContractState, amount: u256) -> u256;
    fn withdraw(ref self: TContractState, ybtc_amount: u256) -> u256;
    
    // Leverage management
    fn apply_leverage(ref self: TContractState, target_leverage: u128);
    fn deleverage(ref self: TContractState);
    
    // Strategy management
    fn deploy_to_strategy(
        ref self: TContractState,
        strategy: ContractAddress,
        amount: u256
    );
    fn withdraw_from_strategy(
        ref self: TContractState,
        strategy: ContractAddress,
        amount: u256
    );
    
    // View functions
    fn get_user_position(
        self: @TContractState,
        user: ContractAddress
    ) -> (u256, u256, u128); // (ybtc_balance, btc_value, leverage)
    fn get_share_price(self: @TContractState) -> u256;
    fn get_total_assets(self: @TContractState) -> u256;
    fn get_total_debt(self: @TContractState) -> u256;
    fn get_apy(self: @TContractState) -> u128;
    
    // Oracle price — delegates to the router's cached Pragma price
    fn get_btc_usd_price(self: @TContractState) -> u128;

    // Liquidation / per-user health
    /// Returns the user's health factor scaled by 100:
    ///   150 = 1.50x (safe), 120 = warning, 100 = liquidation threshold.
    /// Returns u128::MAX when the user has no leveraged debt.
    fn get_user_health(self: @TContractState, user: ContractAddress) -> u128;
    /// Returns the BTC/USD price (8 decimals) below which `user` becomes
    /// liquidatable (P_crit = D * BTC_DECIMALS / (C_sat * LIQUIDATION_LTV / 100)).
    /// Returns 0 when the user has no debt.
    fn get_liquidation_price(self: @TContractState, user: ContractAddress) -> u128;
    /// Returns true when get_user_health(user) <= 100.
    fn is_liquidatable(self: @TContractState, user: ContractAddress) -> bool;
    /// Liquidate an under-collateralised position.
    /// Caller receives the user's BTC collateral + LIQUIDATION_BONUS_BPS %.
    /// Panics if the position is healthy.
    fn liquidate(ref self: TContractState, user: ContractAddress);

    // Admin functions (instantaneous — owner or GUARDIAN for pause/unpause)
    fn pause(ref self: TContractState);
    fn unpause(ref self: TContractState);

    // Timelocked admin functions — must queue op_id first, wait TIMELOCK_DELAY, then call
    fn set_router(ref self: TContractState, op_id: felt252, router: ContractAddress);
    fn set_minimum_deposit_timelocked(ref self: TContractState, op_id: felt252, minimum: u256);

    // Strategy registration (owner or ROLE_ADMIN)
    fn register_strategy(ref self: TContractState, strategy: ContractAddress, risk_level: u8);

    // Yield accrual trigger (owner or ROLE_KEEPER)
    fn trigger_yield_accrual(ref self: TContractState);

    // ── User mode & preferences ───────────────────────────────────────────────
    /// Set the caller's operating mode and personal risk parameters.
    ///
    /// `mode`               — None / YieldOnly / LeverageOnly / Combined
    /// `yield_strategy`     — strategy address to enrol in (zero = no change / none)
    /// `custom_leverage_cap`— personal max leverage (100-based; 0 = use system max)
    /// `custom_yield_bps`   — max % of collateral to deploy to yield (bps; 0 = default)
    /// `accept_warning`     — MUST be true when custom_leverage_cap > recommended, or
    ///                        when mode = Combined.  Panics otherwise.
    fn set_user_mode(
        ref self: TContractState,
        mode: UserMode,
        yield_strategy: ContractAddress,
        custom_leverage_cap: u128,
        custom_yield_bps: u16,
        accept_warning: bool,
    );

    // ── Full per-user dashboard (single read for the frontend) ────────────────
    fn get_user_dashboard(
        self: @TContractState,
        user: ContractAddress,
    ) -> UserDashboard;

    // ── Yield claims ─────────────────────────────────────────────────────────
    /// How much wBTC yield the user can currently claim (satoshis).
    fn get_user_claimable_yield(self: @TContractState, user: ContractAddress) -> u256;
    /// Transfer the caller's claimable yield in wBTC to their wallet.
    fn claim_yield(ref self: TContractState);

    // ── Protocol recommendations (shown as defaults in the UI) ───────────────
    /// Safe leverage cap the protocol recommends for this user's collateral+health.
    fn get_recommended_leverage(self: @TContractState, user: ContractAddress) -> u128;
    /// Address of the lowest-risk active strategy the protocol recommends.
    /// Returns zero address when no strategy is registered.
    fn get_recommended_strategy(self: @TContractState) -> ContractAddress;
}

// =====================================
// yBTC Token Interface
// =====================================

#[starknet::interface]
pub trait IYBTCToken<TContractState> {
    // ERC20 standard
    fn name(self: @TContractState) -> ByteArray;
    fn symbol(self: @TContractState) -> ByteArray;
    fn decimals(self: @TContractState) -> u8;
    fn total_supply(self: @TContractState) -> u256;
    fn balance_of(self: @TContractState, account: ContractAddress) -> u256;
    fn allowance(
        self: @TContractState,
        owner: ContractAddress,
        spender: ContractAddress
    ) -> u256;
    
    fn transfer(ref self: TContractState, recipient: ContractAddress, amount: u256) -> bool;
    fn transfer_from(
        ref self: TContractState,
        sender: ContractAddress,
        recipient: ContractAddress,
        amount: u256
    ) -> bool;
    fn approve(ref self: TContractState, spender: ContractAddress, amount: u256) -> bool;
    
    // Vault-controlled minting/burning
    fn mint(ref self: TContractState, to: ContractAddress, amount: u256);
    fn burn(ref self: TContractState, from: ContractAddress, amount: u256);
}

// =====================================
// Strategy Interface
// =====================================

#[starknet::interface]
pub trait IStrategy<TContractState> {
    // Deploy capital to strategy
    fn deploy(ref self: TContractState, amount: u256);
    
    // Withdraw capital from strategy
    fn withdraw(ref self: TContractState, amount: u256) -> u256;
    
    // Get current value in strategy
    fn get_value(self: @TContractState) -> u256;
    
    // Get APY
    fn get_apy(self: @TContractState) -> u128;
    
    // Get strategy info
    fn get_strategy_info(self: @TContractState) -> (felt252, u8, u256); // (name, risk_level, capacity)
}

// =====================================
// ERC-20 Interface (for wBTC interactions)
// =====================================

#[starknet::interface]
pub trait IERC20<TContractState> {
    fn transfer(ref self: TContractState, recipient: ContractAddress, amount: u256) -> bool;
    fn transfer_from(
        ref self: TContractState,
        sender: ContractAddress,
        recipient: ContractAddress,
        amount: u256
    ) -> bool;
    fn approve(ref self: TContractState, spender: ContractAddress, amount: u256) -> bool;
    fn allowance(self: @TContractState, owner: ContractAddress, spender: ContractAddress) -> u256;
    fn balance_of(self: @TContractState, account: ContractAddress) -> u256;
}
