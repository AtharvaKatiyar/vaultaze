use starknet::{ContractAddress, get_caller_address, get_block_timestamp, get_contract_address};
use starknet::storage::Map;

#[starknet::contract]
mod BTCVault {
    use super::{ContractAddress, get_caller_address, get_block_timestamp, get_contract_address, Map};
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess, StorageMapReadAccess, StorageMapWriteAccess};
    use core::num::traits::Zero;
    use core::poseidon::poseidon_hash_span;
    use super::super::interfaces::
    {
        IBTCSecurityRouterDispatcher, IBTCSecurityRouterDispatcherTrait,
        IYBTCTokenDispatcher, IYBTCTokenDispatcherTrait,
        IERC20Dispatcher, IERC20DispatcherTrait,
        IStrategyDispatcher, IStrategyDispatcherTrait,
        IAccessControl,
        ROLE_ADMIN, ROLE_GUARDIAN, ROLE_KEEPER, ROLE_LIQUIDATOR, TIMELOCK_DELAY, GRACE_PERIOD,
        UserMode, UserDashboard,
    };

    // ╔═══════════════════════════════════════════════════════════════════════╗
    // ║                  FORMAL SPECIFICATION — BTCVault v1                  ║
    // ╠═══════════════════════════════════════════════════════════════════════╣
    // ║  SYSTEM INVARIANTS  (must hold after every external call)            ║
    // ║  ─────────────────────────────────────────────────────────────────── ║
    // ║  I-1  owner ≠ 0x0                                                    ║
    // ║  I-2  deployed_capital ≤ total_assets                               ║
    // ║  I-3  minimum_deposit > 0                                            ║
    // ║  I-4  ybtc_total_supply > 0  ⟹  total_assets > 0  (no phantom supply)║
    // ║  I-5  reentrancy_guard = false  (released between external calls)   ║
    // ║                                                                       ║
    // ║  SAFETY PROPERTIES  (must never be violated)                         ║
    // ║  ─────────────────────────────────────────────────────────────────── ║
    // ║  S-1  deposit(D):  wBTC pulled ⟹ yBTC minted  (atomically)         ║
    // ║  S-2  withdraw(S): yBTC burned ⟹ wBTC returned (atomically)        ║
    // ║  S-3  liquidate(u): gated by is_liquidatable(u) = true             ║
    // ║  S-4  set_router: op_id must equal hash('set_router', [new_router]) ║
    // ║  S-5  share_price = total_assets * SCALE / ybtc_supply (supply > 0) ║
    // ║  S-6  leverage blocked when oracle price = 0 (stale or absent)      ║
    // ║                                                                       ║
    // ║  LIVENESS PROPERTIES                                                 ║
    // ║  ─────────────────────────────────────────────────────────────────── ║
    // ║  L-1  any op with eta ≤ now ≤ eta + GRACE_PERIOD can be executed    ║
    // ║  L-2  owner can always transfer ownership to a non-zero address      ║
    // ║                                                                       ║
    // ║  ACCESS CONTROL MATRIX  (TL = requires timelock)                    ║
    // ║  ─────────────────────────────────────────────────────────────────── ║
    // ║  Function                   │ OWNER │ ADMIN │ GUARD │ KEEP │ LQDR  ║
    // ║  grant_role(ADMIN/GUARD)    │   ✓   │       │       │      │       ║
    // ║  grant_role(KEEP/LQDR)      │   ✓   │   ✓   │       │      │       ║
    // ║  queue_operation            │   ✓   │   ✓   │       │      │       ║
    // ║  set_router          (TL)   │   ✓   │   ✓   │       │      │       ║
    // ║  set_min_deposit     (TL)   │   ✓   │   ✓   │       │      │       ║
    // ║  pause                      │   ✓   │       │   ✓   │      │       ║
    // ║  unpause                    │   ✓   │       │       │      │       ║
    // ║  deploy/withdraw_strategy   │   ✓   │   ✓   │       │      │       ║
    // ║  liquidate                  │   ✓   │       │       │      │   ✓   ║
    // ║  trigger_yield_accrual      │   ✓   │       │       │  ✓   │       ║
    // ║  register_strategy          │   ✓   │   ✓   │       │      │       ║
    // ║                                                                       ║
    // ║  TRUST ASSUMPTIONS                                                   ║
    // ║  ─────────────────────────────────────────────────────────────────── ║
    // ║  T-1  wBTC: compliant ERC-20, no fee-on-transfer, returns bool      ║
    // ║  T-2  Router: is_operation_allowed is non-manipulable               ║
    // ║  T-3  Pragma oracle: BTC/USD median price is correct and fresh      ║
    // ║  T-4  Owner/ADMIN: only queue legitimate governance operations       ║
    // ║  T-5  yBTC: only the vault can mint/burn (enforced by YBTCToken)    ║
    // ╚═══════════════════════════════════════════════════════════════════════╝

    // =====================================
    // Storage
    // =====================================

    #[storage]
    struct Storage {
        // Reentrancy protection (docs: 09-risk-management Runtime Protections)
        reentrancy_guard: bool,

        // Token addresses
        wbtc_address: ContractAddress,
        ybtc_address: ContractAddress,
        usdc_address: ContractAddress,
        
        // Router
        router_address: ContractAddress,
        
        // Vault state
        total_assets: u256,      // Total BTC assets (in BTC terms)
        total_debt: u256,        // Total debt (in USD terms)
        ybtc_total_supply: u256, // Total yBTC minted
        deployed_capital: u256,  // Capital deployed to strategies (USD)
        
        // User positions
        user_leverage: Map<ContractAddress, u128>,
        user_debt: Map<ContractAddress, u256>,  // per-user USD debt (8 decimals, Pragma scale)
        
        // Strategy allocations
        strategies: Map<ContractAddress, StrategyInfo>,
        strategy_count: u32,
        // Parallel address index so _ensure_liquidity can walk all strategies.
        // strategy_addresses[i] = address of the i-th registered strategy.
        // register_strategy() appends; deactivate_strategy() marks inactive (not removed).
        strategy_addresses: Map<u32, ContractAddress>,

        // Yield tracking
        last_yield_update: u64,
        accumulated_yield: u256,
        
        // Admin & control
        owner: ContractAddress,
        paused: bool,
        minimum_deposit: u256,

        // Role-based access control
        roles: Map<(felt252, ContractAddress), bool>, // (role, account) => granted
        pending_owner: ContractAddress,               // 2-step ownership transfer

        // Role hierarchy: role => admin_role whose holders can grant/revoke this role.
        // A stored value of 0 means only the owner may manage this role.
        role_admin: Map<felt252, felt252>,

        // Timelock: op_id => earliest execution timestamp (0 = not queued / consumed)
        timelock_queue: Map<felt252, u64>,

        // ─── Per-user mode & preferences ─────────────────────────────────────────
        // Operating mode: 0=None, 1=YieldOnly, 2=LeverageOnly, 3=Combined
        // Stored as u8 because Cairo enums with Store require explicit mapping.
        user_mode: Map<ContractAddress, u8>,
        // Strategy address the user chose for yield (zero = no strategy selected)
        user_yield_strategy: Map<ContractAddress, ContractAddress>,
        // User's personal max-leverage cap (100-based; 0 = use system max)
        user_custom_leverage_cap: Map<ContractAddress, u128>,
        // User's custom yield allocation cap in basis points (0 = no cap / use default)
        user_custom_yield_bps: Map<ContractAddress, u16>,
        // True once the user has acknowledged the custom-settings risk warning
        user_warning_accepted: Map<ContractAddress, bool>,
        // Block timestamp of the user's first deposit (0 = never deposited)
        user_deposit_timestamp: Map<ContractAddress, u64>,
        // Snapshot of accumulated_yield at the user's last claim
        // Claimable = (accumulated_yield - snapshot) * user_shares / total_supply
        user_yield_snapshot: Map<ContractAddress, u256>,
    }

    // =====================================
    // Data Structures
    // =====================================

    #[derive(Drop, Copy, Serde, starknet::Store)]
    struct StrategyInfo {
        strategy_address: ContractAddress,
        allocated_amount: u256,
        active: bool,
        risk_level: u8,
    }

    // =====================================
    // Events
    // =====================================

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Deposit: Deposit,
        Withdrawal: Withdrawal,
        LeverageAdjusted: LeverageAdjusted,
        StrategyDeployed: StrategyDeployed,
        StrategyWithdrawn: StrategyWithdrawn,
        YieldAccrued: YieldAccrued,
        Paused: Paused,
        Unpaused: Unpaused,
        PositionLiquidated: PositionLiquidated,
        RoleGranted: RoleGranted,
        RoleRevoked: RoleRevoked,
        OwnershipTransferStarted: OwnershipTransferStarted,
        OwnershipTransferred: OwnershipTransferred,
        OperationQueued: OperationQueued,
        OperationExecuted: OperationExecuted,
        OperationCancelled: OperationCancelled,
        UserModeSet: UserModeSet,
        YieldClaimed: YieldClaimed,
    }

    #[derive(Drop, starknet::Event)]
    struct Deposit {
        #[key]
        user: ContractAddress,
        amount: u256,
        ybtc_minted: u256,
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct Withdrawal {
        #[key]
        user: ContractAddress,
        ybtc_burned: u256,
        amount_received: u256,
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct LeverageAdjusted {
        #[key]
        user: ContractAddress,
        old_leverage: u128,
        new_leverage: u128,
    }

    #[derive(Drop, starknet::Event)]
    struct StrategyDeployed {
        #[key]
        strategy: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct StrategyWithdrawn {
        #[key]
        strategy: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct YieldAccrued {
        amount: u256,
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct Paused {
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct Unpaused {
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct PositionLiquidated {
        #[key]
        liquidator: ContractAddress,
        #[key]
        user: ContractAddress,
        collateral_seized: u256,  // satoshis of wBTC sent to liquidator (incl. bonus)
        debt_cleared: u256,       // USD debt cleared (8 decimals)
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct RoleGranted {
        #[key]
        role: felt252,
        #[key]
        account: ContractAddress,
        sender: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct RoleRevoked {
        #[key]
        role: felt252,
        #[key]
        account: ContractAddress,
        sender: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct OwnershipTransferStarted {
        #[key]
        previous_owner: ContractAddress,
        #[key]
        new_owner: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct OwnershipTransferred {
        #[key]
        previous_owner: ContractAddress,
        #[key]
        new_owner: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct OperationQueued {
        #[key]
        op_id: felt252,
        eta: u64,
        sender: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct OperationExecuted {
        #[key]
        op_id: felt252,
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct OperationCancelled {
        #[key]
        op_id: felt252,
        sender: ContractAddress,
    }

    /// Emitted when a user configures their operating mode and/or custom risk parameters.
    #[derive(Drop, starknet::Event)]
    struct UserModeSet {
        #[key]
        user: ContractAddress,
        mode: u8,
        yield_strategy: ContractAddress,
        custom_leverage_cap: u128,
        custom_yield_bps: u16,
        warning_accepted: bool,
        timestamp: u64,
    }

    /// Emitted when a user claims their proportional share of accrued vault yield.
    #[derive(Drop, starknet::Event)]
    struct YieldClaimed {
        #[key]
        user: ContractAddress,
        amount_sat: u256,
        timestamp: u64,
    }

    // =====================================
    // Constants
    // =====================================

    const SCALE: u256 = 1_000_000; // 6 decimals for share price
    const MINIMUM_FIRST_DEPOSIT: u256 = 10_000_000; // 0.1 BTC (8 decimals)
    const BTC_DECIMALS: u256 = 100_000_000; // 10^8
    const MAX_LEVERAGE_INCREASE_PER_TX: u128 = 100; // Max 1.0x per tx (allows 1.0x→2.0x in one step)

    // Liquidation health thresholds (scaled ×100: 150 = 1.5x, 100 = 1.0x)
    const HEALTH_SAFE: u128 = 150;          // green zone
    const HEALTH_WARNING: u128 = 120;       // orange zone
    const HEALTH_DANGER: u128 = 100;        // liquidation threshold (h ≤ 100 → liquidatable)
    const LIQUIDATION_LTV: u256 = 80;       // λ = 80% (collateral factor in %)
    const LIQUIDATION_BONUS_BPS: u256 = 5;  // 5% extra wBTC bonus to liquidator

    // =====================================
    // Constructor
    // =====================================

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        wbtc_address: ContractAddress,
        ybtc_address: ContractAddress,
        usdc_address: ContractAddress,
        router_address: ContractAddress
    ) {
        assert(!owner.is_zero(), 'Owner is zero address');
        assert(!wbtc_address.is_zero(), 'wBTC address is zero');
        assert(!ybtc_address.is_zero(), 'yBTC address is zero');
        assert(!router_address.is_zero(), 'Router address is zero');
        self.owner.write(owner);
        self.wbtc_address.write(wbtc_address);
        self.ybtc_address.write(ybtc_address);
        self.usdc_address.write(usdc_address);
        self.router_address.write(router_address);
        self.paused.write(false);
        self.minimum_deposit.write(1_000_000); // 0.01 BTC minimum
        self.total_assets.write(0);
        self.total_debt.write(0);
        self.ybtc_total_supply.write(0);
        self.deployed_capital.write(0);
        self.strategy_count.write(0);
        self.last_yield_update.write(get_block_timestamp());
        self.accumulated_yield.write(0);
        // Delegate operational roles to ADMIN: any ADMIN holder can grant/revoke
        // KEEPER and LIQUIDATOR without requiring the owner's key.
        // ADMIN and GUARDIAN remain owner-only (role_admin default 0).
        self.role_admin.write(ROLE_KEEPER, ROLE_ADMIN);
        self.role_admin.write(ROLE_LIQUIDATOR, ROLE_ADMIN);
    }

    // =====================================
    // External Functions
    // =====================================

    /// Compute a deterministic operation ID: Poseidon(selector ++ params).
    /// Both the queuer and the timelocked function must compute the same hash
    /// from identical (selector, params) — preventing parameter-substitution attacks.
    fn compute_op_id(selector: felt252, params: Span<felt252>) -> felt252 {
        let mut full: Array<felt252> = array![selector];
        let mut i: u32 = 0;
        let len = params.len();
        while i < len {
            full.append(*params.at(i));
            i += 1;
        };
        poseidon_hash_span(full.span())
    }

    // =====================================
    // Access Control Implementation
    // =====================================

    #[abi(embed_v0)]
    impl AccessControlImpl of IAccessControl<ContractState> {
        fn has_role(self: @ContractState, role: felt252, account: ContractAddress) -> bool {
            self.roles.read((role, account))
        }

        fn get_owner(self: @ContractState) -> ContractAddress {
            self.owner.read()
        }

        fn get_pending_owner(self: @ContractState) -> ContractAddress {
            self.pending_owner.read()
        }

        fn get_role_admin(self: @ContractState, role: felt252) -> felt252 {
            self.role_admin.read(role)
        }

        fn hash_operation(self: @ContractState, selector: felt252, params: Span<felt252>) -> felt252 {
            compute_op_id(selector, params)
        }

        fn grant_role(ref self: ContractState, role: felt252, account: ContractAddress) {
            let caller = get_caller_address();
            self._check_can_manage_role(caller, role);
            assert(!account.is_zero(), 'Account is zero address');
            self.roles.write((role, account), true);
            self.emit(RoleGranted {
                role,
                account,
                sender: caller,
            });
        }

        fn revoke_role(ref self: ContractState, role: felt252, account: ContractAddress) {
            let caller = get_caller_address();
            self._check_can_manage_role(caller, role);
            self.roles.write((role, account), false);
            self.emit(RoleRevoked {
                role,
                account,
                sender: caller,
            });
        }

        fn transfer_ownership(ref self: ContractState, new_owner: ContractAddress) {
            self._only_owner();
            assert(!new_owner.is_zero(), 'New owner is zero');
            let previous = self.owner.read();
            self.pending_owner.write(new_owner);
            self.emit(OwnershipTransferStarted {
                previous_owner: previous,
                new_owner,
            });
        }

        fn accept_ownership(ref self: ContractState) {
            let caller = get_caller_address();
            let pending = self.pending_owner.read();
            assert(caller == pending, 'Not pending owner');
            let previous = self.owner.read();
            self.owner.write(caller);
            self.pending_owner.write(core::num::traits::Zero::zero());
            self.emit(OwnershipTransferred {
                previous_owner: previous,
                new_owner: caller,
            });
        }

        fn renounce_role(ref self: ContractState, role: felt252) {
            let caller = get_caller_address();
            assert(self.roles.read((role, caller)), 'Role not held');
            self.roles.write((role, caller), false);
            self.emit(RoleRevoked {
                role,
                account: caller,
                sender: caller,
            });
        }

        /// Queue a timelocked operation for future execution.
        ///
        /// **CRITICAL:** `op_id` must equal `hash_operation(selector, params)` for the
        /// intended call, computed by the caller off-chain or via `hash_operation()`.
        /// This binds the queue slot to exact calldata — any parameter substitution at
        /// execution time will be caught by the receiving function's hash verification.
        ///
        /// **Pre-conditions:**
        ///   - caller is owner or holds ROLE_ADMIN
        ///   - `eta >= block_timestamp + TIMELOCK_DELAY` (2 days)
        ///   - `op_id` not already queued (prevents duplicate slot)
        ///
        /// **Post-conditions:**
        ///   - `timelock_queue[op_id] = eta`
        ///   - op expires at `eta + GRACE_PERIOD` (14 days) and must be re-queued after
        ///
        /// **Emits:** `OperationQueued`
        fn queue_operation(ref self: ContractState, op_id: felt252, eta: u64) {
            self._only_owner_or_role(ROLE_ADMIN);
            let now = get_block_timestamp();
            assert(eta >= now + TIMELOCK_DELAY, 'ETA too early');
            assert(self.timelock_queue.read(op_id) == 0, 'Op already queued');
            self.timelock_queue.write(op_id, eta);
            self.emit(OperationQueued {
                op_id,
                eta,
                sender: get_caller_address(),
            });
        }

        fn cancel_operation(ref self: ContractState, op_id: felt252) {
            self._only_owner_or_role(ROLE_ADMIN);
            assert(self.timelock_queue.read(op_id) != 0, 'Op not queued');
            self.timelock_queue.write(op_id, 0);
            self.emit(OperationCancelled {
                op_id,
                sender: get_caller_address(),
            });
        }

        fn execute_operation(ref self: ContractState, op_id: felt252) {
            self._only_owner_or_role(ROLE_ADMIN);
            // _check_timelock already emits OperationExecuted — do not emit again here.
            self._check_timelock(op_id);
        }

        fn get_operation_eta(self: @ContractState, op_id: felt252) -> u64 {
            self.timelock_queue.read(op_id)
        }
    }

    // =====================================
    // External Functions
    // =====================================

    #[abi(embed_v0)]
    impl BTCVaultImpl of super::super::interfaces::IBTCVault<ContractState> {
        
        // ===== Core Deposit/Withdraw Functions =====

        /// Deposit `amount` wBTC into the vault and receive yBTC shares.
        ///
        /// **Pre-conditions (Checks):**
        ///   - vault not paused
        ///   - `amount > 0` and `amount >= minimum_deposit`
        ///   - if first deposit: `amount >= MINIMUM_FIRST_DEPOSIT` (10_000_000 sat)
        ///   - `wbtc.allowance(caller, vault) >= amount`
        ///   - router `is_operation_allowed('deposit', vault, amount)` is true
        ///
        /// **State mutations (Effects):**
        ///   - `total_assets += amount`
        ///   - `ybtc_total_supply += shares_minted`
        ///   - yBTC minted to caller
        ///
        /// **External calls (Interactions):**
        ///   - `wbtc.transfer_from(caller, vault, amount)` — reentrancy guard active
        ///   - `ybtc.mint(caller, shares)` — reentrancy guard active
        ///
        /// **Emits:** `Deposit`
        /// **Invariants maintained:** I-1 through I-5
        fn deposit(ref self: ContractState, amount: u256) -> u256 {
            assert(!self.reentrancy_guard.read(), 'Reentrant call');
            self.reentrancy_guard.write(true);
            assert(!self.paused.read(), 'Vault paused');
            assert(amount > 0, 'Zero deposit amount');
            assert(amount >= self.minimum_deposit.read(), 'Amount too small');
            
            let caller = get_caller_address();
            
            // Check with router
            let router = super::super::interfaces::IBTCSecurityRouterDispatcher {
                contract_address: self.router_address.read()
            };
            assert(
                router.is_operation_allowed('deposit', get_contract_address(), amount),
                'Router rejected deposit'
            );

            // Validate first-deposit minimum BEFORE moving tokens
            // (all checks must pass before any state change or token transfer)
            let current_supply = self.ybtc_total_supply.read();
            if current_supply == 0 {
                assert(amount >= MINIMUM_FIRST_DEPOSIT, 'First deposit too small');
            }

            // Snapshot yield on every fresh vault entry (first deposit OR re-deposit
            // after full withdrawal).  Checking the yBTC balance rather than the stored
            // timestamp fixes the stale-snapshot window: a user who held zero shares
            // for a period must not inherit an old (lower) snapshot and be able to
            // claim yield that accrued while they held no shares.
            let ybtc = super::super::interfaces::IYBTCTokenDispatcher {
                contract_address: self.ybtc_address.read()
            };
            if ybtc.balance_of(caller) == 0 {
                self.user_deposit_timestamp.write(caller, get_block_timestamp());
                self.user_yield_snapshot.write(caller, self.accumulated_yield.read());
            }

            // Pull wBTC from user into the vault — only after all validation passes
            let wbtc = IERC20Dispatcher { contract_address: self.wbtc_address.read() };
            let ok = wbtc.transfer_from(caller, get_contract_address(), amount);
            assert(ok, 'wBTC transfer_from failed');

            // Calculate yBTC to mint
            let ybtc_to_mint = self._calculate_shares_to_mint(amount);

            // Mint yBTC  (ybtc dispatcher already declared above)
            ybtc.mint(caller, ybtc_to_mint);
            
            // Update state
            let new_total_assets = self.total_assets.read() + amount;
            self.total_assets.write(new_total_assets);
            
            let new_supply = self.ybtc_total_supply.read() + ybtc_to_mint;
            self.ybtc_total_supply.write(new_supply);
            
            // Report to router
            self._report_to_router();
            
            self.emit(Deposit {
                user: caller,
                amount,
                ybtc_minted: ybtc_to_mint,
                timestamp: get_block_timestamp(),
            });

            self.reentrancy_guard.write(false);
            ybtc_to_mint
        }

        /// Burn `ybtc_amount` yBTC shares and receive proportional wBTC back.
        ///
        /// **Pre-conditions (Checks):**
        ///   - vault not paused
        ///   - `ybtc_amount > 0`
        ///   - `btc_to_return <= total_assets` (sufficient vault liquidity)
        ///   - vault holds enough liquid wBTC (not fully deployed to strategies)
        ///
        /// **State mutations (Effects):**
        ///   - `total_assets -= btc_to_return`
        ///   - `ybtc_total_supply -= ybtc_amount`
        ///   - yBTC burned from caller
        ///
        /// **External calls (Interactions):**
        ///   - `ybtc.burn(caller, ybtc_amount)` — reentrancy guard active
        ///   - `wbtc.transfer(caller, btc_to_return)` — reentrancy guard active
        ///
        /// **Emits:** `Withdrawal`
        /// **Invariants maintained:** I-1 through I-5
        fn withdraw(ref self: ContractState, ybtc_amount: u256) -> u256 {
            assert(!self.reentrancy_guard.read(), 'Reentrant call');
            self.reentrancy_guard.write(true);
            assert(!self.paused.read(), 'Vault paused');
            assert(ybtc_amount > 0, 'Zero withdrawal amount');
            let caller = get_caller_address();
            
            // Calculate BTC to return
            let btc_to_return = self._calculate_btc_for_shares(ybtc_amount);
            
            // Check if we have enough liquidity
            assert(btc_to_return <= self.total_assets.read(), 'Insufficient liquidity');
            
            // Burn yBTC from user
            let ybtc = IYBTCTokenDispatcher {
                contract_address: self.ybtc_address.read()
            };
            ybtc.burn(caller, ybtc_amount);
            
            // Ensure liquidity (may need to withdraw from strategies)
            self._ensure_liquidity(btc_to_return);
            
            // Push wBTC back to user
            let wbtc = IERC20Dispatcher { contract_address: self.wbtc_address.read() };
            let ok = wbtc.transfer(caller, btc_to_return);
            assert(ok, 'wBTC transfer failed');
            
            // Update state
            let new_total_assets = self.total_assets.read() - btc_to_return;
            self.total_assets.write(new_total_assets);
            
            let new_supply = self.ybtc_total_supply.read() - ybtc_amount;
            self.ybtc_total_supply.write(new_supply);
            
            // Report to router
            self._report_to_router();
            
            self.emit(Withdrawal {
                user: caller,
                ybtc_burned: ybtc_amount,
                amount_received: btc_to_return,
                timestamp: get_block_timestamp(),
            });

            self.reentrancy_guard.write(false);
            btc_to_return
        }

        // ===== Leverage Management =====

        fn apply_leverage(ref self: ContractState, target_leverage: u128) {
            assert(!self.reentrancy_guard.read(), 'Reentrant call');
            self.reentrancy_guard.write(true);
            assert(!self.paused.read(), 'Vault paused');
            let caller = get_caller_address();
            
            // Check with router for max allowed leverage.
            // IMPORTANT: use is_operation_allowed('leverage', ...) rather than calling
            // get_max_leverage() directly. The direct call bypasses the safe mode guard
            // inside is_operation_allowed — in safe mode is_operation_allowed returns false
            // for all non-withdraw/repay ops, but get_max_leverage() has no safe mode check
            // and would still return a non-zero tier value, letting leverage increase
            // through even when the system is in emergency lockdown.
            let router = IBTCSecurityRouterDispatcher {
                contract_address: self.router_address.read()
            };
            assert(
                router.is_operation_allowed('leverage', get_contract_address(), target_leverage.into()),
                'Router rejected leverage'
            );
            let max_leverage = router.get_max_leverage();
            assert(target_leverage <= max_leverage, 'Leverage exceeds max');
            assert(target_leverage >= 100, 'Leverage below 1.0');

            // ── User mode gate ─────────────────────────────────────────────────
            // Users in YieldOnly mode (1) cannot apply leverage.
            let u_mode = self.user_mode.read(caller);
            assert(u_mode != 1_u8, 'Mode: yield only, no leverage');

            // ── User's personal leverage cap ───────────────────────────────────
            // If the user set a custom cap, enforce it even if the system allows more.
            let custom_cap = self.user_custom_leverage_cap.read(caller);
            if custom_cap > 0 {
                assert(target_leverage <= custom_cap, 'Custom leverage cap exceeded');
            }

            // ── Per-transaction leverage increase limit ────────────────────────
            // Treat storage default 0 as 100 (1.0x base leverage for new users)
            let old_leverage = self.user_leverage.read(caller);
            let effective_old = if old_leverage == 0 { 100_u128 } else { old_leverage };
            assert(
                target_leverage <= effective_old + MAX_LEVERAGE_INCREASE_PER_TX,
                'Leverage increase too large'
            );
            
            // Execute leverage loop
            self._execute_leverage_loop(caller, target_leverage);
            
            self.user_leverage.write(caller, target_leverage);
            
            // Report to router
            self._report_to_router();
            
            self.emit(LeverageAdjusted {
                user: caller,
                old_leverage,
                new_leverage: target_leverage,
            });
            self.reentrancy_guard.write(false);
        }

        fn deleverage(ref self: ContractState) {
            // NOTE: the `paused` check is intentionally absent here.
            // In a crisis the vault is paused to block new deposits and leverage increases,
            // but users must always be able to reduce their own risk exposure.
            // Adding a pause guard would trap users in leveraged positions during an
            // emergency — the opposite of the intended safety behaviour (cf. L-6 in audit).
            let caller = get_caller_address();
            let current_leverage = self.user_leverage.read(caller);
            
            if current_leverage > 100 {
                // Repay debt and reduce leverage to 1.0
                self._execute_deleverage(caller);
                self.user_leverage.write(caller, 100);
                // I-6: reset user_mode to default (0 = Standard) now that the leveraged
                // position is fully closed. Without this reset, a user previously in
                // LeverageOnly mode (2) would re-open leverage on the next apply_leverage()
                // call without ever explicitly choosing a mode again.
                self.user_mode.write(caller, 0_u8);
                
                self.emit(LeverageAdjusted {
                    user: caller,
                    old_leverage: current_leverage,
                    new_leverage: 100,
                });
                
                // Report to router
                self._report_to_router();
            }
        }

        // ===== Strategy Management =====

        fn deploy_to_strategy(
            ref self: ContractState,
            strategy: ContractAddress,
            amount: u256
        ) {
            assert(!self.reentrancy_guard.read(), 'Reentrant call');
            self.reentrancy_guard.write(true);
            self._only_owner_or_role(ROLE_ADMIN);
            
            // Verify strategy is registered
            let strategy_info = self.strategies.read(strategy);
            assert(strategy_info.active, 'Strategy not active');

            // Over-deployment guard: committing more than the vault's undeployed
            // liquid balance would violate invariant I-2 (deployed_capital <= total_assets)
            // and leave the vault unable to process withdrawals.
            let available = self.total_assets.read() - self.deployed_capital.read();
            assert(amount <= available, 'Amount exceeds available');
            
            // Transfer wBTC to the strategy contract and deploy
            let wbtc = IERC20Dispatcher { contract_address: self.wbtc_address.read() };
            let ok = wbtc.transfer(strategy, amount);
            assert(ok, 'wBTC to strategy failed');
            let strat = IStrategyDispatcher { contract_address: strategy };
            strat.deploy(amount);

            // Update tracking
            let new_allocated = strategy_info.allocated_amount + amount;
            self.strategies.write(
                strategy,
                StrategyInfo {
                    strategy_address: strategy_info.strategy_address,
                    allocated_amount: new_allocated,
                    active: true,
                    risk_level: strategy_info.risk_level,
                }
            );
            
            let new_deployed = self.deployed_capital.read() + amount;
            self.deployed_capital.write(new_deployed);
            
            self.emit(StrategyDeployed {
                strategy,
                amount,
            });
            self.reentrancy_guard.write(false);
        }

        fn withdraw_from_strategy(
            ref self: ContractState,
            strategy: ContractAddress,
            amount: u256
        ) {
            assert(!self.reentrancy_guard.read(), 'Reentrant call');
            self.reentrancy_guard.write(true);
            self._only_owner_or_role(ROLE_ADMIN);
            
            // Withdraw from strategy — strategy sends wBTC back to vault and
            // returns the actual amount transferred (may include accrued yield).
            let strat = IStrategyDispatcher { contract_address: strategy };
            let returned = strat.withdraw(amount);

            // Update tracking
            let strategy_info = self.strategies.read(strategy);
            // Never underflow: deduct at most what was allocated
            let deduct = if amount <= strategy_info.allocated_amount {
                amount
            } else {
                strategy_info.allocated_amount
            };
            self.strategies.write(
                strategy,
                StrategyInfo {
                    strategy_address: strategy_info.strategy_address,
                    allocated_amount: strategy_info.allocated_amount - deduct,
                    active: strategy_info.active,
                    risk_level: strategy_info.risk_level,
                }
            );

            let cur_deployed = self.deployed_capital.read();
            self.deployed_capital.write(if deduct <= cur_deployed { cur_deployed - deduct } else { 0 });

            // Reconcile total_assets with the actual return from the strategy.
            if returned > amount {
                // Strategy returned more than requested — credit the surplus yield so
                // share price reflects the real gain immediately.
                let surplus = returned - amount;
                self.total_assets.write(self.total_assets.read() + surplus);
                // Credit the same surplus to accumulated_yield so proportional yield
                // distribution in _compute_claimable_yield() reflects the real gain.
                // This is the ONLY place accumulated_yield grows in production.
                self.accumulated_yield.write(self.accumulated_yield.read() + surplus);
                self.emit(YieldAccrued {
                    amount: surplus,
                    timestamp: get_block_timestamp(),
                });
            } else if returned < amount {
                // Strategy returned less than requested — realise the loss immediately
                // so share price falls to reflect reality.  Hiding this shortfall would
                // let early withdrawers drain the vault at later depositors' expense.
                let loss = amount - returned;
                let cur = self.total_assets.read();
                self.total_assets.write(if cur >= loss { cur - loss } else { 0 });
            }

            self.emit(StrategyWithdrawn {
                strategy,
                amount: returned,
            });
            self.reentrancy_guard.write(false);
        }

        // ===== View Functions =====

        fn get_user_position(
            self: @ContractState,
            user: ContractAddress
        ) -> (u256, u256, u128) {
            let ybtc = IYBTCTokenDispatcher {
                contract_address: self.ybtc_address.read()
            };
            let ybtc_balance = ybtc.balance_of(user);
            let btc_value = self._calculate_btc_for_shares(ybtc_balance);
            let leverage = self.user_leverage.read(user);
            
            (ybtc_balance, btc_value, leverage)
        }

        fn get_share_price(self: @ContractState) -> u256 {
            let total_assets = self.total_assets.read();
            let total_supply = self.ybtc_total_supply.read();
            
            if total_supply == 0 {
                return SCALE; // 1.0
            }
            
            (total_assets * SCALE) / total_supply
        }

        fn get_total_assets(self: @ContractState) -> u256 {
            self.total_assets.read()
        }

        fn get_total_debt(self: @ContractState) -> u256 {
            self.total_debt.read()
        }

        fn get_apy(self: @ContractState) -> u128 {
            // Simplified APY calculation
            // In production: calculate based on historical yield
            let deployed = self.deployed_capital.read();
            let total = self.total_assets.read();
            
            if total == 0 {
                return 0;
            }
            
            // Mock: 10% base APY
            let base_apy: u128 = 1000; // 10.00%
            
            // Adjust based on deployment ratio
            let deployment_ratio = (deployed * 100) / total;
            if deployment_ratio > 0xffffffffffffffffffffffffffffffff {
                return base_apy;
            }
            
            let ratio_u128: u128 = deployment_ratio.try_into().unwrap();
            (base_apy * ratio_u128) / 100
        }

        /// Return the cached BTC/USD price from the router's Pragma oracle feed.
        /// Price uses 8 decimal places (Pragma convention).
        /// Returns 0 when the router has no oracle configured or the price has
        /// never been refreshed.
        fn get_btc_usd_price(self: @ContractState) -> u128 {
            let router = IBTCSecurityRouterDispatcher {
                contract_address: self.router_address.read()
            };
            router.get_btc_usd_price()
        }

        // ===== Liquidation / Per-User Health =====

        /// Health factor scaled ×100.
        ///   h = (C_sat × P_8dec × LIQUIDATION_LTV × 100) / (D_usd8 × BTC_DECIMALS)
        /// Returns u128::MAX when the user has no leveraged debt.
        fn get_user_health(self: @ContractState, user: ContractAddress) -> u128 {
            let debt = self.user_debt.read(user);
            if debt == 0 {
                return 0xffffffffffffffffffffffffffffffff_u128; // no debt → infinite health
            }

            let ybtc = IYBTCTokenDispatcher {
                contract_address: self.ybtc_address.read()
            };
            let user_shares = ybtc.balance_of(user);
            let collateral_sat = self._calculate_btc_for_shares(user_shares); // satoshis

            if collateral_sat == 0 {
                return 0; // no collateral → fully underwater
            }

            let router = IBTCSecurityRouterDispatcher {
                contract_address: self.router_address.read()
            };
            let btc_price: u256 = router.get_btc_usd_price().into(); // 8-decimal USD price

            if btc_price == 0 {
                return 0xffffffffffffffffffffffffffffffff_u128; // no price → can't liquidate
            }

            // h = (C × P × λ) / (D × BTC_DECIMALS) — result is h×100 scale
            // where λ = LIQUIDATION_LTV (80 = 80%):
            //   h×100 = (C_sat × P_8dec × 80) / (D_8dec × BTC_DECIMALS)
            // e.g. 1 BTC @ $10k, D=$19k → (10^8 × 10^12 × 80)/(1.9×10^12 × 10^8) = 42
            //   → h = 0.42 → position liquidatable (below threshold of 100)
            let numerator = collateral_sat * btc_price * LIQUIDATION_LTV;
            let denominator = debt * BTC_DECIMALS;
            let h = numerator / denominator;
            if h > 0xffffffffffffffffffffffffffffffff {
                0xffffffffffffffffffffffffffffffff_u128
            } else {
                h.try_into().unwrap()
            }
        }

        /// Critical BTC/USD price below which this user becomes liquidatable.
        ///   P_crit = D × BTC_DECIMALS / (C_sat × LIQUIDATION_LTV / 100)
        /// Returns 0 when the user has no debt.
        fn get_liquidation_price(self: @ContractState, user: ContractAddress) -> u128 {
            let debt = self.user_debt.read(user);
            if debt == 0 {
                return 0;
            }

            let ybtc = IYBTCTokenDispatcher {
                contract_address: self.ybtc_address.read()
            };
            let user_shares = ybtc.balance_of(user);
            let collateral_sat = self._calculate_btc_for_shares(user_shares);

            if collateral_sat == 0 {
                return 0xffffffffffffffffffffffffffffffff_u128; // already insolvent
            }

            // P_crit = D * BTC_DECIMALS * 100 / (C * LIQUIDATION_LTV)
            let p_crit = (debt * BTC_DECIMALS * 100) / (collateral_sat * LIQUIDATION_LTV);
            if p_crit > 0xffffffffffffffffffffffffffffffff {
                0xffffffffffffffffffffffffffffffff_u128
            } else {
                p_crit.try_into().unwrap()
            }
        }

        /// True when the user's health factor ≤ 100 (at or below liquidation threshold).
        fn is_liquidatable(self: @ContractState, user: ContractAddress) -> bool {
            let debt = self.user_debt.read(user);
            if debt == 0 {
                return false;
            }
            let h = self.get_user_health(user);
            h <= HEALTH_DANGER
        }

        /// Liquidate an under-collateralised user's position.
        ///
        /// **Pre-conditions (Checks):**
        ///   - caller holds ROLE_LIQUIDATOR or is owner
        ///   - `is_liquidatable(user)` is true (health ≤ 100)
        ///   - user's yBTC balance > 0
        ///   - vault holds enough liquid wBTC to cover collateral + bonus
        ///
        /// **State mutations (Effects):**
        ///   - `user_debt[user]` cleared to 0
        ///   - `total_debt` reduced by user's debt
        ///   - `total_assets` reduced by `collateral_sat`
        ///   - `ybtc_total_supply` reduced by user's shares
        ///   - `user_leverage[user]` cleared to 0
        ///
        /// **External calls (Interactions):**
        ///   - `ybtc.burn(user, shares)` — reentrancy guard active
        ///   - `wbtc.transfer(liquidator, collateral + bonus)` — reentrancy guard active
        ///
        /// **Liquidation bonus:** `LIQUIDATION_BONUS_BPS = 5%` on top of seized collateral.
        /// The bonus is effectively socialised across all remaining depositors: `total_assets` is
        /// reduced by `collateral + bonus` while `ybtc_total_supply` falls by only the liquidated
        /// user's shares, so every surviving yBTC holder's share price decreases fractionally.
        /// This is the standard design for incentivised vault liquidations (cf. L-5 in audit).
        ///
        /// **Emits:** `PositionLiquidated`
        /// **Invariants maintained:** I-1, I-3, I-4, I-5  (I-2 maintained by _ensure_liquidity)
        fn liquidate(ref self: ContractState, user: ContractAddress) {
            assert(!self.reentrancy_guard.read(), 'Reentrant call');
            self.reentrancy_guard.write(true);

            self._only_owner_or_role(ROLE_LIQUIDATOR);
            // Prevent self-liquidation: a user who is their own liquidator would
            // receive the 5% bonus from vault reserves at other depositors' expense.
            let liquidator = get_caller_address();
            assert(liquidator != user, 'Cannot self-liquidate');
            assert(self.is_liquidatable(user), 'Position not liquidatable');

            // Resolve user's yBTC balance → collateral in satoshis
            let ybtc = IYBTCTokenDispatcher {
                contract_address: self.ybtc_address.read()
            };
            let user_shares = ybtc.balance_of(user);
            assert(user_shares > 0, 'No collateral to seize');

            let collateral_sat = self._calculate_btc_for_shares(user_shares);
            let debt_usd = self.user_debt.read(user);

            // Collateral to seize = collateral + bonus (5%)
            let bonus = (collateral_sat * LIQUIDATION_BONUS_BPS) / 100;
            let to_seize = collateral_sat + bonus;

            // Burn the user's yBTC shares
            ybtc.burn(user, user_shares);

            // Ensure the vault has enough liquid wBTC (including bonus)
            self._ensure_liquidity(to_seize);

            // Transfer wBTC (collateral + bonus) to the liquidator
            let wbtc = IERC20Dispatcher { contract_address: self.wbtc_address.read() };
            let ok = wbtc.transfer(liquidator, to_seize);
            assert(ok, 'wBTC to liquidator failed');

            // Update per-user debt and global debt
            let global_debt = self.total_debt.read();
            self.total_debt.write(
                if global_debt >= debt_usd { global_debt - debt_usd } else { 0 }
            );
            self.user_debt.write(user, 0);
            self.user_leverage.write(user, 0);

            // Update global asset and supply accounting.
            // Deduct the FULL wBTC outflow (collateral + bonus) from total_assets so
            // the accounting matches what physically left the vault.  The liquidation
            // bonus is borne by the liquidated user's own collateral position —
            // silently charging it to other depositors by under-deducting total_assets
            // would inflate every remaining share price at their expense.
            let current_assets = self.total_assets.read();
            self.total_assets.write(
                if current_assets >= to_seize { current_assets - to_seize } else { 0 }
            );

            let current_supply = self.ybtc_total_supply.read();
            self.ybtc_total_supply.write(
                if current_supply >= user_shares { current_supply - user_shares } else { 0 }
            );

            // Report updated exposure to the router
            self._report_to_router();

            self.emit(PositionLiquidated {
                liquidator,
                user,
                collateral_seized: to_seize,
                debt_cleared: debt_usd,
                timestamp: get_block_timestamp(),
            });

            self.reentrancy_guard.write(false);
        }

        // ===== Admin Functions =====

        fn pause(ref self: ContractState) {
            self._only_owner_or_role(ROLE_GUARDIAN);
            self.paused.write(true);
            self.emit(Paused {
                timestamp: get_block_timestamp(),
            });
        }

        fn unpause(ref self: ContractState) {
            self._only_owner();
            self.paused.write(false);
            self.emit(Unpaused {
                timestamp: get_block_timestamp(),
            });
        }

        fn set_router(ref self: ContractState, op_id: felt252, router: ContractAddress) {
            self._only_owner_or_role(ROLE_ADMIN);
            let expected = compute_op_id('set_router', array![router.into()].span());
            assert(op_id == expected, 'Op id mismatch');
            self._check_timelock(op_id);
            assert(!router.is_zero(), 'Router is zero address');
            self.router_address.write(router);
        }

        fn set_minimum_deposit_timelocked(ref self: ContractState, op_id: felt252, minimum: u256) {
            self._only_owner_or_role(ROLE_ADMIN);
            let expected = compute_op_id(
                'set_min_deposit',
                array![minimum.low.into(), minimum.high.into()].span()
            );
            assert(op_id == expected, 'Op id mismatch');
            self._check_timelock(op_id);
            assert(minimum > 0, 'Minimum must be positive');
            self.minimum_deposit.write(minimum);
        }

        // ── Strategy registration (ABI-exposed so tests and integrations can call it) ──
        fn register_strategy(ref self: ContractState, strategy: ContractAddress, risk_level: u8) {
            self._only_owner_or_role(ROLE_ADMIN);
            // Guard 1: zero address would silently poison the strategy_addresses index,
            // causing _ensure_liquidity to call a zero-address strategy and panic.
            assert(!strategy.is_zero(), 'Strategy is zero address');
            // Guard 2: prevent duplicate registration.  A second call for the same
            // address appends it twice to strategy_addresses and increments
            // strategy_count twice, making _ensure_liquidity withdraw from the same
            // strategy twice in one pass (double-withdraw bug).
            assert(
                self.strategies.read(strategy).strategy_address.is_zero(),
                'Strategy already registered'
            );
            self.strategies.write(strategy, StrategyInfo {
                strategy_address: strategy,
                allocated_amount: 0,
                active: true,
                risk_level,
            });
            let count = self.strategy_count.read();
            self.strategy_addresses.write(count, strategy);
            self.strategy_count.write(count + 1);
        }

        // ── Yield accrual trigger (ABI-exposed so keepers and tests can call it) ────────
        fn trigger_yield_accrual(ref self: ContractState) {
            self._only_owner_or_role(ROLE_KEEPER);
            self._accrue_yield();
        }

        // ─────────────────────────────────────────────────────────────────────
        // User Mode & Preference Functions
        // ─────────────────────────────────────────────────────────────────────

        /// Configure the caller's operating mode and personal risk parameters.
        ///
        /// **Rules:**
        ///   - YieldOnly (1) or Combined (3): `yield_strategy` must be an active registered strategy.
        ///   - Combined (3): always requires `accept_warning = true`.
        ///   - `custom_leverage_cap > 0 && cap > recommended`: requires `accept_warning = true`.
        ///   - `custom_leverage_cap` cannot exceed the system's absolute max leverage.
        ///
        /// **Emits:** `UserModeSet`
        fn set_user_mode(
            ref self: ContractState,
            mode: UserMode,
            yield_strategy: ContractAddress,
            custom_leverage_cap: u128,
            custom_yield_bps: u16,
            accept_warning: bool,
        ) {
            assert(!self.paused.read(), 'Vault paused');
            let caller = get_caller_address();

            // Convert enum → u8 for storage
            let mode_u8: u8 = match mode {
                UserMode::None => 0_u8,
                UserMode::YieldOnly => 1_u8,
                UserMode::LeverageOnly => 2_u8,
                UserMode::Combined => 3_u8,
            };

            // Combined mode is inherently high-risk — require explicit warning acceptance
            // NOTE: check this BEFORE strategy validation so the correct panic fires when
            // accept_warning=false, regardless of whether the strategy is registered.
            if mode_u8 == 3_u8 {
                assert(accept_warning, 'Combined mode needs warning');
            }

            // Validate yield strategy when mode requires yield
            if mode_u8 == 1_u8 || mode_u8 == 3_u8 {
                assert(!yield_strategy.is_zero(), 'Yield strategy required');
                let sinfo = self.strategies.read(yield_strategy);
                assert(sinfo.active, 'Strategy not active');
            }

            // Validate custom leverage cap
            if custom_leverage_cap > 0 {
                let router = IBTCSecurityRouterDispatcher {
                    contract_address: self.router_address.read()
                };
                let sys_max = router.get_max_leverage();
                assert(custom_leverage_cap <= sys_max, 'Custom cap exceeds system max');

                // Warn if user sets a cap above protocol recommendation
                let rec = self._recommended_leverage_for(caller);
                if custom_leverage_cap > rec {
                    assert(accept_warning, 'Warning required for custom cap');
                }
            }

            // Persist preferences
            self.user_mode.write(caller, mode_u8);
            self.user_yield_strategy.write(caller, yield_strategy);
            self.user_custom_leverage_cap.write(caller, custom_leverage_cap);
            self.user_custom_yield_bps.write(caller, custom_yield_bps);
            self.user_warning_accepted.write(caller, accept_warning);

            self.emit(UserModeSet {
                user: caller,
                mode: mode_u8,
                yield_strategy,
                custom_leverage_cap,
                custom_yield_bps,
                warning_accepted: accept_warning,
                timestamp: get_block_timestamp(),
            });
        }

        /// Returns a comprehensive snapshot of everything about the user's position.
        /// Single on-chain call designed to power a complete frontend dashboard page.
        fn get_user_dashboard(
            self: @ContractState,
            user: ContractAddress,
        ) -> UserDashboard {
            let ybtc = IYBTCTokenDispatcher { contract_address: self.ybtc_address.read() };
            let ybtc_balance = ybtc.balance_of(user);
            let btc_value_sat = self._calculate_btc_for_shares(ybtc_balance);

            let router = IBTCSecurityRouterDispatcher {
                contract_address: self.router_address.read()
            };
            let oracle_price: u128 = router.get_btc_usd_price();
            let price_is_fresh = router.is_price_fresh();
            let is_safe_mode = router.is_safe_mode();

            // USD value of the user's BTC position
            let btc_value_usd: u256 = if oracle_price > 0 && price_is_fresh {
                (btc_value_sat * oracle_price.into()) / BTC_DECIMALS
            } else {
                0_u256
            };

            let current_leverage = self.user_leverage.read(user);
            let user_debt_usd = self.user_debt.read(user);
            let health_factor = self.get_user_health(user);
            let liquidation_price_usd = self.get_liquidation_price(user);

            let claimable_yield_sat = self._compute_claimable_yield(user);

            // Decode stored u8 back to UserMode enum
            let mode_u8 = self.user_mode.read(user);
            let mode_enum: UserMode = if mode_u8 == 1_u8 {
                UserMode::YieldOnly
            } else if mode_u8 == 2_u8 {
                UserMode::LeverageOnly
            } else if mode_u8 == 3_u8 {
                UserMode::Combined
            } else {
                UserMode::None
            };

            let can_deposit = router.is_operation_allowed(
                'deposit', get_contract_address(), 1_u256
            );
            let can_leverage = router.is_operation_allowed(
                'leverage', get_contract_address(), 100_u256
            );

            let recommended_leverage = self._recommended_leverage_for(user);
            let recommended_strategy = self._best_strategy_address();

            UserDashboard {
                ybtc_balance,
                btc_value_sat,
                btc_value_usd,
                current_leverage,
                user_debt_usd,
                health_factor,
                liquidation_price_usd,
                claimable_yield_sat,
                yield_strategy: self.user_yield_strategy.read(user),
                mode: mode_enum,
                custom_leverage_cap: self.user_custom_leverage_cap.read(user),
                custom_yield_bps: self.user_custom_yield_bps.read(user),
                warning_accepted: self.user_warning_accepted.read(user),
                deposit_timestamp: self.user_deposit_timestamp.read(user),
                share_price: self.get_share_price(),
                vault_apy: self.get_apy(),
                price_is_fresh,
                is_safe_mode,
                recommended_leverage,
                recommended_strategy,
                can_deposit,
                can_leverage,
            }
        }

        /// How much wBTC yield (satoshis) the user can claim right now.
        /// Proportional to the user's share of total yBTC supply since their last claim.
        fn get_user_claimable_yield(self: @ContractState, user: ContractAddress) -> u256 {
            self._compute_claimable_yield(user)
        }

        /// Transfer the caller's claimable yield as wBTC to their wallet.
        ///
        /// **Pre-conditions:** vault not paused, claimable > 0.
        /// **State mutations:** updates yield snapshot, reduces total_assets by amount.
        /// **Emits:** `YieldClaimed`
        fn claim_yield(ref self: ContractState) {
            assert(!self.reentrancy_guard.read(), 'Reentrant call');
            self.reentrancy_guard.write(true);
            assert(!self.paused.read(), 'Vault paused');

            let caller = get_caller_address();
            let claimable = self._compute_claimable_yield(caller);
            assert(claimable > 0, 'Nothing to claim');

            // Advance the snapshot so this yield cannot be claimed twice.
            // We snapshot to accumulated_yield at claim time, not to accumulated_yield
            // at deposit time, because yield can accrue between deposits.
            self.user_yield_snapshot.write(caller, self.accumulated_yield.read());

            // Ensure liquid wBTC is available for the payout.
            // This may recall capital from strategies if the vault is fully deployed.
            self._ensure_liquidity(claimable);

            // Reduce total_assets BEFORE the transfer (CEI order).
            // Real wBTC is physically leaving the vault, so total_assets must reflect
            // the outflow — otherwise share price stays artificially inflated and later
            // withdrawals will be under-collateralised.
            let cur_assets = self.total_assets.read();
            self.total_assets.write(if cur_assets >= claimable { cur_assets - claimable } else { 0 });

            // Transfer wBTC yield to user.
            let wbtc = IERC20Dispatcher { contract_address: self.wbtc_address.read() };
            let ok = wbtc.transfer(caller, claimable);
            assert(ok, 'wBTC yield transfer failed');

            self.emit(YieldClaimed {
                user: caller,
                amount_sat: claimable,
                timestamp: get_block_timestamp(),
            });

            self.reentrancy_guard.write(false);
        }

        /// Protocol-recommended safe leverage cap for a user.
        /// Uses the user's health factor to suggest a conservative ceiling:
        ///   - health >= SAFE (150)  → suggest up to 130 (1.3x)
        ///   - health >= WARNING (120) → suggest up to 115 (1.15x)
        ///   - otherwise             → suggest 100 (1.0x, no leverage)
        /// Always capped by the system max leverage from the router.
        fn get_recommended_leverage(self: @ContractState, user: ContractAddress) -> u128 {
            self._recommended_leverage_for(user)
        }

        /// Address of the lowest-risk (smallest risk_level) active strategy.
        /// Returns zero address when no strategy is registered.
        fn get_recommended_strategy(self: @ContractState) -> ContractAddress {
            self._best_strategy_address()
        }
    }

    // =====================================
    // Internal Functions
    // =====================================

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn _only_owner(self: @ContractState) {
            let caller = get_caller_address();
            assert(caller == self.owner.read(), 'Only owner');
        }

        fn _only_owner_or_role(self: @ContractState, role: felt252) {
            let caller = get_caller_address();
            assert(
                caller == self.owner.read() || self.roles.read((role, caller)),
                'Unauthorized'
            );
        }

        /// Authorisation check for grant_role / revoke_role.
        /// Owner may manage any role.
        /// Non-owners must hold the role's admin-role (get_role_admin);
        /// a zero admin-role means owner-only.
        fn _check_can_manage_role(self: @ContractState, caller: ContractAddress, role: felt252) {
            if caller != self.owner.read() {
                let admin_role = self.role_admin.read(role);
                assert(admin_role != 0, 'Only owner can grant this role');
                assert(self.roles.read((admin_role, caller)), 'Unauthorized');
            }
        }

        fn _check_timelock(ref self: ContractState, op_id: felt252) {
            let eta = self.timelock_queue.read(op_id);
            assert(eta != 0, 'Op not queued');
            let now = get_block_timestamp();
            assert(now >= eta, 'Timelock not expired');
            assert(now <= eta + GRACE_PERIOD, 'Operation expired');
            self.timelock_queue.write(op_id, 0); // consume — cannot replay
            self.emit(OperationExecuted {
                op_id,
                timestamp: now,
            });
        }

        fn _calculate_shares_to_mint(self: @ContractState, amount: u256) -> u256 {
            let total_assets = self.total_assets.read();
            let total_supply = self.ybtc_total_supply.read();
            
            if total_supply == 0 {
                // First deposit: 1:1 ratio
                return amount;
            }
            
            // shares = amount * supply / assets
            (amount * total_supply) / total_assets
        }

        fn _calculate_btc_for_shares(self: @ContractState, shares: u256) -> u256 {
            let total_assets = self.total_assets.read();
            let total_supply = self.ybtc_total_supply.read();
            
            if total_supply == 0 {
                return 0;
            }
            
            // btc = shares * assets / supply
            (shares * total_assets) / total_supply
        }

        fn _execute_leverage_loop(
            ref self: ContractState,
            user: ContractAddress,
            target_leverage: u128
        ) {
            // BUG-FIX 1: use the caller's *own* collateral share, not global total_assets.
            // Without this, Alice borrowing at 1.2x would create debt proportional to
            // the entire vault (Alice + Bob + …), massively over-stating her USD debt.
            let ybtc = IYBTCTokenDispatcher { contract_address: self.ybtc_address.read() };
            let user_shares = ybtc.balance_of(user);
            let user_collateral = self._calculate_btc_for_shares(user_shares); // satoshis

            // BUG-FIX 2: only the INCREMENTAL leverage increase creates new debt.
            // Going 1.0x → 1.2x adds 0.2x debt; going 1.2x → 1.3x adds only 0.1x.
            // Using (target - 100) as the factor would re-add the full 0.2x on every
            // repeated call, doubling debt each time with no position change.
            let stored_leverage = self.user_leverage.read(user);
            let effective_old: u128 = if stored_leverage == 0 { 100_u128 } else { stored_leverage };

            // Nothing to borrow if the target is at or below the current level.
            // Callers should use deleverage() to reduce an open position.
            if target_leverage <= effective_old {
                return;
            }

            let delta_factor: u256 = (target_leverage - effective_old).into();

            // Fetch the cached BTC/USD price from the router's oracle (Pragma, 8 decimals).
            // Example: BTC @ $95,000  →  btc_usd_price = 9_500_000_000_000
            let router = IBTCSecurityRouterDispatcher {
                contract_address: self.router_address.read()
            };
            let btc_usd_price: u256 = router.get_btc_usd_price().into();

            // A zero price means the oracle is unconfigured or the cached price has expired.
            // When no price is available, skip debt accrual rather than blocking the whole
            // transaction: leverage metadata (user_leverage) is still recorded by the caller.
            // This is safe because zero-debt leverage creates no systemic risk; when the oracle
            // becomes available, the next leverage adjustment will accrue the correct incremental debt.
            if btc_usd_price == 0 {
                return;
            }

            // USD debt for the incremental leverage step (8 decimal places):
            //   additional_debt = user_collateral_sat × price_8dec × delta_factor
            //                     ───────────────────────────────────────────────
            //                                  BTC_DECIMALS × 100
            //
            // Example — 1 BTC @ $95k, going 1.0x → 1.2x (delta = 20):
            //   100_000_000 × 9_500_000_000_000 × 20
            //   ──────────────────────────────────── = 1_900_000_000_000  ($19,000.00)
            //              100_000_000 × 100
            let denom: u256 = BTC_DECIMALS * 100; // 10^8 × 100 = 10^10
            let additional_debt: u256 = (user_collateral * btc_usd_price * delta_factor) / denom;

            // Update global and per-user debt atomically.
            self.total_debt.write(self.total_debt.read() + additional_debt);
            let old_user_debt = self.user_debt.read(user);
            self.user_debt.write(user, old_user_debt + additional_debt);
        }

        fn _execute_deleverage(ref self: ContractState, user: ContractAddress) {
            // Only clear the debt that belongs to this user.
            // Subtract from the global total so the invariant total_debt == Σ user_debt holds.
            let user_debt_amount = self.user_debt.read(user);
            if user_debt_amount > 0 {
                let global = self.total_debt.read();
                self.total_debt.write(
                    if global >= user_debt_amount { global - user_debt_amount } else { 0 }
                );
                self.user_debt.write(user, 0);
            }
        }

        fn _ensure_liquidity(ref self: ContractState, amount: u256) {
            let wbtc = IERC20Dispatcher { contract_address: self.wbtc_address.read() };
            let liquid = wbtc.balance_of(get_contract_address());
            if liquid >= amount {
                return; // Already have sufficient liquid wBTC — no recall needed
            }

            // Auto-recall from strategies to cover the shortfall.
            // Iterates strategy_addresses[0..strategy_count-1] and withdraws the
            // minimum from each active strategy (in registration order) until the
            // shortfall is covered or all strategies are exhausted.
            let shortfall = amount - liquid;
            let count = self.strategy_count.read();
            let mut i: u32 = 0;
            let mut recalled: u256 = 0;
            while recalled < shortfall && i < count {
                let addr = self.strategy_addresses.read(i);
                if !addr.is_zero() {
                    let info = self.strategies.read(addr);
                    if info.active && info.allocated_amount > 0 {
                        let remaining = shortfall - recalled;
                        let to_recall = if info.allocated_amount >= remaining {
                            remaining
                        } else {
                            info.allocated_amount
                        };
                        let strat = IStrategyDispatcher { contract_address: addr };
                        let returned = strat.withdraw(to_recall);

                        // Update strategy allocation tracking
                        let deduct = if to_recall <= info.allocated_amount {
                            to_recall
                        } else {
                            info.allocated_amount
                        };
                        self.strategies.write(addr, StrategyInfo {
                            strategy_address: info.strategy_address,
                            allocated_amount: info.allocated_amount - deduct,
                            active: info.active,
                            risk_level: info.risk_level,
                        });
                        let cur_deployed = self.deployed_capital.read();
                        self.deployed_capital.write(
                            if deduct <= cur_deployed { cur_deployed - deduct } else { 0 }
                        );

                        // Reconcile total_assets: credit gains, realise losses immediately
                        if returned > to_recall {
                            self.total_assets.write(
                                self.total_assets.read() + (returned - to_recall)
                            );
                        } else if returned < to_recall {
                            let loss = to_recall - returned;
                            let cur = self.total_assets.read();
                            self.total_assets.write(if cur >= loss { cur - loss } else { 0 });
                        }

                        recalled += returned;
                        self.emit(StrategyWithdrawn { strategy: addr, amount: returned });
                    }
                }
                i += 1;
            };

            // Final hard check after all strategy recalls
            let final_liquid = wbtc.balance_of(get_contract_address());
            assert(final_liquid >= amount, 'Insufficient liquid wBTC');
        }

        fn _report_to_router(ref self: ContractState) {
            let router = IBTCSecurityRouterDispatcher {
                contract_address: self.router_address.read()
            };
            
            let collateral = self.total_assets.read();
            let debt = self.total_debt.read();
            
            // Calculate average leverage (simplified)
            let leverage: u128 = if collateral > 0 {
                let total_exposure = collateral + debt;
                let lev_256 = (total_exposure * 100) / collateral;
                if lev_256 > 0xffffffffffffffffffffffffffffffff {
                    200 // Cap at 2.0x
                } else {
                    lev_256.try_into().unwrap()
                }
            } else {
                100
            };
            
            router.report_exposure(collateral, debt, leverage);
        }

        fn _accrue_yield(ref self: ContractState) {
            // Synthetic time-based yield accrual has been intentionally removed.
            //
            // Rationale: computing a phantom APY percentage and adding it to
            // `accumulated_yield` creates yield that is not backed by real wBTC.
            // If users then call `claim_yield()`, the vault transfers real wBTC that
            // was deposited by OTHER users, effectively stealing from depositors.
            //
            // Real yield accounting path:
            //   1. Deploy capital to a strategy via `deploy_to_strategy()`.
            //   2. When the strategy earns yield, call `withdraw_from_strategy()`.
            //   3. If the strategy returns more than was requested (returned > amount),
            //      `withdraw_from_strategy()` credits the surplus to BOTH `total_assets`
            //      (so share price reflects the real gain) AND `accumulated_yield`
            //      (so `_compute_claimable_yield()` distributes it proportionally).
            //   4. Users then call `claim_yield()` to receive their proportional share.
            //
            // This function is kept (callable by KEEPER via `trigger_yield_accrual`)
            // to maintain ABI compatibility but is a deliberate no-op.
            self.last_yield_update.write(get_block_timestamp());
        }

        // ─────────────────────────────────────────────────────────────────────
        // Formal invariant checker
        // ─────────────────────────────────────────────────────────────────────

        /// Verify all system invariants in a single pass.
        ///
        /// Panics with a descriptive message at the first violation.
        ///
        /// **USAGE**
        ///   - Call in test/fuzz builds after every state-changing external function.
        ///   - Do NOT embed in production code paths (adds unnecessary gas overhead).
        ///
        /// **Invariants checked:**
        ///   I-1  owner ≠ 0
        ///   I-2  deployed_capital ≤ total_assets
        ///   I-3  minimum_deposit > 0
        ///   I-4  ybtc_total_supply > 0  ⟹  total_assets > 0
        ///   I-5  reentrancy_guard = false
        // ─────────────────────────────────────────────────────────────────────
        // User yield + recommendation helpers
        // ─────────────────────────────────────────────────────────────────────

        /// Compute the amount of wBTC yield claimable by `user`.
        /// Formula: claimable = (accumulated_yield - snapshot) * user_shares / total_supply
        /// A snapshot of 0 is treated as accumulated_yield at deposit time if that is also 0,
        /// which is correct for users who deposited before any yield accrued.
        fn _compute_claimable_yield(self: @ContractState, user: ContractAddress) -> u256 {
            let total_yield = self.accumulated_yield.read();
            let snapshot = self.user_yield_snapshot.read(user);
            // If the vault yield has not moved past the user's snapshot, nothing to claim.
            if total_yield <= snapshot {
                return 0_u256;
            }
            let earned_since = total_yield - snapshot;

            let ybtc = IYBTCTokenDispatcher { contract_address: self.ybtc_address.read() };
            let user_shares = ybtc.balance_of(user);
            if user_shares == 0 {
                return 0_u256;
            }
            let total_supply = self.ybtc_total_supply.read();
            if total_supply == 0 {
                return 0_u256;
            }
            (earned_since * user_shares) / total_supply
        }

        /// Internal recommended leverage calculation (shared by view and set_user_mode).
        fn _recommended_leverage_for(self: @ContractState, user: ContractAddress) -> u128 {
            let router = IBTCSecurityRouterDispatcher {
                contract_address: self.router_address.read()
            };
            let sys_max = router.get_max_leverage();
            let health = self.get_user_health(user);
            let rec: u128 = if health >= HEALTH_SAFE {
                130_u128  // 1.3x — comfortable
            } else if health >= HEALTH_WARNING {
                115_u128  // 1.15x — cautious
            } else {
                100_u128  // 1.0x — no leverage recommended
            };
            // Never suggest more than what the router currently allows
            if rec <= sys_max { rec } else { sys_max }
        }

        /// Walk all registered strategies and return the address of the one with the
        /// lowest risk_level that is currently active.  Returns zero if none registered.
        fn _best_strategy_address(self: @ContractState) -> ContractAddress {
            let count = self.strategy_count.read();
            let zero: ContractAddress = core::num::traits::Zero::zero();
            if count == 0 {
                return zero;
            }
            let mut best_addr: ContractAddress = zero;
            let mut best_risk: u8 = 0xff_u8;
            let mut i: u32 = 0;
            while i < count {
                let addr = self.strategy_addresses.read(i);
                if !addr.is_zero() {
                    let info = self.strategies.read(addr);
                    if info.active && info.risk_level < best_risk {
                        best_risk = info.risk_level;
                        best_addr = addr;
                    }
                }
                i += 1;
            };
            best_addr
        }

        fn _assert_vault_invariants(self: @ContractState) {
            // I-1: owner is always a valid non-zero address
            assert(!self.owner.read().is_zero(), 'INV: owner is zero');

            // I-2: deployed capital never exceeds what the vault holds
            //      Violation → vault has committed more capital than it owns.
            assert(
                self.deployed_capital.read() <= self.total_assets.read(),
                'INV: deployed > assets'
            );

            // I-3: minimum deposit must remain positive
            //      (constructor sets 1_000_000; timelocked change enforces minimum > 0)
            assert(self.minimum_deposit.read() > 0, 'INV: min_deposit is zero');

            // I-4: no yBTC supply without corresponding assets (phantom-supply guard)
            //      Violation → yBTC holders hold claims against an empty vault.
            if self.ybtc_total_supply.read() > 0 {
                assert(self.total_assets.read() > 0, 'INV: supply without assets');
            }

            // I-5: reentrancy guard must be released between external calls
            //      A stuck guard permanently bricks all vault entry points.
            assert(!self.reentrancy_guard.read(), 'INV: reentrancy stuck');
        }
    }

    // =====================================
    // Additional Admin Functions
    // =====================================

    #[generate_trait]
    impl AdminImpl of AdminTrait {
        fn deactivate_strategy(ref self: ContractState, strategy: ContractAddress) {
            self._only_owner_or_role(ROLE_ADMIN);

            let strategy_info = self.strategies.read(strategy);
            assert(strategy_info.active, 'Strategy not active');
            // Guard: refuse to deactivate a strategy that still holds vault capital.
            // Marking it inactive while allocated_amount > 0 silently excludes those
            // funds from _ensure_liquidity recall loops, stranding wBTC in the strategy
            // and making deployed_capital permanently higher than recoverable capital.
            // Call withdraw_from_strategy() first to fully recall before deactivating.
            assert(
                strategy_info.allocated_amount == 0,
                'Recall capital first'
            );
            self.strategies.write(strategy, StrategyInfo {
                strategy_address: strategy_info.strategy_address,
                allocated_amount: strategy_info.allocated_amount,
                active: false,
                risk_level: strategy_info.risk_level,
            });
        }
        // The non-timelocked set_minimum_deposit() emergency path has been removed.
        // All minimum-deposit changes must now go through set_minimum_deposit_timelocked()
        // (owner or ADMIN + 2-day timelock queue) to prevent unilateral silent changes.
        // See L-7 in SECURITY_AUDIT.md for the original finding.
    }
}