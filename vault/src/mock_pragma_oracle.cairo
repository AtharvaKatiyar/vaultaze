use starknet::get_block_timestamp;

/// MockPragmaOracle — a controllable price oracle for unit tests / Sepolia E2E testing.
///
/// ⚠ TEST INFRASTRUCTURE ONLY — do NOT use on mainnet.
///   On Sepolia and mainnet, point BTCSecurityRouter.oracle_address at the live
///   Pragma V2 contract instead:
///     Sepolia:  0x36031daa264c24520b11d93af622c848b2499b66b41d611bac95e13cfca131a
///     Mainnet:  0x2a85bd616f912537c50a49a4076db02c00b29b2cdc8a197ce92ed1837fa875b
///
/// Implements `IPragmaOracle` (the real Pragma V2 ABI) and `IMockPragmaOracle`
/// (owner-only admin interface). The deployer is automatically set as owner;
/// only the owner may call `set_price`.
///
/// Price encoding matches Pragma conventions:
///   BTC/USD $95,000.00  →  price = 9_500_000_000_000  (8 decimal places)
#[starknet::contract]
mod MockPragmaOracle {
    use super::get_block_timestamp;
    use starknet::{ContractAddress, get_caller_address};
    use core::num::traits::Zero;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use super::super::interfaces::{
        DataType, PragmaPricesResponse,
    };

    // ==============================
    // Events
    // ==============================

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        MockPriceSet: MockPriceSet,
    }

    #[derive(Drop, starknet::Event)]
    struct MockPriceSet {
        #[key]
        caller: ContractAddress,
        new_price: u128,
        timestamp: u64,
    }

    // ==============================
    // Storage
    // ==============================

    #[storage]
    struct Storage {
        /// Contract owner (deployer). Only the owner may call set_price.
        owner: ContractAddress,
        /// Stored price with 8 decimal places (Pragma convention).
        price: u128,
        /// Block timestamp when the price was last written.
        last_updated: u64,
    }

    // ==============================
    // Constructor
    // ==============================

    /// Deploys the mock oracle with an initial BTC/USD price.
    /// `owner` is the address that will be authorised to call set_price.
    /// Pass a specific test-account address or the keeper account here.
    #[constructor]
    fn constructor(ref self: ContractState, initial_price: u128, owner: ContractAddress) {
        assert(!owner.is_zero(), 'Owner is zero');
        self.owner.write(owner);
        self.price.write(initial_price);
        self.last_updated.write(get_block_timestamp());
    }

    // ==============================
    // IPragmaOracle implementation
    // ==============================

    /// Returns the stored price regardless of which `data_type` is requested.
    /// The DataType parameter is accepted to match the real Pragma ABI but is
    /// intentionally ignored — tests set a single global BTC/USD mock price.
    #[abi(embed_v0)]
    impl IPragmaOracleImpl of super::super::interfaces::IPragmaOracle<ContractState> {
        fn get_data_median(self: @ContractState, data_type: DataType) -> PragmaPricesResponse {
            PragmaPricesResponse {
                price: self.price.read(),
                decimals: 8_u32,
                last_updated_timestamp: self.last_updated.read(),
                num_sources_aggregated: 5_u32,
                expiration_timestamp: Option::None,
            }
        }
    }

    // ==============================
    // IMockPragmaOracle implementation (test admin)
    // ==============================

    #[abi(embed_v0)]
    impl IMockPragmaOracleImpl of super::super::interfaces::IMockPragmaOracle<ContractState> {
        /// Set a new mock price (8-decimal Pragma format) and update the timestamp.
        /// Only the deployer (owner) may call this — prevents adversaries on the
        /// testnet from manipulating the price seen by the router.
        fn set_price(ref self: ContractState, new_price: u128) {
            let caller = get_caller_address();
            assert(caller == self.owner.read(), 'Only owner can set price');
            let now = get_block_timestamp();
            self.price.write(new_price);
            self.last_updated.write(now);
            self.emit(MockPriceSet { caller, new_price, timestamp: now });
        }

        /// Read back the currently stored mock price.
        fn get_price(self: @ContractState) -> u128 {
            self.price.read()
        }
    }
}
