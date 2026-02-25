use starknet::{ContractAddress, get_caller_address, get_block_timestamp};

// =====================================
// MockStrategy Admin Interface (file-level so dispatcher types are crate-visible)
// =====================================

/// Interface for simulating real strategy yield in tests without a live
/// off-chain yield source.  Add pending yield, then call the vault's
/// `withdraw_from_strategy()` — the surplus flows through the real
/// accounting path, crediting both `total_assets` and `accumulated_yield`.
#[starknet::interface]
pub trait IMockStrategyAdmin<TContractState> {
    /// Queue `amount` of pending yield to be included in the next
    /// `withdraw()` call as a bonus on top of the principal.
    /// Caller must have already transferred `amount` of extra wBTC
    /// to this contract's address before calling this function.
    fn add_pending_yield(ref self: TContractState, amount: u256);
}


/// Mock Strategy Contract for Testing and Demonstration
/// This simulates a yield-generating strategy (e.g., lending protocol, LP pool)
#[starknet::contract]
mod MockStrategy {
    use super::{ContractAddress, get_caller_address, get_block_timestamp};
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use super::super::interfaces::{IERC20Dispatcher, IERC20DispatcherTrait};

    // =====================================
    // Storage
    // =====================================

    #[storage]
    struct Storage {
        // Strategy info
        name: felt252,
        risk_level: u8,         // 1-5, 5 = highest risk
        capacity: u256,          // Max capacity
        
        // Deployed capital
        total_deployed: u256,
        
        // Yield parameters
        base_apy: u128,          // e.g., 1200 = 12%
        last_yield_update: u64,
        accumulated_yield: u256,
        
        // Admin
        owner: ContractAddress,
        vault_address: ContractAddress,

        // ERC-20 token the strategy holds (wBTC)
        wbtc_address: ContractAddress,

        // Test helper: surplus wBTC to include in the next withdraw() call.
        // Set via add_pending_yield(); cleared automatically after each withdrawal.
        // The extra wBTC must already be present in this contract's balance.
        pending_yield: u256,
    }

    // =====================================
    // Events
    // =====================================

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Deployed: Deployed,
        Withdrawn: Withdrawn,
        YieldAccrued: YieldAccrued,
    }

    #[derive(Drop, starknet::Event)]
    struct Deployed {
        #[key]
        from: ContractAddress,
        amount: u256,
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct Withdrawn {
        #[key]
        to: ContractAddress,
        amount: u256,
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct YieldAccrued {
        amount: u256,
        timestamp: u64,
    }

    // =====================================
    // Constructor
    // =====================================

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        vault_address: ContractAddress,
        wbtc_address: ContractAddress,
        name: felt252,
        risk_level: u8,
        base_apy: u128,
        capacity: u256
    ) {
        self.owner.write(owner);
        self.vault_address.write(vault_address);
        self.wbtc_address.write(wbtc_address);
        self.name.write(name);
        self.risk_level.write(risk_level);
        self.base_apy.write(base_apy);
        self.capacity.write(capacity);
        self.total_deployed.write(0);
        self.accumulated_yield.write(0);
        self.pending_yield.write(0);
        self.last_yield_update.write(get_block_timestamp());
    }

    // =====================================
    // External Functions
    // =====================================

    #[abi(embed_v0)]
    impl MockStrategyImpl of super::super::interfaces::IStrategy<ContractState> {
        
        fn deploy(ref self: ContractState, amount: u256) {
            // Only vault can deploy
            self._only_vault();
            
            // Check capacity
            let current_deployed = self.total_deployed.read();
            let new_deployed = current_deployed + amount;
            assert(new_deployed <= self.capacity.read(), 'Exceeds capacity');
            
            // Accrue yield before updating deployed amount
            self._accrue_yield();
            
            // Update deployed amount
            self.total_deployed.write(new_deployed);
            
            self.emit(Deployed {
                from: get_caller_address(),
                amount,
                timestamp: get_block_timestamp(),
            });
        }

        fn withdraw(ref self: ContractState, amount: u256) -> u256 {
            // Only vault can withdraw
            self._only_vault();

            // Accrue yield before withdrawal
            self._accrue_yield();

            let current_deployed = self.total_deployed.read();
            let current_value = self.get_value();

            // Check if we have enough
            assert(amount <= current_value, 'Insufficient balance');

            // Consume any pending test yield (set via add_pending_yield).
            // This simulates a real strategy returning surplus on top of the principal.
            let pending = self.pending_yield.read();
            if pending > 0 {
                self.pending_yield.write(0);
            }

            // Calculate principal to return (capped at deployed)
            let principal_return = if amount <= current_deployed {
                amount
            } else {
                current_deployed
            };
            // Total return = principal + pending yield bonus
            let total_return = principal_return + pending;

            // Update deployed (reduce by principal only)
            self.total_deployed.write(current_deployed - principal_return);

            // Reduce accumulated yield if withdrawing more than deployed
            if amount > current_deployed {
                let yield_withdrawn = amount - current_deployed;
                let current_yield = self.accumulated_yield.read();
                if yield_withdrawn <= current_yield {
                    self.accumulated_yield.write(current_yield - yield_withdrawn);
                } else {
                    self.accumulated_yield.write(0);
                }
            }

            // Transfer wBTC back to vault (caller)
            let wbtc = IERC20Dispatcher { contract_address: self.wbtc_address.read() };
            let ok = wbtc.transfer(get_caller_address(), total_return);
            assert(ok, 'Strategy wBTC transfer failed');

            self.emit(Withdrawn {
                to: get_caller_address(),
                amount: total_return,
                timestamp: get_block_timestamp(),
            });

            total_return
        }

        fn get_value(self: @ContractState) -> u256 {
            // Return total value: deployed + accumulated yield
            self.total_deployed.read() + self.accumulated_yield.read()
        }

        fn get_apy(self: @ContractState) -> u128 {
            self.base_apy.read()
        }

        fn get_strategy_info(self: @ContractState) -> (felt252, u8, u256) {
            (
                self.name.read(),
                self.risk_level.read(),
                self.capacity.read()
            )
        }
    }

    // =====================================
    // Internal Functions
    // =====================================

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn _only_vault(self: @ContractState) {
            let caller = get_caller_address();
            // Only the registered vault contract may call deploy() or withdraw().
            // The owner bypass that existed here (|| caller == self.owner.read()) has
            // been intentionally removed: a direct owner call bypasses vault accounting
            // (deployed_capital / allocated_amount are never updated), which would
            // corrupt total_assets and strand capital from _ensure_liquidity's perspective.
            // For emergency capital recovery, call withdraw_from_strategy() on the vault
            // or use a governance-timelocked path that also updates vault accounting.
            assert(caller == self.vault_address.read(), 'Only vault can call');
        }

        fn _accrue_yield(ref self: ContractState) {
            let current_time = get_block_timestamp();
            let last_update = self.last_yield_update.read();
            let time_elapsed = current_time - last_update;
            
            if time_elapsed > 0 {
                let deployed = self.total_deployed.read();
                
                if deployed > 0 {
                    // Calculate yield: deployed * APY * (seconds / seconds_per_year)
                    let seconds_per_year: u256 = 31_536_000;
                    let apy = self.base_apy.read();
                    
                    // yield = (deployed * apy * time_elapsed) / (10000 * seconds_per_year)
                    // APY is in basis points (e.g., 1200 = 12%)
                    let yield_amount = (deployed * apy.into() * time_elapsed.into()) 
                        / (10000 * seconds_per_year);
                    
                    if yield_amount > 0 {
                        let new_accumulated = self.accumulated_yield.read() + yield_amount;
                        self.accumulated_yield.write(new_accumulated);
                        
                        self.emit(YieldAccrued {
                            amount: yield_amount,
                            timestamp: current_time,
                        });
                    }
                }
                
                self.last_yield_update.write(current_time);
            }
        }
    }

    // =====================================
    // Admin Functions
    // =====================================

    #[generate_trait]
    impl AdminImpl of AdminTrait {
        fn set_apy(ref self: ContractState, new_apy: u128) {
            let caller = get_caller_address();
            assert(caller == self.owner.read(), 'Only owner');
            
            // Accrue yield at old rate first
            self._accrue_yield();
            
            // Update APY
            self.base_apy.write(new_apy);
        }

        fn set_capacity(ref self: ContractState, new_capacity: u256) {
            let caller = get_caller_address();
            assert(caller == self.owner.read(), 'Only owner');
            self.capacity.write(new_capacity);
        }

        fn set_vault_address(ref self: ContractState, new_vault: ContractAddress) {
            let caller = get_caller_address();
            assert(caller == self.owner.read(), 'Only owner');
            self.vault_address.write(new_vault);
        }

        fn transfer_ownership(ref self: ContractState, new_owner: ContractAddress) {
            let caller = get_caller_address();
            assert(caller == self.owner.read(), 'Only owner');
            self.owner.write(new_owner);
        }

        fn force_accrue_yield(ref self: ContractState) {
            // Allow anyone to trigger yield accrual
            self._accrue_yield();
        }

        fn get_accumulated_yield(self: @ContractState) -> u256 {
            self.accumulated_yield.read()
        }

        fn get_total_deployed(self: @ContractState) -> u256 {
            self.total_deployed.read()
        }
    }

    // =====================================
    // ABI-Exposed Test Helpers
    // =====================================

    #[abi(embed_v0)]
    impl MockStrategyAdminImpl of super::IMockStrategyAdmin<ContractState> {
        fn add_pending_yield(ref self: ContractState, amount: u256) {
            // Owner-gated to prevent arbitrary callers from inflating the counter.
            let caller = get_caller_address();
            assert(caller == self.owner.read(), 'Only owner');
            self.pending_yield.write(self.pending_yield.read() + amount);
        }
    }
}
