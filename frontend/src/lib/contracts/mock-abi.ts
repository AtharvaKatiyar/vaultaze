/**
 * ABIs for test-infrastructure contracts (Sepolia only).
 * MockPragmaOracle  — owner can call set_price to refresh the cached BTC/USD price.
 * MockWBTC          — deployed as YBTCToken v2 where vault_address = deployer.
 *                     The deployer can call mint() to distribute test tokens.
 */

/** IMockPragmaOracle — admin interface exposed by MockPragmaOracle */
export const MOCK_ORACLE_ABI = [
  {
    type: "function",
    name: "set_price",
    inputs: [{ name: "new_price", type: "core::integer::u128" }],
    outputs: [],
    state_mutability: "external",
  },
  {
    type: "function",
    name: "get_price",
    inputs: [],
    outputs: [{ type: "core::integer::u128" }],
    state_mutability: "view",
  },
  {
    type: "function",
    name: "get_last_updated",
    inputs: [],
    outputs: [{ type: "core::integer::u64" }],
    state_mutability: "view",
  },
  {
    type: "function",
    name: "get_data_median",
    inputs: [
      {
        name: "data_type",
        type: "vault::interfaces::DataType",
      },
    ],
    outputs: [
      {
        type: "vault::interfaces::PragmaPricesResponse",
      },
    ],
    state_mutability: "view",
  },
] as const;

/** IBTCSecurityRouter — keeper-accessible price refresh */
export const ROUTER_KEEPER_ABI = [
  {
    type: "function",
    name: "refresh_btc_price",
    inputs: [],
    outputs: [],
    state_mutability: "external",
  },
  {
    type: "function",
    name: "update_btc_backing",
    inputs: [{ name: "new_backing", type: "core::integer::u256" }],
    outputs: [],
    state_mutability: "external",
  },
] as const;

/**
 * MockWBTC mint — callable only by the vault_address stored in the contract.
 * For MockWBTC deployed on Sepolia, vault_address was set to the deployer account.
 */
export const MOCK_WBTC_ABI = [
  {
    type: "function",
    name: "mint",
    inputs: [
      { name: "to", type: "core::starknet::contract_address::ContractAddress" },
      { name: "amount", type: "core::integer::u256" },
    ],
    outputs: [],
    state_mutability: "external",
  },
  {
    type: "function",
    name: "balance_of",
    inputs: [{ name: "account", type: "core::starknet::contract_address::ContractAddress" }],
    outputs: [{ type: "core::integer::u256" }],
    state_mutability: "view",
  },
  {
    type: "function",
    name: "symbol",
    inputs: [],
    outputs: [{ type: "core::felt252" }],
    state_mutability: "view",
  },
] as const;

/** Deployer address that controls MockPragmaOracle and MockWBTC */
export const DEPLOYER_ADDRESS =
  "0x01390501de9c3e2c1f06d97fd317c1cd002d95250ab6f58bf1f272bdb9f8ed18";

export const MOCK_ORACLE_ADDRESS =
  "0x06d1c9aa3cb65003c51a4b360c8ac3a23a9724530246031ba92ff0b2461f7e74";

/**
 * BTC/USD price at 8-decimal Pragma precision.
 * 9_500_000_000_000 = $95,000
 */
export const DEFAULT_BTC_PRICE = "9500000000000";
