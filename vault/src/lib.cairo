// =====================================
// BTC Security Infrastructure
// A comprehensive Bitcoin yield and leverage system on Starknet
// =====================================

// Core contract interfaces
pub mod interfaces;

// Contract implementations
pub mod router;
pub mod vault;
pub mod ybtc_token;
pub mod mock_strategy;

// ── Test infrastructure ─────────────────────────────────────────────────────
// The modules below are compiled only in test builds (snforge / scarb test).
// In production, point BTCSecurityRouter.oracle_address at the live Pragma V2
// contract (see interfaces::PRAGMA_ORACLE_SEPOLIA / PRAGMA_ORACLE_MAINNET).
// MockStrategy should be replaced by production strategy contracts.
#[cfg(test)]
pub mod mock_pragma_oracle;

// Re-export main interfaces for convenience
pub use interfaces::{
    IBTCSecurityRouter, IBTCSecurityRouterDispatcher, IBTCSecurityRouterDispatcherTrait,
    IBTCVault, IBTCVaultDispatcher, IBTCVaultDispatcherTrait,
    IYBTCToken, IYBTCTokenDispatcher, IYBTCTokenDispatcherTrait,
    IStrategy, IStrategyDispatcher, IStrategyDispatcherTrait,
    IERC20, IERC20Dispatcher, IERC20DispatcherTrait,
    // Pragma oracle — production interface + live contract addresses
    IPragmaOracle, IPragmaOracleDispatcher, IPragmaOracleDispatcherTrait,
    DataType, PragmaPricesResponse, BTC_USD_PRAGMA_KEY,
    PRAGMA_ORACLE_SEPOLIA, PRAGMA_ORACLE_MAINNET,
    // Mock oracle interface types (always compiled — only the contract is test-only)
    IMockPragmaOracle, IMockPragmaOracleDispatcher, IMockPragmaOracleDispatcherTrait,
    // Access control
    IAccessControl, IAccessControlDispatcher, IAccessControlDispatcherTrait,
    ROLE_ADMIN, ROLE_GUARDIAN, ROLE_KEEPER, ROLE_LIQUIDATOR, TIMELOCK_DELAY, GRACE_PERIOD,
};
// Mock strategy admin interface (test helper for simulating real yield)
pub use mock_strategy::{IMockStrategyAdmin, IMockStrategyAdminDispatcher, IMockStrategyAdminDispatcherTrait};
// YBTCToken admin interface (ownership transfer helpers)
pub use ybtc_token::{IYBTCAdmin, IYBTCAdminDispatcher, IYBTCAdminDispatcherTrait};
