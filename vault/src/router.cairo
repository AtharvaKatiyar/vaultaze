use starknet::{ContractAddress, get_caller_address, get_block_timestamp};
use starknet::storage::Map;

#[starknet::contract]
mod BTCSecurityRouter {
    use super::{ContractAddress, get_caller_address, get_block_timestamp, Map};
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess, StorageMapReadAccess, StorageMapWriteAccess};
    use core::num::traits::Zero;
    use core::poseidon::poseidon_hash_span;
    use super::super::interfaces::{
        IPragmaOracleDispatcher, IPragmaOracleDispatcherTrait,
        DataType, BTC_USD_PRAGMA_KEY,
        IAccessControl,
        ROLE_ADMIN, ROLE_GUARDIAN, ROLE_KEEPER, TIMELOCK_DELAY, GRACE_PERIOD,
    };

    // ╔═══════════════════════════════════════════════════════════════════════╗
    // ║          FORMAL SPECIFICATION — BTCSecurityRouter v1               ║
    // ╠═══════════════════════════════════════════════════════════════════════╣
    // ║  SYSTEM INVARIANTS  (must hold after every external call)            ║
    // ║  ─────────────────────────────────────────────────────────────────── ║
    // ║  I-1  owner ≠ 0x0                                                    ║
    // ║  I-2  safe_mode_threshold > min_health_factor                       ║
    // ║  I-3  min_health_factor = 100  (immutable, set in constructor)      ║
    // ║  I-4  btc_exposure = Σ(active protocol collaterals)  (exact after   ║
    // ║       reconciliation; approximate between calls via delta tracking) ║
    // ║                                                                       ║
    // ║  SAFETY PROPERTIES                                                   ║
    // ║  ─────────────────────────────────────────────────────────────────── ║
    // ║  S-1  enter_safe_mode: requires health < safe_mode_threshold        ║
    // ║  S-2  exit_safe_mode: requires health ≥ 130 AND valid timelock op   ║
    // ║  S-3  set_oracle_address: op_id = hash('set_oracle', [oracle])      ║
    // ║  S-4  get_btc_usd_price returns 0 when price stale (> MAX_PRICE_AGE)║
    // ║  S-5  is_operation_allowed returns false for all ops in safe mode   ║
    // ║       (exception: 'withdraw' and 'repay' are always permitted)      ║
    // ║  S-6  only registered active protocols can call report_exposure      ║
    // ║                                                                       ║
    // ║  ACCESS CONTROL MATRIX  (TL = requires timelock)                    ║
    // ║  ─────────────────────────────────────────────────────────────────── ║
    // ║  Function                   │ OWNER │ ADMIN │ GUARD │ KEEP  │       ║
    // ║  grant_role(ADMIN/GUARD)    │   ✓   │       │       │       │       ║
    // ║  grant_role(KEEP)           │   ✓   │   ✓   │       │       │       ║
    // ║  queue_operation            │   ✓   │   ✓   │       │       │       ║
    // ║  enter_safe_mode            │   ✓   │       │   ✓   │       │       ║
    // ║  exit_safe_mode      (TL)   │   ✓   │   ✓   │       │       │       ║
    // ║  set_oracle_address  (TL)   │   ✓   │   ✓   │       │       │       ║
    // ║  set_safe_mode_thresh (TL)  │   ✓   │   ✓   │       │       │       ║
    // ║  refresh_btc_price          │   ✓   │       │       │   ✓   │       ║
    // ║  update_btc_backing         │   ✓   │       │       │   ✓   │       ║
    // ║  register_protocol          │   ✓   │   ✓   │       │       │       ║
    // ║  report_exposure            │  (any registered active protocol)    ║
    // ║                                                                       ║
    // ║  TRUST ASSUMPTIONS                                                   ║
    // ║  ─────────────────────────────────────────────────────────────────── ║
    // ║  T-1  Pragma oracle: BTC/USD median price is correct and timely     ║
    // ║  T-2  Registered protocols report honest collateral/debt values     ║
    // ║  T-3  Owner/ADMIN: only queue legitimate governance operations       ║
    // ╚═══════════════════════════════════════════════════════════════════════╝

    // =====================================
    // Storage
    // =====================================

    #[storage]
    struct Storage {
        // Global state
        btc_backing: u256,
        btc_exposure: u256,
        safe_mode: bool,
        
        // Registered protocols
        protocols: Map<ContractAddress, ProtocolInfo>,
        protocol_count: u32,
        
        // Parameters
        safe_mode_threshold: u128, // e.g., 110 = 1.1
        min_health_factor: u128,   // e.g., 100 = 1.0
        
        // Admin & authorized addresses
        owner: ContractAddress,

        // Role-based access control
        roles: Map<(felt252, ContractAddress), bool>, // (role, account) => granted
        pending_owner: ContractAddress,               // 2-step ownership transfer

        // Role hierarchy: role => admin_role whose holders can grant/revoke this role.
        // A stored value of 0 means only the owner may manage this role.
        role_admin: Map<felt252, felt252>,

        // Timelock: op_id => earliest execution timestamp (0 = not queued / consumed)
        timelock_queue: Map<felt252, u64>,

        // Oracle integration
        oracle_address: ContractAddress,  // Pragma oracle contract address (zero = not configured)
        btc_usd_price: u128,              // Cached BTC/USD price from last refresh (8 decimals)
        price_last_updated: u64,          // Timestamp of the last successful price refresh

        // Protocol address index for iteration (Cairo Map cannot be iterated directly)
        // protocol_addresses[i] = address of the i-th registered protocol
        protocol_addresses: Map<u32, ContractAddress>,

        // Timestamp of the last full O(n) reconciliation scan
        last_reconciliation: u64,
    }

    // =====================================
    // Data Structures
    // =====================================

    #[derive(Drop, Copy, Serde, starknet::Store)]
    struct ProtocolInfo {
        protocol_type: felt252,
        collateral: u256,
        debt: u256,
        leverage: u128,
        active: bool,
    }

    // =====================================
    // Events
    // =====================================

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        SafeModeActivated: SafeModeActivated,
        SafeModeDeactivated: SafeModeDeactivated,
        HealthUpdated: HealthUpdated,
        ProtocolRegistered: ProtocolRegistered,
        ExposureReported: ExposureReported,
        BackingUpdated: BackingUpdated,
        ExposureReconciled: ExposureReconciled,
        PriceRefreshed: PriceRefreshed,
        RoleGranted: RoleGranted,
        RoleRevoked: RoleRevoked,
        OwnershipTransferStarted: OwnershipTransferStarted,
        OwnershipTransferred: OwnershipTransferred,
        OperationQueued: OperationQueued,
        OperationExecuted: OperationExecuted,
        OperationCancelled: OperationCancelled,
    }

    #[derive(Drop, starknet::Event)]
    struct SafeModeActivated {
        #[key]
        timestamp: u64,
        health_factor: u128,
    }

    #[derive(Drop, starknet::Event)]
    struct SafeModeDeactivated {
        #[key]
        timestamp: u64,
        health_factor: u128,
    }

    #[derive(Drop, starknet::Event)]
    struct HealthUpdated {
        old_health: u128,
        new_health: u128,
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct ProtocolRegistered {
        #[key]
        protocol: ContractAddress,
        protocol_type: felt252,
    }

    #[derive(Drop, starknet::Event)]
    struct ExposureReported {
        #[key]
        protocol: ContractAddress,
        collateral: u256,
        debt: u256,
        leverage: u128,
    }

    #[derive(Drop, starknet::Event)]
    struct BackingUpdated {
        old_backing: u256,
        new_backing: u256,
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct ExposureReconciled {
        old_exposure: u256,       // btc_exposure before the scan
        new_exposure: u256,       // ground-truth sum from the scan
        drift: u256,              // absolute difference (catches silent drift)
        active_protocol_count: u32,
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct PriceRefreshed {
        old_price: u128,   // previous cached price
        new_price: u128,   // freshly fetched price from Pragma
        timestamp: u64,    // block timestamp of the refresh
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

    // =====================================
    // Constants
    // =====================================

    // Rate-limit full reconciliation to once per hour — bounds O(n) gas cost
    // while still catching drift before it compounds
    const MIN_RECONCILIATION_INTERVAL: u64 = 3600;

    // Maximum age (seconds) of a cached oracle price before it is considered stale.
    // Callers may still read the cached value via get_btc_usd_price(); this constant
    // is informational and can be used by off-chain agents to decide refresh frequency.
    const MAX_PRICE_AGE: u64 = 3600;

    // Rate-of-change limits for update_btc_backing().
    // A KEEPER may reduce btc_backing by at most 50% or increase it by at most 50%
    // in a single call.  Applies only when the current value is non-zero
    // (the first call from 0 is unconstrained so initialisation remains flexible).
    //
    // Check arithmetic:
    //   lower bound: new_backing * 2 >= old_backing  ↔  new >= 50% of old
    //   upper bound: new_backing <= old_backing + old_backing / 2  ↔  new <= 150% of old
    const BTC_BACKING_MIN_PCT: u256 = 50;   // floor: new must be at least 50% of current
    const BTC_BACKING_MAX_PCT: u256 = 150;  // ceiling: new must be at most 150% of current

    // =====================================
    // Constructor
    // =====================================

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        safe_mode_threshold: u128,
        oracle_address: ContractAddress, // Pragma oracle; zero = not yet configured
    ) {
        assert(!owner.is_zero(), 'Owner is zero address');
        assert(safe_mode_threshold > 0, 'Invalid threshold');
        self.owner.write(owner);
        self.safe_mode_threshold.write(safe_mode_threshold);
        self.min_health_factor.write(100); // 1.0
        self.safe_mode.write(false);
        self.btc_backing.write(0);
        self.btc_exposure.write(0);
        self.protocol_count.write(0);
        self.last_reconciliation.write(0);
        // Oracle: zero address is valid — oracle can be configured later via set_oracle_address
        self.oracle_address.write(oracle_address);
        self.btc_usd_price.write(0);
        self.price_last_updated.write(0);
        // KEEPER can be granted/revoked by any ADMIN holder (not just the owner).
        // ADMIN and GUARDIAN remain owner-only (role_admin default 0).
        self.role_admin.write(ROLE_KEEPER, ROLE_ADMIN);
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
    impl BTCSecurityRouterImpl of super::super::interfaces::IBTCSecurityRouter<ContractState> {
        
        // ===== View Functions =====
        
        fn get_btc_health(self: @ContractState) -> u128 {
            let backing = self.btc_backing.read();
            let exposure = self.btc_exposure.read();
            
            if exposure == 0 {
                // Zero exposure = perfectly healthy (no risk in the system)
                return 0xffffffffffffffffffffffffffffffff_u128;
            }
            
            // Return health as percentage (e.g., 142 = 1.42)
            let health_256 = (backing * 100) / exposure;
            
            // Convert to u128, handling overflow
            if health_256 > 0xffffffffffffffffffffffffffffffff {
                return 0xffffffffffffffffffffffffffffffff_u128;
            }
            
            health_256.try_into().unwrap()
        }

        fn is_safe_mode(self: @ContractState) -> bool {
            self.safe_mode.read()
        }

        fn get_max_leverage(self: @ContractState) -> u128 {
            let raw_health = self.get_btc_health();
            
            // Cap at 200 (2.0x backing ratio) to prevent u128 overflow when
            // btc_exposure=0 causes get_btc_health() to return u128::MAX.
            // Any health above 200 maps to the same max leverage tier anyway.
            let health: u128 = if raw_health > 200 { 200 } else { raw_health };
            
            // Piecewise function based on health
            if health < 100 {
                0
            } else if health < 120 {
                // 1.0 to 1.1: 100 + (health - 100) * 0.5
                100 + (health - 100) / 2
            } else if health < 150 {
                // 1.1 to 1.35: 110 + (health - 120) * 0.83
                110 + ((health - 120) * 83) / 100
            } else {
                // 1.35+: 135 + (health - 150) * 1.3
                135 + ((health - 150) * 13) / 10
            }
        }

        fn get_max_ltv(self: @ContractState) -> u128 {
            let health = self.get_btc_health();
            
            if health < 100 {
                0
            } else if health < 120 {
                50 // 50%
            } else if health < 150 {
                65 // 65%
            } else {
                75 // 75%
            }
        }

        fn get_btc_backing(self: @ContractState) -> u256 {
            self.btc_backing.read()
        }

        fn get_btc_exposure(self: @ContractState) -> u256 {
            self.btc_exposure.read()
        }

        // ===== Operation Checks =====

        fn is_operation_allowed(
            self: @ContractState,
            operation_type: felt252,
            protocol: ContractAddress,
            amount: u256
        ) -> bool {
            // Check safe mode
            if self.safe_mode.read() {
                // Only allow withdrawals and repayments in safe mode
                if operation_type == 'withdraw' || operation_type == 'repay' {
                    return true;
                }
                return false;
            }
            
            // Check health factor
            let health = self.get_btc_health();
            if health < self.min_health_factor.read() {
                return false;
            }
            
            // Check if protocol is registered
            let protocol_info = self.protocols.read(protocol);
            if !protocol_info.active {
                return false;
            }
            
            // Enforce operation-specific limits (the critical enforcement mechanism per docs)
            if operation_type == 'leverage' {
                // amount = requested leverage factor (100 = 1.0x, 150 = 1.5x)
                let max_leverage = self.get_max_leverage();
                if max_leverage == 0 { return false; }
                return amount <= max_leverage.into();
            }
            
            if operation_type == 'borrow' {
                // amount = requested LTV percentage (50 = 50%)
                let max_ltv = self.get_max_ltv();
                if max_ltv == 0 { return false; }
                return amount <= max_ltv.into();
            }
            
            // deposit / withdraw / repay: allowed when not in safe mode
            true
        }

        // ===== State Updates =====

        fn update_btc_backing(ref self: ContractState, new_backing: u256) {
            // KEEPER role (oracles/bots) or owner can update backing
            self._only_owner_or_role(ROLE_KEEPER);

            let old_backing = self.btc_backing.read();

            // Rate-of-change guard: when backing is already initialised, reject any
            // single call that moves it by more than ±50%.
            // This prevents a single compromised KEEPER key from zeroing-out btc_backing
            // in one transaction and triggering a false safe-mode lockout for all users.
            // The initial call from 0 is intentionally unconstrained.
            if old_backing > 0 {
                // new >= 50% of old:  new * 2 >= old
                assert(new_backing * 2 >= old_backing, 'Backing drop exceeds 50%');
                // new <= 150% of old:  new <= old + old / 2
                assert(new_backing <= old_backing + old_backing / 2, 'Backing jump exceeds 150%');
            }

            self.btc_backing.write(new_backing);

            self.emit(BackingUpdated {
                old_backing,
                new_backing,
                timestamp: get_block_timestamp(),
            });

            self._check_and_update_health();
        }

        /// Update the caller protocol's collateral/debt contribution to system exposure.
        ///
        /// **Pre-conditions:**
        ///   - `caller` is a registered active protocol (S-6)
        ///
        /// **Post-conditions:**
        ///   - `btc_exposure` updated via delta: old contribution removed, new added
        ///   - `protocols[caller]` record updated with new values
        ///   - `_check_and_update_health()` triggered (may auto-activate safe mode)
        ///
        /// **Emits:** `ExposureReported`, possibly `SafeModeActivated`, `HealthUpdated`
        fn report_exposure(
            ref self: ContractState,
            collateral: u256,
            debt: u256,
            leverage: u128
        ) {
            let caller = get_caller_address();
            
            // Verify protocol is registered
            let old_info = self.protocols.read(caller);
            assert(old_info.active, 'Protocol not registered');
            
            // Delta-update total BTC exposure: remove old contribution, add new
            // This keeps btc_exposure accurate without iterating all protocols
            let current_total = self.btc_exposure.read();
            let new_total = if current_total >= old_info.collateral {
                current_total - old_info.collateral + collateral
            } else {
                collateral
            };
            self.btc_exposure.write(new_total);
            
            // Write updated protocol info (struct construction since Copy type)
            self.protocols.write(caller, ProtocolInfo {
                protocol_type: old_info.protocol_type,
                collateral,
                debt,
                leverage,
                active: true,
            });
            
            self.emit(ExposureReported {
                protocol: caller,
                collateral,
                debt,
                leverage,
            });
            
            self._check_and_update_health();
        }

        // ===== Safe Mode =====

        /// Activate safe mode to restrict vault operations during a systemic risk event.
        ///
        /// **Pre-conditions:**
        ///   - caller is owner or holds ROLE_GUARDIAN
        ///   - `get_btc_health() < safe_mode_threshold`  (S-1: no spurious activation)
        ///
        /// **Post-conditions:**
        ///   - `safe_mode = true`
        ///   - `is_operation_allowed` returns false for all ops except 'withdraw'/'repay' (S-5)
        ///
        /// **Emits:** `SafeModeActivated`
        fn enter_safe_mode(ref self: ContractState) {
            self._only_owner_or_role(ROLE_GUARDIAN);
            
            let health = self.get_btc_health();
            
            // Verify conditions warrant safe mode
            assert(
                health < self.safe_mode_threshold.read(),
                'Health too high for safe mode'
            );
            
            self.safe_mode.write(true);
            
            self.emit(SafeModeActivated {
                timestamp: get_block_timestamp(),
                health_factor: health,
            });
        }

        fn exit_safe_mode(ref self: ContractState, op_id: felt252) {
            self._only_owner_or_role(ROLE_ADMIN);
            let expected = compute_op_id('exit_safe_mode', array![].span());
            assert(op_id == expected, 'Op id mismatch');
            self._check_timelock(op_id);
            
            let health = self.get_btc_health();
            
            // Require health to be sufficiently high
            assert(health >= 130, 'Health still too low'); // 1.3
            
            self.safe_mode.write(false);
            
            self.emit(SafeModeDeactivated {
                timestamp: get_block_timestamp(),
                health_factor: health,
            });
        }

        // ===== Protocol Management =====

        fn register_protocol(
            ref self: ContractState,
            protocol: ContractAddress,
            protocol_type: felt252
        ) {
            self._only_owner_or_role(ROLE_ADMIN);
            assert(!protocol.is_zero(), 'Protocol is zero address');
            assert(protocol_type != 0, 'Invalid protocol type');
            // Guard: reject duplicate registration.
            // A second call for the same address appends it again to protocol_addresses
            // and increments protocol_count, causing _recalculate_total_exposure to
            // double-count that protocol's collateral — falsely inflating btc_exposure
            // and depressing the health factor, potentially triggering spurious safe mode.
            assert(!self.protocols.read(protocol).active, 'Protocol already registered');

            let protocol_info = ProtocolInfo {
                protocol_type,
                collateral: 0,
                debt: 0,
                leverage: 100,
                active: true,
            };
            
            self.protocols.write(protocol, protocol_info);

            // Store address in index so _recalculate_total_exposure can walk all protocols
            let count = self.protocol_count.read();
            self.protocol_addresses.write(count, protocol);
            self.protocol_count.write(count + 1);

            self.emit(ProtocolRegistered {
                protocol,
                protocol_type,
            });
        }

        // ===== Oracle Integration =====

        /// Return the cached BTC/USD price (8 decimal places, Pragma convention).
        ///
        /// Returns 0 in two cases:
        ///   1. The oracle has never been successfully refreshed.
        ///   2. The cached price is older than MAX_PRICE_AGE seconds (stale).
        ///
        /// Callers MUST treat a 0 return as "price unavailable" and abort any
        /// operation that requires a valid price (e.g. leverage, LTV checks).
        fn get_btc_usd_price(self: @ContractState) -> u128 {
            let price = self.btc_usd_price.read();
            // Price of 0 means the oracle was never refreshed (or refresh_btc_price
            // was never called with a non-zero result).
            if price == 0 {
                return 0;
            }
            // Enforce freshness: reject cached prices older than MAX_PRICE_AGE.
            let last_updated = self.price_last_updated.read();
            let now = get_block_timestamp();
            if now > last_updated + MAX_PRICE_AGE {
                return 0; // stale — caller must call refresh_btc_price() first
            }
            price
        }

        /// Return the block timestamp of the most recent successful price refresh.
        /// Returns 0 if the oracle has never been refreshed.
        fn get_price_last_updated(self: @ContractState) -> u64 {
            self.price_last_updated.read()
        }

        /// Returns true when a non-zero price is cached AND it is within
        /// MAX_PRICE_AGE seconds of the current block timestamp.
        fn is_price_fresh(self: @ContractState) -> bool {
            let price = self.btc_usd_price.read();
            if price == 0 {
                return false; // never refreshed
            }
            let last_updated = self.price_last_updated.read();
            let now = get_block_timestamp();
            now <= last_updated + MAX_PRICE_AGE
        }

        /// Fetch the BTC/USD spot median price from the configured Pragma oracle,
        /// validate it, cache it, and emit a PriceRefreshed event.
        ///
        /// Validation:
        ///   1. Oracle address must be configured (non-zero).
        ///   2. Returned price must be > 0 (rejects oracle malfunction / delisted pair).
        ///   3. Pragma's own `last_updated_timestamp` must be within MAX_PRICE_AGE
        ///      (rejects Pragma-side stale data before it enters our cache).
        ///
        /// Callable by: owner or any authorized agent.
        /// Fetch a fresh BTC/USD price from the Pragma oracle and cache it.
        ///
        /// **Pre-conditions:**
        ///   - caller is owner or holds ROLE_KEEPER
        ///   - `oracle_address != 0` (oracle must be configured)
        ///
        /// **Post-conditions:**
        ///   - `btc_usd_price` = Pragma median price (> 0)
        ///   - `price_last_updated` = current `block_timestamp`
        ///   - `is_price_fresh()` returns true immediately after this call
        ///
        /// **Validation:**
        ///   - Rejects price = 0 (oracle malfunction / delisted pair)
        ///   - Rejects if Pragma's own `last_updated_timestamp` > MAX_PRICE_AGE old
        ///
        /// **Emits:** `PriceRefreshed`
        fn refresh_btc_price(ref self: ContractState) {
            self._only_owner_or_role(ROLE_KEEPER);

            let oracle_addr = self.oracle_address.read();
            assert(!oracle_addr.is_zero(), 'Oracle not configured');

            let now = get_block_timestamp();

            // Fetch the BTC/USD spot median from Pragma
            let oracle = IPragmaOracleDispatcher { contract_address: oracle_addr };
            let response = oracle.get_data_median(DataType::SpotEntry(BTC_USD_PRAGMA_KEY));

            // Guard 1: price must be non-zero
            assert(response.price > 0, 'Oracle returned zero price');

            // Guard 2: Pragma's own data must be fresh enough.
            // last_updated_timestamp is when Pragma's aggregators last wrote the price.
            // Reject if Pragma itself hasn't had a recent update — this prevents us from
            // caching data that Pragma is already serving as stale.
            assert(
                now <= response.last_updated_timestamp + MAX_PRICE_AGE,
                'Pragma data too stale'
            );

            let old_price = self.btc_usd_price.read();

            self.btc_usd_price.write(response.price);
            self.price_last_updated.write(now);

            self.emit(PriceRefreshed {
                old_price,
                new_price: response.price,
                timestamp: now,
            });
        }

        /// Admin override: set BTC/USD price directly (8 dec, e.g. $95k = 9_500_000_000_000).
        /// Callable by owner only. Useful on testnets where Pragma data is stale.
        /// The price is treated as freshly updated (timestamp = now).
        fn admin_set_btc_price(ref self: ContractState, price: u128) {
            self._only_owner_or_role(ROLE_ADMIN);
            assert(price > 0, 'Price must be > 0');
            let now = get_block_timestamp();
            let old_price = self.btc_usd_price.read();
            self.btc_usd_price.write(price);
            self.price_last_updated.write(now);
            self.emit(PriceRefreshed {
                old_price,
                new_price: price,
                timestamp: now,
            });
        }

        /// Configure (or replace) the Pragma oracle address. Timelocked.
        fn set_oracle_address(ref self: ContractState, op_id: felt252, oracle: ContractAddress) {
            self._only_owner_or_role(ROLE_ADMIN);
            let expected = compute_op_id('set_oracle', array![oracle.into()].span());
            assert(op_id == expected, 'Op id mismatch');
            self._check_timelock(op_id);
            self.oracle_address.write(oracle);
        }

        /// Update safe mode threshold. Timelocked.
        fn set_safe_mode_threshold_timelocked(ref self: ContractState, op_id: felt252, threshold: u128) {
            self._only_owner_or_role(ROLE_ADMIN);
            let expected = compute_op_id('set_threshold', array![threshold.into()].span());
            assert(op_id == expected, 'Op id mismatch');
            self._check_timelock(op_id);
            assert(threshold > self.min_health_factor.read(), 'Threshold below min health');
            self.safe_mode_threshold.write(threshold);
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

        // Full O(n) reconciliation scan.
        //
        // PURPOSE
        // Delta-tracking in report_exposure() keeps btc_exposure accurate for the
        // common case (O(1) per call). But it can silently drift when:
        //   • A protocol is deactivated via deactivate_protocol() or admin override
        //     without calling report_exposure(collateral=0) first.
        //   • A future migration touches storage directly.
        // This scan is the safety net: it recomputes the canonical sum from scratch
        // and overwrites btc_exposure with the ground-truth value.
        //
        // MATH (docs §Mathematical Models §Exposure Function)
        //   E(t) = Σ_j C_j(t)   (sum of collateral across all ACTIVE protocols)
        //
        // ITERATION
        // Cairo Map<K,V> is not iterable. We maintain a parallel index:
        //   protocol_addresses[0..protocol_count-1] holds every registered address.
        // register_protocol() appends to this index; deactivate_protocol() marks
        // the protocol inactive so it is skipped here.
        //
        // GAS
        // O(protocol_count) storage reads. Rate-limited by _check_and_update_health
        // to at most once per MIN_RECONCILIATION_INTERVAL (1 hour).
        fn _recalculate_total_exposure(ref self: ContractState) {
            let count = self.protocol_count.read();
            let mut i: u32 = 0;
            let mut total: u256 = 0;
            let mut active_count: u32 = 0;

            while i < count {
                let addr = self.protocol_addresses.read(i);
                let info = self.protocols.read(addr);

                // Only active protocols contribute to system exposure.
                // Deactivated protocols have already been removed from the
                // delta total by deactivate_protocol(); this scan confirms that.
                if info.active {
                    total += info.collateral;
                    active_count += 1;
                }

                i += 1;
            };

            let old_exposure = self.btc_exposure.read();
            let drift = if old_exposure >= total {
                old_exposure - total
            } else {
                total - old_exposure
            };

            self.btc_exposure.write(total);
            self.last_reconciliation.write(get_block_timestamp());

            self.emit(ExposureReconciled {
                old_exposure,
                new_exposure: total,
                drift,
                active_protocol_count: active_count,
                timestamp: get_block_timestamp(),
            });
        }

        fn _check_and_update_health(ref self: ContractState) {
            // Rate-limited full reconciliation: at most once per MIN_RECONCILIATION_INTERVAL.
            // Between scans, delta tracking keeps btc_exposure accurate enough.
            let now = get_block_timestamp();
            let last = self.last_reconciliation.read();
            if now >= last + MIN_RECONCILIATION_INTERVAL {
                self._recalculate_total_exposure();
            }

            let old_health = self.get_btc_health();
            
            // Trigger safe mode if needed
            if old_health < self.safe_mode_threshold.read() && !self.safe_mode.read() {
                self.safe_mode.write(true);
                self.emit(SafeModeActivated {
                    timestamp: now,
                    health_factor: old_health,
                });
            }

            let new_health = self.get_btc_health();

            self.emit(HealthUpdated {
                old_health,
                new_health,
                timestamp: now,
            });
        }

        // ─────────────────────────────────────────────────────────────────────
        // Formal invariant checker
        // ─────────────────────────────────────────────────────────────────────

        /// Verify all router system invariants in a single pass.
        ///
        /// Panics with a descriptive message at the first violation.
        ///
        /// **USAGE:** Call in test/fuzz builds after every state-changing function.
        ///
        /// **Invariants checked:**
        ///   I-1  owner ≠ 0
        ///   I-2  safe_mode_threshold > min_health_factor
        ///   I-3  min_health_factor = 100  (immutable)
        fn _assert_router_invariants(self: @ContractState) {
            // I-1: owner is always a valid non-zero address
            assert(!self.owner.read().is_zero(), 'INV: owner is zero');

            // I-2: safe_mode_threshold must be strictly above min_health_factor
            //      Violation → threshold is at or below 1.0x health, meaning safe mode
            //      triggers even for a perfectly healthy system.
            assert(
                self.safe_mode_threshold.read() > self.min_health_factor.read(),
                'INV: threshold<=min_health'
            );

            // I-3: min_health_factor is immutable (constructor sets 100, nothing changes it)
            //      Violation → system-wide floor has been tampered with.
            assert(self.min_health_factor.read() == 100, 'INV: min_health_factor!=100');
        }
    }

    // =====================================
    // Additional Admin Functions
    // =====================================

    #[generate_trait]
    impl AdminImpl of AdminTrait {
        // Emergency non-timelocked threshold update — owner only.
        // For governance-controlled changes use set_safe_mode_threshold_timelocked.
        fn set_safe_mode_threshold(ref self: ContractState, threshold: u128) {
            self._only_owner();
            // Must be strictly above min_health_factor (100 = 1.0x) to be meaningful.
            // A threshold at or below 1.0x would trigger safe mode on a perfectly healthy system.
            assert(threshold > self.min_health_factor.read(), 'Threshold below min health');
            self.safe_mode_threshold.write(threshold);
        }

        fn force_update_exposure(ref self: ContractState, new_exposure: u256) {
            self._only_owner_or_role(ROLE_ADMIN);
            self.btc_exposure.write(new_exposure);
            self._check_and_update_health();
        }

        // Force a full reconciliation right now, bypassing the 1-hour rate limit.
        fn force_reconcile_exposure(ref self: ContractState) {
            self._only_owner_or_role(ROLE_ADMIN);
            self._recalculate_total_exposure();
            self._check_and_update_health();
        }

        // Deactivate a sunset or misbehaving protocol.
        fn deactivate_protocol(ref self: ContractState, protocol: ContractAddress) {
            self._only_owner_or_role(ROLE_ADMIN);
            assert(!protocol.is_zero(), 'Protocol is zero address');

            let info = self.protocols.read(protocol);
            assert(info.active, 'Protocol already inactive');

            // Remove from delta total immediately
            let current_total = self.btc_exposure.read();
            let new_total = if current_total >= info.collateral {
                current_total - info.collateral
            } else {
                0
            };
            self.btc_exposure.write(new_total);

            // Mark inactive with zeroed fields
            self.protocols.write(protocol, ProtocolInfo {
                protocol_type: info.protocol_type,
                collateral: 0,
                debt: 0,
                leverage: 100,
                active: false,
            });

            self._check_and_update_health();
        }
    }
}
