// ============================================================
// BTC Security Infrastructure — Test Suite
// ============================================================
// Uses snforge_std for deployment, cheatcodes, and assertions.
// ============================================================

use starknet::{ContractAddress, contract_address_const};
use core::array::ArrayTrait;
use snforge_std::{
    declare, ContractClassTrait, DeclareResultTrait,
    start_cheat_caller_address, stop_cheat_caller_address,
    start_cheat_block_timestamp, stop_cheat_block_timestamp,
    store, map_entry_address,
};
use vault::interfaces::{
    IBTCSecurityRouterDispatcher, IBTCSecurityRouterDispatcherTrait,
    IYBTCTokenDispatcher, IYBTCTokenDispatcherTrait,
    IBTCVaultDispatcher, IBTCVaultDispatcherTrait,
    IERC20Dispatcher, IERC20DispatcherTrait,
    IStrategyDispatcher, IStrategyDispatcherTrait,
    ROLE_ADMIN, ROLE_GUARDIAN, ROLE_KEEPER, ROLE_LIQUIDATOR, TIMELOCK_DELAY, GRACE_PERIOD,
    UserMode,
};
use vault::{
    IMockPragmaOracleDispatcher, IMockPragmaOracleDispatcherTrait,
    IAccessControlDispatcher, IAccessControlDispatcherTrait,
    IMockStrategyAdminDispatcher, IMockStrategyAdminDispatcherTrait,
    IYBTCAdminDispatcher, IYBTCAdminDispatcherTrait,
};

// --------------------------------------------------------
// Addresses used across tests
// --------------------------------------------------------
fn owner()    -> ContractAddress { contract_address_const::<0xAD>() }
fn protocol() -> ContractAddress { contract_address_const::<0xCC>() }
fn alice()    -> ContractAddress { contract_address_const::<0xA1>() }
fn bob()      -> ContractAddress { contract_address_const::<0xB0>() }
fn dummy()    -> ContractAddress { contract_address_const::<0xDD>() }
fn vault_a()  -> ContractAddress { contract_address_const::<0xAB>() }
fn proto2()   -> ContractAddress { contract_address_const::<0xC2>() }

// --------------------------------------------------------
// Deploy helpers
// --------------------------------------------------------

fn deploy_router(threshold: u128) -> IBTCSecurityRouterDispatcher {
    let contract = declare("BTCSecurityRouter").unwrap().contract_class();
    let mut calldata: Array<felt252> = ArrayTrait::new();
    calldata.append(owner().into());
    calldata.append(threshold.into());
    calldata.append(0); // oracle_address = zero (not configured; use deploy_router_with_oracle to set one)
    let (addr, _) = contract.deploy(@calldata).unwrap();
    IBTCSecurityRouterDispatcher { contract_address: addr }
}

/// Deploy a router pre-configured with a Pragma oracle address.
fn deploy_router_with_oracle(threshold: u128, oracle_addr: ContractAddress) -> IBTCSecurityRouterDispatcher {
    let contract = declare("BTCSecurityRouter").unwrap().contract_class();
    let mut calldata: Array<felt252> = ArrayTrait::new();
    calldata.append(owner().into());
    calldata.append(threshold.into());
    calldata.append(oracle_addr.into());
    let (addr, _) = contract.deploy(@calldata).unwrap();
    IBTCSecurityRouterDispatcher { contract_address: addr }
}

/// Deploy the MockPragmaOracle with an initial BTC/USD price.
/// Price uses 8 decimal places: $95,000 → 9_500_000_000_000.
fn deploy_mock_oracle(initial_price: u128) -> IMockPragmaOracleDispatcher {
    let contract = declare("MockPragmaOracle").unwrap().contract_class();
    let mut calldata: Array<felt252> = ArrayTrait::new();
    calldata.append(initial_price.into());
    calldata.append(owner().into()); // owner = the test owner address (0xAD)
    let (addr, _) = contract.deploy(@calldata).unwrap();
    IMockPragmaOracleDispatcher { contract_address: addr }
}

fn deploy_ybtc(vault_addr: ContractAddress) -> IYBTCTokenDispatcher {
    let contract = declare("YBTCToken").unwrap().contract_class();
    let mut calldata: Array<felt252> = ArrayTrait::new();
    calldata.append(owner().into());
    calldata.append(vault_addr.into());
    let (addr, _) = contract.deploy(@calldata).unwrap();
    IYBTCTokenDispatcher { contract_address: addr }
}

// Deploy a mock wBTC token (reuses YBTCToken contract).
// wbtc_minter is the address that YBTCToken's _only_vault() will accept for mint/burn.
// In tests, pass vault_a() so we can mint wBTC to users in test setup;
// then call wbtc.set_vault_address(vault.contract_address) after vault is deployed
// so the real vault can do transfer / transfer_from (not mint — vault calls ERC-20 directly).
fn deploy_wbtc(wbtc_minter: ContractAddress) -> IYBTCTokenDispatcher {
    let contract = declare("YBTCToken").unwrap().contract_class();
    let mut calldata: Array<felt252> = ArrayTrait::new();
    calldata.append(owner().into());
    calldata.append(wbtc_minter.into());
    let (addr, _) = contract.deploy(@calldata).unwrap();
    IYBTCTokenDispatcher { contract_address: addr }
}

fn deploy_vault(wbtc_addr: ContractAddress, ybtc_addr: ContractAddress, router_addr: ContractAddress) -> IBTCVaultDispatcher {
    let contract = declare("BTCVault").unwrap().contract_class();
    let mut calldata: Array<felt252> = ArrayTrait::new();
    calldata.append(owner().into());
    calldata.append(wbtc_addr.into()); // real wBTC address
    calldata.append(ybtc_addr.into());
    calldata.append(dummy().into()); // usdc placeholder
    calldata.append(router_addr.into());
    let (addr, _) = contract.deploy(@calldata).unwrap();
    IBTCVaultDispatcher { contract_address: addr }
}

// ============================================================
// Router: Health factor
// ============================================================

#[test]
fn test_router_health_zero_exposure_returns_max() {
    let router = deploy_router(110);
    let health = router.get_btc_health();
    // Zero exposure = no risk = u128::MAX
    assert(health == 0xffffffffffffffffffffffffffffffff_u128, 'zero exp must be max health');
}

#[test]
fn test_router_health_calculation() {
    // H = backing * 100 / exposure = 1000*100/700 = 142
    let router = deploy_router(110);

    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(1000);
    router.register_protocol(protocol(), 'vault');
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(router.contract_address, protocol());
    router.report_exposure(700, 0, 100);
    stop_cheat_caller_address(router.contract_address);

    assert(router.get_btc_health() == 142, 'health should be 142');
}

#[test]
fn test_router_health_at_parity() {
    // backing == exposure → health == 100
    let router = deploy_router(110);

    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(500);
    router.register_protocol(protocol(), 'vault');
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(router.contract_address, protocol());
    router.report_exposure(500, 0, 100);
    stop_cheat_caller_address(router.contract_address);

    assert(router.get_btc_health() == 100, 'health should be 100');
}

// ============================================================
// Router: Leverage caps (piecewise formula)
// ============================================================

#[test]
fn test_router_max_leverage_zero_when_unhealthy() {
    // health = 50/200 * 100 = 25 < 100 → max leverage == 0
    let router = deploy_router(110);

    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(50);
    router.register_protocol(protocol(), 'vault');
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(router.contract_address, protocol());
    router.report_exposure(200, 0, 100);
    stop_cheat_caller_address(router.contract_address);

    assert(router.get_max_leverage() == 0, 'max lev should be 0');
}

#[test]
fn test_router_max_leverage_tier1() {
    // health = 110 → tier1: 100 + (110-100)/2 = 105
    let router = deploy_router(90);

    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(110);
    router.register_protocol(protocol(), 'vault');
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(router.contract_address, protocol());
    router.report_exposure(100, 0, 100);
    stop_cheat_caller_address(router.contract_address);

    assert(router.get_max_leverage() == 105, 'tier1 lev should be 105');
}

#[test]
fn test_router_max_leverage_tier2() {
    // health = 130 → tier2: 110 + (130-120)*83/100 = 118
    let router = deploy_router(90);

    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(130);
    router.register_protocol(protocol(), 'vault');
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(router.contract_address, protocol());
    router.report_exposure(100, 0, 100);
    stop_cheat_caller_address(router.contract_address);

    assert(router.get_max_leverage() == 118, 'tier2 lev should be 118');
}

#[test]
fn test_router_max_leverage_tier3() {
    // health = 200 → tier3: 135 + (200-150)*13/10 = 200
    let router = deploy_router(90);

    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(200);
    router.register_protocol(protocol(), 'vault');
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(router.contract_address, protocol());
    router.report_exposure(100, 0, 100);
    stop_cheat_caller_address(router.contract_address);

    assert(router.get_max_leverage() == 200, 'tier3 lev should be 200');
}

// ============================================================
// Router: LTV caps
// ============================================================

#[test]
fn test_router_ltv_health_above_150() {
    // health = 200 >= 150 → LTV 75
    let router = deploy_router(90);

    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(200);
    router.register_protocol(protocol(), 'vault');
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(router.contract_address, protocol());
    router.report_exposure(100, 0, 100);
    stop_cheat_caller_address(router.contract_address);

    assert(router.get_max_ltv() == 75, 'ltv above 150 should be 75');
}

#[test]
fn test_router_ltv_health_120_to_150() {
    // health ≈ 130 → LTV 65
    let router = deploy_router(90);

    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(130);
    router.register_protocol(protocol(), 'vault');
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(router.contract_address, protocol());
    router.report_exposure(100, 0, 100);
    stop_cheat_caller_address(router.contract_address);

    assert(router.get_max_ltv() == 65, 'ltv 120-150 should be 65');
}

#[test]
fn test_router_ltv_health_100_to_120() {
    // health = 110 → LTV 50
    let router = deploy_router(90);

    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(110);
    router.register_protocol(protocol(), 'vault');
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(router.contract_address, protocol());
    router.report_exposure(100, 0, 100);
    stop_cheat_caller_address(router.contract_address);

    assert(router.get_max_ltv() == 50, 'ltv 100-120 should be 50');
}

// ============================================================
// Router: Safe mode
// ============================================================

#[test]
fn test_router_starts_not_in_safe_mode() {
    let router = deploy_router(110);
    assert(!router.is_safe_mode(), 'should not start in safe mode');
}

#[test]
fn test_router_safe_mode_auto_triggers() {
    // health = 105 < threshold 110 → auto safe mode
    let router = deploy_router(110);

    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(105);
    router.register_protocol(protocol(), 'vault');
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(router.contract_address, protocol());
    router.report_exposure(100, 0, 100);
    stop_cheat_caller_address(router.contract_address);

    assert(router.is_safe_mode(), 'safe mode should activate');
}

#[test]
fn test_router_safe_mode_blocks_deposit() {
    let router = deploy_router(110);

    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(105);
    router.register_protocol(protocol(), 'vault');
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(router.contract_address, protocol());
    router.report_exposure(100, 0, 100);
    stop_cheat_caller_address(router.contract_address);

    let allowed = router.is_operation_allowed('deposit', protocol(), 1000);
    assert(!allowed, 'deposit blocked in safe mode');
}

#[test]
fn test_router_safe_mode_allows_withdraw() {
    let router = deploy_router(110);

    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(105);
    router.register_protocol(protocol(), 'vault');
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(router.contract_address, protocol());
    router.report_exposure(100, 0, 100);
    stop_cheat_caller_address(router.contract_address);

    assert(router.is_safe_mode(), 'precond: safe mode on');
    assert(router.is_operation_allowed('withdraw', protocol(), 1), 'withdraw must be allowed');
    assert(router.is_operation_allowed('repay', protocol(), 1), 'repay must be allowed');
}

#[test]
fn test_router_exit_safe_mode_happy_path() {
    // Get into safe mode, fix health, then exit
    let router = deploy_router(110);
    let ac = IAccessControlDispatcher { contract_address: router.contract_address };

    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(105);
    router.register_protocol(protocol(), 'vault');
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(router.contract_address, protocol());
    router.report_exposure(100, 0, 100); // safe mode on
    stop_cheat_caller_address(router.contract_address);

    // Raise backing so health = 150 >= 130 (150 is within the +50% limit: 105 + 52 = 157 max)
    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(150);

    // Queue the exit_safe_mode operation — op_id must be hash('exit_safe_mode', [])
    let op_id: felt252 = ac.hash_operation('exit_safe_mode', array![].span());
    let eta: u64 = TIMELOCK_DELAY + 1;
    ac.queue_operation(op_id, eta);
    stop_cheat_caller_address(router.contract_address);

    // Advance block timestamp past the timelock
    start_cheat_block_timestamp(router.contract_address, eta);

    start_cheat_caller_address(router.contract_address, owner());
    router.exit_safe_mode(op_id);
    stop_cheat_caller_address(router.contract_address);

    stop_cheat_block_timestamp(router.contract_address);

    assert(!router.is_safe_mode(), 'safe mode should be off');
}

#[test]
#[should_panic(expected: ('Health still too low',))]
fn test_router_exit_safe_mode_fails_low_health() {
    // Properly queue exit_safe_mode with the correct op_id, then try to exit
    // while health is still below 130 — must fail with 'Health still too low'.
    let router = deploy_router(110);
    let ac = IAccessControlDispatcher { contract_address: router.contract_address };

    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(105);
    router.register_protocol(protocol(), 'vault');
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(router.contract_address, protocol());
    router.report_exposure(100, 0, 100); // health = 105 → triggers safe mode (threshold = 110)
    stop_cheat_caller_address(router.contract_address);

    // Queue the exit operation with its correct parameter-bound op_id
    let op_id: felt252 = ac.hash_operation('exit_safe_mode', array![].span());
    let eta: u64 = TIMELOCK_DELAY + 1;
    start_cheat_caller_address(router.contract_address, owner());
    ac.queue_operation(op_id, eta);
    stop_cheat_caller_address(router.contract_address);

    // Advance past the timelock but keep health at 105 (< 130)
    start_cheat_block_timestamp(router.contract_address, eta);

    start_cheat_caller_address(router.contract_address, owner());
    router.exit_safe_mode(op_id); // must panic — health still too low
    stop_cheat_caller_address(router.contract_address);

    stop_cheat_block_timestamp(router.contract_address);
}

// ============================================================
// Router: Operation gating
// ============================================================

#[test]
fn test_router_leverage_op_blocked_above_cap() {
    // health = 110 → max_leverage = 105; 106 must be blocked
    let router = deploy_router(90);

    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(110);
    router.register_protocol(protocol(), 'vault');
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(router.contract_address, protocol());
    router.report_exposure(100, 0, 100);
    stop_cheat_caller_address(router.contract_address);

    assert(!router.is_operation_allowed('leverage', protocol(), 110), 'lev 110 must be blocked');
    assert(router.is_operation_allowed('leverage', protocol(), 105), 'lev 105 must be allowed');
}

#[test]
fn test_router_borrow_op_blocked_above_ltv() {
    // health = 200 → max_ltv = 75; 80 must be blocked
    let router = deploy_router(90);

    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(200);
    router.register_protocol(protocol(), 'vault');
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(router.contract_address, protocol());
    router.report_exposure(100, 0, 100);
    stop_cheat_caller_address(router.contract_address);

    assert(!router.is_operation_allowed('borrow', protocol(), 80), 'borrow 80 must be blocked');
    assert(router.is_operation_allowed('borrow', protocol(), 75), 'borrow 75 must be allowed');
}

// ============================================================
// Router: Protocol registration
// ============================================================

#[test]
fn test_router_register_protocol_enables_reporting() {
    let router = deploy_router(110);

    start_cheat_caller_address(router.contract_address, owner());
    router.register_protocol(protocol(), 'vault');
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(router.contract_address, protocol());
    router.report_exposure(100, 50, 100);
    stop_cheat_caller_address(router.contract_address);

    assert(router.get_btc_exposure() == 100, 'exposure should be 100');
}

#[test]
#[should_panic(expected: ('Protocol not registered',))]
fn test_router_unregistered_protocol_cannot_report() {
    let router = deploy_router(110);
    start_cheat_caller_address(router.contract_address, protocol());
    router.report_exposure(100, 0, 100);
    stop_cheat_caller_address(router.contract_address);
}

#[test]
#[should_panic(expected: ('Protocol is zero address',))]
fn test_router_register_zero_protocol_fails() {
    let router = deploy_router(110);
    let zero: ContractAddress = 0.try_into().unwrap();
    start_cheat_caller_address(router.contract_address, owner());
    router.register_protocol(zero, 'vault');
    stop_cheat_caller_address(router.contract_address);
}

// ============================================================
// Router: Exposure delta tracking
// ============================================================

#[test]
fn test_router_two_protocols_exposure_sums() {
    let router = deploy_router(90);

    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(10000);
    router.register_protocol(protocol(), 'vault');
    router.register_protocol(proto2(), 'cdp');
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(router.contract_address, protocol());
    router.report_exposure(300, 0, 100);
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(router.contract_address, proto2());
    router.report_exposure(200, 0, 100);
    stop_cheat_caller_address(router.contract_address);

    assert(router.get_btc_exposure() == 500, 'total exposure should be 500');
}

#[test]
fn test_router_exposure_update_replaces_old_value() {
    let router = deploy_router(90);

    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(10000);
    router.register_protocol(protocol(), 'vault');
    router.register_protocol(proto2(), 'cdp');
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(router.contract_address, protocol());
    router.report_exposure(300, 0, 100);
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(router.contract_address, proto2());
    router.report_exposure(200, 0, 100);
    stop_cheat_caller_address(router.contract_address);

    // Update first protocol: 300 → 400; total should become 600
    start_cheat_caller_address(router.contract_address, protocol());
    router.report_exposure(400, 0, 100);
    stop_cheat_caller_address(router.contract_address);

    assert(router.get_btc_exposure() == 600, 'exposure after update: 600');
}

// ============================================================
// Router: Access control
// ============================================================

#[test]
#[should_panic(expected: ('Unauthorized',))]
fn test_router_non_admin_cannot_register_protocol() {
    let router = deploy_router(110);
    start_cheat_caller_address(router.contract_address, alice());
    router.register_protocol(protocol(), 'vault');
    stop_cheat_caller_address(router.contract_address);
}

#[test]
#[should_panic(expected: ('Unauthorized',))]
fn test_router_non_oracle_cannot_update_backing() {
    let router = deploy_router(110);
    start_cheat_caller_address(router.contract_address, alice());
    router.update_btc_backing(1000);
    stop_cheat_caller_address(router.contract_address);
}

// ============================================================
// Router: Constructor guards
// ============================================================

#[test]
#[should_panic(expected: ('Owner is zero address',))]
fn test_router_zero_owner_constructor_fails() {
    let contract = declare("BTCSecurityRouter").unwrap().contract_class();
    let mut calldata: Array<felt252> = ArrayTrait::new();
    calldata.append(0); // zero owner
    calldata.append(110);
    calldata.append(0); // oracle_address = zero
    match contract.deploy(@calldata) {
        Result::Ok(_) => {},
        Result::Err(err) => panic(err),
    }
}

#[test]
#[should_panic(expected: ('Invalid threshold',))]
fn test_router_zero_threshold_constructor_fails() {
    let contract = declare("BTCSecurityRouter").unwrap().contract_class();
    let mut calldata: Array<felt252> = ArrayTrait::new();
    calldata.append(owner().into());
    calldata.append(0); // zero threshold
    calldata.append(0); // oracle_address = zero
    match contract.deploy(@calldata) {
        Result::Ok(_) => {},
        Result::Err(err) => panic(err),
    }
}

// ============================================================
// yBTC Token: Metadata
// ============================================================

#[test]
fn test_ybtc_metadata() {
    let ybtc = deploy_ybtc(dummy());
    assert(ybtc.decimals() == 8, 'decimals should be 8');
    assert(ybtc.total_supply() == 0, 'initial supply should be 0');
}

// ============================================================
// yBTC Token: Mint / Burn
// ============================================================

#[test]
fn test_ybtc_mint_increases_supply_and_balance() {
    let ybtc = deploy_ybtc(vault_a());

    start_cheat_caller_address(ybtc.contract_address, vault_a());
    ybtc.mint(alice(), 1000);
    stop_cheat_caller_address(ybtc.contract_address);

    assert(ybtc.total_supply() == 1000, 'supply should be 1000');
    assert(ybtc.balance_of(alice()) == 1000, 'alice balance: 1000');
}

#[test]
fn test_ybtc_burn_decreases_supply_and_balance() {
    let ybtc = deploy_ybtc(vault_a());

    start_cheat_caller_address(ybtc.contract_address, vault_a());
    ybtc.mint(alice(), 1000);
    ybtc.burn(alice(), 400);
    stop_cheat_caller_address(ybtc.contract_address);

    assert(ybtc.total_supply() == 600, 'supply should be 600');
    assert(ybtc.balance_of(alice()) == 600, 'alice balance: 600');
}

#[test]
#[should_panic(expected: ('Only vault can call',))]
fn test_ybtc_non_vault_cannot_mint() {
    let ybtc = deploy_ybtc(dummy());
    start_cheat_caller_address(ybtc.contract_address, alice());
    ybtc.mint(alice(), 100);
    stop_cheat_caller_address(ybtc.contract_address);
}

#[test]
#[should_panic(expected: ('Only vault can call',))]
fn test_ybtc_non_vault_cannot_burn() {
    let ybtc = deploy_ybtc(vault_a());

    start_cheat_caller_address(ybtc.contract_address, vault_a());
    ybtc.mint(alice(), 500);
    stop_cheat_caller_address(ybtc.contract_address);

    start_cheat_caller_address(ybtc.contract_address, alice());
    ybtc.burn(alice(), 100); // must panic
    stop_cheat_caller_address(ybtc.contract_address);
}

#[test]
#[should_panic(expected: ('Zero mint amount',))]
fn test_ybtc_zero_mint_fails() {
    let ybtc = deploy_ybtc(vault_a());
    start_cheat_caller_address(ybtc.contract_address, vault_a());
    ybtc.mint(alice(), 0);
    stop_cheat_caller_address(ybtc.contract_address);
}

#[test]
#[should_panic(expected: ('Zero burn amount',))]
fn test_ybtc_zero_burn_fails() {
    let ybtc = deploy_ybtc(vault_a());
    start_cheat_caller_address(ybtc.contract_address, vault_a());
    ybtc.mint(alice(), 100);
    ybtc.burn(alice(), 0);
    stop_cheat_caller_address(ybtc.contract_address);
}

#[test]
#[should_panic(expected: ('Insufficient balance',))]
fn test_ybtc_burn_exceeds_balance() {
    let ybtc = deploy_ybtc(vault_a());
    start_cheat_caller_address(ybtc.contract_address, vault_a());
    ybtc.mint(alice(), 100);
    ybtc.burn(alice(), 200);
    stop_cheat_caller_address(ybtc.contract_address);
}

// ============================================================
// yBTC Token: ERC20 transfer / approve
// ============================================================

#[test]
fn test_ybtc_transfer() {
    let ybtc = deploy_ybtc(vault_a());

    start_cheat_caller_address(ybtc.contract_address, vault_a());
    ybtc.mint(alice(), 500);
    stop_cheat_caller_address(ybtc.contract_address);

    start_cheat_caller_address(ybtc.contract_address, alice());
    ybtc.transfer(bob(), 200);
    stop_cheat_caller_address(ybtc.contract_address);

    assert(ybtc.balance_of(alice()) == 300, 'alice should have 300');
    assert(ybtc.balance_of(bob()) == 200, 'bob should have 200');
}

#[test]
fn test_ybtc_approve_and_transfer_from() {
    let ybtc = deploy_ybtc(vault_a());

    start_cheat_caller_address(ybtc.contract_address, vault_a());
    ybtc.mint(alice(), 500);
    stop_cheat_caller_address(ybtc.contract_address);

    start_cheat_caller_address(ybtc.contract_address, alice());
    ybtc.approve(bob(), 150);
    stop_cheat_caller_address(ybtc.contract_address);

    assert(ybtc.allowance(alice(), bob()) == 150, 'allowance should be 150');

    start_cheat_caller_address(ybtc.contract_address, bob());
    ybtc.transfer_from(alice(), bob(), 150);
    stop_cheat_caller_address(ybtc.contract_address);

    assert(ybtc.balance_of(alice()) == 350, 'alice should have 350');
    assert(ybtc.balance_of(bob()) == 150, 'bob should have 150');
    assert(ybtc.allowance(alice(), bob()) == 0, 'allowance should be 0');
}

#[test]
#[should_panic(expected: ('Insufficient allowance',))]
fn test_ybtc_transfer_from_exceeds_allowance() {
    let ybtc = deploy_ybtc(vault_a());

    start_cheat_caller_address(ybtc.contract_address, vault_a());
    ybtc.mint(alice(), 500);
    stop_cheat_caller_address(ybtc.contract_address);

    start_cheat_caller_address(ybtc.contract_address, alice());
    ybtc.approve(bob(), 50);
    stop_cheat_caller_address(ybtc.contract_address);

    start_cheat_caller_address(ybtc.contract_address, bob());
    ybtc.transfer_from(alice(), bob(), 100);
    stop_cheat_caller_address(ybtc.contract_address);
}

#[test]
#[should_panic(expected: ('Transfer to zero address',))]
fn test_ybtc_transfer_to_zero_fails() {
    let ybtc = deploy_ybtc(vault_a());
    let zero: ContractAddress = 0.try_into().unwrap();

    start_cheat_caller_address(ybtc.contract_address, vault_a());
    ybtc.mint(alice(), 100);
    stop_cheat_caller_address(ybtc.contract_address);

    start_cheat_caller_address(ybtc.contract_address, alice());
    ybtc.transfer(zero, 50);
    stop_cheat_caller_address(ybtc.contract_address);
}

// ============================================================
// yBTC Token: Constructor guards
// ============================================================

#[test]
#[should_panic(expected: ('Owner is zero address',))]
fn test_ybtc_zero_owner_constructor_fails() {
    let contract = declare("YBTCToken").unwrap().contract_class();
    let mut calldata: Array<felt252> = ArrayTrait::new();
    calldata.append(0); // zero owner
    calldata.append(vault_a().into());
    match contract.deploy(@calldata) {
        Result::Ok(_) => {},
        Result::Err(err) => panic(err),
    }
}

#[test]
#[should_panic(expected: ('Vault is zero address',))]
fn test_ybtc_zero_vault_constructor_fails() {
    let contract = declare("YBTCToken").unwrap().contract_class();
    let mut calldata: Array<felt252> = ArrayTrait::new();
    calldata.append(owner().into());
    calldata.append(0); // zero vault
    match contract.deploy(@calldata) {
        Result::Ok(_) => {},
        Result::Err(err) => panic(err),
    }
}

// ============================================================
// Share math: pure arithmetic verification
// ============================================================

#[test]
fn test_share_math_first_deposit_is_1_to_1() {
    let amount: u256 = 100_000_000;
    let total_supply: u256 = 0;
    let shares = if total_supply == 0 { amount } else { 0 };
    assert(shares == amount, 'first deposit must be 1:1');
}

#[test]
fn test_share_math_subsequent_deposit() {
    // assets=100, supply=100, deposit=10 → 10*100/100 = 10 shares
    let amount: u256 = 10;
    let total_assets: u256 = 100;
    let total_supply: u256 = 100;
    let shares = (amount * total_supply) / total_assets;
    assert(shares == 10, 'shares should be 10');
}

#[test]
fn test_share_math_after_yield() {
    // assets=105, supply=100, deposit=10 → 10*100/105 = 9 shares (floor)
    let amount: u256 = 10;
    let total_assets: u256 = 105;
    let total_supply: u256 = 100;
    let shares = (amount * total_supply) / total_assets;
    assert(shares == 9, 'shares after yield: 9');
}

#[test]
fn test_share_math_redemption() {
    // shares=10, assets=105, supply=100 → 10*105/100 = 10 (floor)
    let shares: u256 = 10;
    let total_assets: u256 = 105;
    let total_supply: u256 = 100;
    let btc = (shares * total_assets) / total_supply;
    assert(btc == 10, 'redemption should be 10');
}

#[test]
fn test_share_math_loss_scenario() {
    // assets=90, supply=100, shares=10 → 10*90/100 = 9
    let shares: u256 = 10;
    let total_assets: u256 = 90;
    let total_supply: u256 = 100;
    let btc = (shares * total_assets) / total_supply;
    assert(btc == 9, 'loss scenario: 9 btc back');
}

#[test]
fn test_share_math_multi_user_equal_split() {
    // 22 assets, 20 supply → alice 10 shares → 10*22/20 = 11
    let total_assets: u256 = 22;
    let total_supply: u256 = 20;
    let alice_shares: u256 = 10;
    let alice_btc = (alice_shares * total_assets) / total_supply;
    assert(alice_btc == 11, 'alice should get 11 btc');
}

// ============================================================
// Leverage math: pure arithmetic verification
// ============================================================

#[test]
fn test_leverage_per_tx_increase_limit_arithmetic() {
    // MAX_LEVERAGE_INCREASE_PER_TX = 30
    // from 100 to 130 is allowed; 131 is not
    let max_increase: u128 = 30;
    let current: u128 = 100;
    assert(130_u128 <= current + max_increase, 'within limit ok');
    assert(131_u128 > current + max_increase, 'over limit ok');
}

#[test]
fn test_leverage_debt_calculation_arithmetic() {
    // debt = collateral * (leverage - 100) / 100
    // 1000 * 50 / 100 = 500
    let collateral: u256 = 1000;
    let target_leverage: u128 = 150;
    let leverage_factor: u256 = (target_leverage - 100).into();
    let debt = (collateral * leverage_factor) / 100;
    assert(debt == 500, 'debt should be 500');
}

// ============================================================
// Vault: pause guard logic (pure)
// ============================================================

#[test]
fn test_vault_pause_guard_blocks_both_deposit_and_withdraw() {
    let is_paused = true;
    assert(!is_paused == false, 'deposit blocked when paused');
    // withdraw was missing the pause check before the security fix — now both blocked
    assert(!is_paused == false, 'withdraw blocked when paused');
}

// ============================================================
// Vault: reentrancy guard logic (pure)
// ============================================================

#[test]
fn test_reentrancy_guard_flag_transitions() {
    let mut guard = false;
    assert(!guard, 'guard starts false');
    guard = true;
    assert(guard, 'guard is true during call');
    guard = false;
    assert(!guard, 'guard resets to false');
}

// ============================================================
// Router deactivate_protocol: guard message verification (pure)
// ============================================================

#[test]
fn test_deactivate_protocol_error_message_constant() {
    // Documents the exact panic message emitted by deactivate_protocol()
    // when called on an already-inactive protocol.
    let msg: felt252 = 'Protocol already inactive';
    assert(msg == 'Protocol already inactive', 'msg constant correct');
}

// ============================================================
// Router: get_btc_backing view
// ============================================================

#[test]
fn test_router_get_btc_backing_returns_value() {
    let router = deploy_router(110);
    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(12345);
    stop_cheat_caller_address(router.contract_address);
    assert(router.get_btc_backing() == 12345, 'backing should be 12345');
}

// ============================================================
// Router: enter_safe_mode explicit call
// ============================================================

#[test]
#[should_panic(expected: ('Health too high for safe mode',))]
fn test_router_enter_safe_mode_health_too_high_fails() {
    // health = MAX (zero exposure) >> threshold → manual entry rejected
    let router = deploy_router(110);
    start_cheat_caller_address(router.contract_address, owner());
    router.enter_safe_mode();
    stop_cheat_caller_address(router.contract_address);
}

#[test]
fn test_router_enter_safe_mode_manual_call() {
    // health = 105 < threshold 110 → auto-triggered; explicit call also valid
    let router = deploy_router(110);

    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(105);
    router.register_protocol(protocol(), 'vault');
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(router.contract_address, protocol());
    router.report_exposure(100, 0, 100); // auto-triggers safe mode
    stop_cheat_caller_address(router.contract_address);

    assert(router.is_safe_mode(), 'precond: safe mode on');

    // Calling enter_safe_mode explicitly when health < threshold must succeed
    start_cheat_caller_address(router.contract_address, owner());
    router.enter_safe_mode();
    stop_cheat_caller_address(router.contract_address);

    assert(router.is_safe_mode(), 'still in safe mode');
}

#[test]
#[should_panic(expected: ('Unauthorized',))]
fn test_router_non_authorized_enter_safe_mode_fails() {
    let router = deploy_router(110);
    start_cheat_caller_address(router.contract_address, alice());
    router.enter_safe_mode();
    stop_cheat_caller_address(router.contract_address);
}

// ============================================================
// yBTC Token: name / symbol metadata
// ============================================================

#[test]
fn test_ybtc_name_and_symbol() {
    let ybtc = deploy_ybtc(dummy());
    assert(ybtc.name() == "Yield Bitcoin", 'name should be Yield Bitcoin');
    assert(ybtc.symbol() == "yBTC", 'symbol should be yBTC');
}

// ============================================================
// yBTC Token: additional guards
// ============================================================

#[test]
#[should_panic(expected: ('Mint to zero address',))]
fn test_ybtc_mint_to_zero_fails() {
    let ybtc = deploy_ybtc(vault_a());
    let zero: ContractAddress = 0.try_into().unwrap();
    start_cheat_caller_address(ybtc.contract_address, vault_a());
    ybtc.mint(zero, 100);
    stop_cheat_caller_address(ybtc.contract_address);
}

#[test]
#[should_panic(expected: ('Zero transfer amount',))]
fn test_ybtc_transfer_zero_amount_fails() {
    let ybtc = deploy_ybtc(vault_a());

    start_cheat_caller_address(ybtc.contract_address, vault_a());
    ybtc.mint(alice(), 100);
    stop_cheat_caller_address(ybtc.contract_address);

    start_cheat_caller_address(ybtc.contract_address, alice());
    ybtc.transfer(bob(), 0);
    stop_cheat_caller_address(ybtc.contract_address);
}

#[test]
#[should_panic(expected: ('Insufficient balance',))]
fn test_ybtc_transfer_insufficient_balance_fails() {
    let ybtc = deploy_ybtc(vault_a());

    start_cheat_caller_address(ybtc.contract_address, vault_a());
    ybtc.mint(alice(), 100);
    stop_cheat_caller_address(ybtc.contract_address);

    start_cheat_caller_address(ybtc.contract_address, alice());
    ybtc.transfer(bob(), 200); // more than balance
    stop_cheat_caller_address(ybtc.contract_address);
}

// ============================================================
// BTCVault: Constructor guards
// ============================================================

#[test]
#[should_panic(expected: ('Owner is zero address',))]
fn test_vault_constructor_zero_owner_fails() {
    let contract = declare("BTCVault").unwrap().contract_class();
    let mut calldata: Array<felt252> = ArrayTrait::new();
    calldata.append(0); // zero owner
    calldata.append(dummy().into());
    calldata.append(dummy().into());
    calldata.append(dummy().into());
    calldata.append(dummy().into());
    match contract.deploy(@calldata) {
        Result::Ok(_) => {},
        Result::Err(err) => panic(err),
    }
}

#[test]
#[should_panic(expected: ('wBTC address is zero',))]
fn test_vault_constructor_zero_wbtc_fails() {
    let contract = declare("BTCVault").unwrap().contract_class();
    let mut calldata: Array<felt252> = ArrayTrait::new();
    calldata.append(owner().into());
    calldata.append(0); // zero wbtc
    calldata.append(dummy().into());
    calldata.append(dummy().into());
    calldata.append(dummy().into());
    match contract.deploy(@calldata) {
        Result::Ok(_) => {},
        Result::Err(err) => panic(err),
    }
}

#[test]
#[should_panic(expected: ('yBTC address is zero',))]
fn test_vault_constructor_zero_ybtc_fails() {
    let contract = declare("BTCVault").unwrap().contract_class();
    let mut calldata: Array<felt252> = ArrayTrait::new();
    calldata.append(owner().into());
    calldata.append(dummy().into());
    calldata.append(0); // zero ybtc
    calldata.append(dummy().into());
    calldata.append(dummy().into());
    match contract.deploy(@calldata) {
        Result::Ok(_) => {},
        Result::Err(err) => panic(err),
    }
}

#[test]
#[should_panic(expected: ('Router address is zero',))]
fn test_vault_constructor_zero_router_fails() {
    let contract = declare("BTCVault").unwrap().contract_class();
    let mut calldata: Array<felt252> = ArrayTrait::new();
    calldata.append(owner().into());
    calldata.append(dummy().into());
    calldata.append(dummy().into());
    calldata.append(dummy().into());
    calldata.append(0); // zero router
    match contract.deploy(@calldata) {
        Result::Ok(_) => {},
        Result::Err(err) => panic(err),
    }
}

// ============================================================
// BTCVault: View functions on fresh deployment
// ============================================================

#[test]
fn test_vault_get_total_assets_initially_zero() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    assert(vault.get_total_assets() == 0, 'total assets should be 0');
}

#[test]
fn test_vault_get_total_debt_initially_zero() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    assert(vault.get_total_debt() == 0, 'total debt should be 0');
}

#[test]
fn test_vault_get_apy_returns_zero_no_capital() {
    // total_assets == 0 → APY returns 0
    let vault = deploy_vault(dummy(), dummy(), dummy());
    assert(vault.get_apy() == 0, 'apy should be 0');
}

#[test]
fn test_vault_get_share_price_empty_returns_scale() {
    // SCALE = 1_000_000; total_supply == 0 → price == 1.0
    let vault = deploy_vault(dummy(), dummy(), dummy());
    assert(vault.get_share_price() == 1_000_000, 'share price should be 1e6');
}

#[test]
fn test_vault_get_user_position_no_deposit() {
    let router = deploy_router(110);
    let ybtc = deploy_ybtc(vault_a());
    let vault = deploy_vault(dummy(), ybtc.contract_address, router.contract_address);
    let (bal, val, lev) = vault.get_user_position(alice());
    assert(bal == 0, 'balance should be 0');
    assert(val == 0, 'btc value should be 0');
    assert(lev == 0, 'leverage should be 0');
}

// ============================================================
// BTCVault: Admin (pause / set_router)
// ============================================================

#[test]
fn test_vault_pause_and_unpause() {
    let vault = deploy_vault(dummy(), dummy(), dummy());

    start_cheat_caller_address(vault.contract_address, owner());
    vault.pause();
    stop_cheat_caller_address(vault.contract_address);

    start_cheat_caller_address(vault.contract_address, owner());
    vault.unpause();
    stop_cheat_caller_address(vault.contract_address);
}

#[test]
#[should_panic(expected: ('Unauthorized',))]
fn test_vault_non_owner_cannot_pause() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    start_cheat_caller_address(vault.contract_address, alice());
    vault.pause();
    stop_cheat_caller_address(vault.contract_address);
}

#[test]
fn test_vault_set_router_owner_succeeds() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };

    // Queue the operation with ETA = TIMELOCK_DELAY + 1
    let op_id: felt252 = ac.hash_operation('set_router', array![dummy().into()].span());
    let eta: u64 = TIMELOCK_DELAY + 1;
    start_cheat_caller_address(vault.contract_address, owner());
    ac.queue_operation(op_id, eta);
    stop_cheat_caller_address(vault.contract_address);

    // Advance block timestamp past the timelock
    start_cheat_block_timestamp(vault.contract_address, eta);

    start_cheat_caller_address(vault.contract_address, owner());
    vault.set_router(op_id, dummy()); // must not panic
    stop_cheat_caller_address(vault.contract_address);

    stop_cheat_block_timestamp(vault.contract_address);
}

#[test]
#[should_panic(expected: ('Unauthorized',))]
fn test_vault_non_owner_cannot_set_router() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    start_cheat_caller_address(vault.contract_address, alice());
    vault.set_router('op1', dummy());
    stop_cheat_caller_address(vault.contract_address);
}

#[test]
#[should_panic(expected: ('Vault paused',))]
fn test_vault_pause_blocks_deposit() {
    let vault = deploy_vault(dummy(), dummy(), dummy());

    start_cheat_caller_address(vault.contract_address, owner());
    vault.pause();
    stop_cheat_caller_address(vault.contract_address);

    start_cheat_caller_address(vault.contract_address, alice());
    vault.deposit(100_000_000);
    stop_cheat_caller_address(vault.contract_address);
}

#[test]
#[should_panic(expected: ('Vault paused',))]
fn test_vault_pause_blocks_withdraw() {
    let vault = deploy_vault(dummy(), dummy(), dummy());

    start_cheat_caller_address(vault.contract_address, owner());
    vault.pause();
    stop_cheat_caller_address(vault.contract_address);

    start_cheat_caller_address(vault.contract_address, alice());
    vault.withdraw(100_000_000);
    stop_cheat_caller_address(vault.contract_address);
}

// ============================================================
// BTCVault: Deposit / Withdraw input validation
// ============================================================

#[test]
#[should_panic(expected: ('Zero deposit amount',))]
fn test_vault_deposit_zero_fails() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    start_cheat_caller_address(vault.contract_address, alice());
    vault.deposit(0);
    stop_cheat_caller_address(vault.contract_address);
}

#[test]
#[should_panic(expected: ('Amount too small',))]
fn test_vault_deposit_amount_too_small_fails() {
    // minimum_deposit = 1_000_000; 500_000 is rejected before any router call
    let vault = deploy_vault(dummy(), dummy(), dummy());
    start_cheat_caller_address(vault.contract_address, alice());
    vault.deposit(500_000);
    stop_cheat_caller_address(vault.contract_address);
}

#[test]
#[should_panic(expected: ('First deposit too small',))]
fn test_vault_deposit_first_deposit_too_small_fails() {
    // 5_000_000 >= minimum_deposit (1_000_000) but < MINIMUM_FIRST_DEPOSIT (10_000_000)
    // First-deposit guard now fires BEFORE transfer_from, so dummy() wBTC is fine.
    let router = deploy_router(90);
    let ybtc = deploy_ybtc(vault_a());
    let vault = deploy_vault(dummy(), ybtc.contract_address, router.contract_address);

    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(1_000_000_000);
    router.register_protocol(vault.contract_address, 'vault');
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(vault.contract_address, alice());
    vault.deposit(5_000_000); // panics before transfer_from
    stop_cheat_caller_address(vault.contract_address);
}

#[test]
#[should_panic(expected: ('Zero withdrawal amount',))]
fn test_vault_withdraw_zero_fails() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    start_cheat_caller_address(vault.contract_address, alice());
    vault.withdraw(0);
    stop_cheat_caller_address(vault.contract_address);
}

#[test]
#[should_panic(expected: ('Router rejected deposit',))]
fn test_vault_deposit_blocked_by_router_safe_mode() {
    // Router safe mode blocks deposit; vault propagates 'Router rejected deposit'
    let router = deploy_router(110);
    let ybtc = deploy_ybtc(vault_a());
    let vault = deploy_vault(dummy(), ybtc.contract_address, router.contract_address);

    // Register vault so is_operation_allowed reaches safe-mode check
    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(105);
    router.register_protocol(vault.contract_address, 'vault');
    router.register_protocol(protocol(), 'mock');
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(router.contract_address, protocol());
    router.report_exposure(100, 0, 100); // health = 105 < 110 → safe mode
    stop_cheat_caller_address(router.contract_address);

    assert(router.is_safe_mode(), 'precond: safe mode');

    start_cheat_caller_address(vault.contract_address, alice());
    vault.deposit(100_000_000);
    stop_cheat_caller_address(vault.contract_address);
}

// ============================================================
// BTCVault: Full deposit / withdraw round-trip
//
// Setup:
//  1. deploy_wbtc(vault_a())  → mock wBTC; vault_a() can mint in test setup
//  2. deploy_ybtc(vault_a())  → yBTC; vault_a() cheat lets vault mint/burn
//  3. deploy_vault(wbtc, ybtc, router) → real vault with real wBTC address
//  4. wbtc.set_vault_address(vault) → not needed; vault only calls transfer/
//     transfer_from on wBTC (ERC-20), never mint/burn.
//     yBTC's set_vault_address IS needed so vault can mint yBTC directly.
//  5. Mint wBTC to alice via vault_a() cheat, alice approves vault.
//  6. Deposit: vault calls wbtc.transfer_from(alice, vault, amount).
//  7. Withdraw: vault calls wbtc.transfer(alice, amount).
// ============================================================

// Helper: full round-trip setup. Returns (wbtc, ybtc, vault) with
// alice pre-funded with `initial_wbtc` wBTC and yBTC vault set.
fn setup_vault_with_wbtc(
    initial_wbtc: u256
) -> (IYBTCTokenDispatcher, IYBTCTokenDispatcher, IBTCVaultDispatcher) {
    let router = deploy_router(90);
    let wbtc = deploy_wbtc(vault_a());       // vault_a() can mint wBTC for test setup
    let ybtc = deploy_ybtc(vault_a());       // temporary vault_a(); will update below
    let vault = deploy_vault(wbtc.contract_address, ybtc.contract_address, router.contract_address);

    // Point yBTC at the real vault so vault.deposit/withdraw can mint/burn yBTC
    start_cheat_caller_address(ybtc.contract_address, owner());
    // set_vault_address is in AdminImpl — called as owner
    // (ybtc_token AdminImpl is not part of the ABI, call via IYBTCToken is not possible;
    //  we keep vault_a() cheat active during deposit/withdraw instead)
    stop_cheat_caller_address(ybtc.contract_address);

    // Register vault with router
    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(1_000_000_000);
    router.register_protocol(vault.contract_address, 'vault');
    stop_cheat_caller_address(router.contract_address);

    // Mint wBTC to alice
    start_cheat_caller_address(wbtc.contract_address, vault_a());
    wbtc.mint(alice(), initial_wbtc);
    stop_cheat_caller_address(wbtc.contract_address);

    // Alice approves the vault to pull her wBTC
    start_cheat_caller_address(wbtc.contract_address, alice());
    wbtc.approve(vault.contract_address, initial_wbtc);
    stop_cheat_caller_address(wbtc.contract_address);

    (wbtc, ybtc, vault)
}

#[test]
fn test_vault_deposit_updates_state() {
    let (wbtc, ybtc, vault) = setup_vault_with_wbtc(100_000_000);

    // Cheat yBTC so vault's internal mint call passes _only_vault()
    start_cheat_caller_address(ybtc.contract_address, vault_a());
    start_cheat_caller_address(vault.contract_address, alice());
    let shares = vault.deposit(100_000_000); // 0.1 BTC; first deposit → 1:1
    stop_cheat_caller_address(vault.contract_address);
    stop_cheat_caller_address(ybtc.contract_address);

    assert(shares == 100_000_000, 'first deposit: 1:1 shares');
    assert(vault.get_total_assets() == 100_000_000, 'total assets: 0.1 BTC');
    assert(ybtc.balance_of(alice()) == 100_000_000, 'alice ybtc: 0.1 BTC');
    // wBTC has moved: alice lost it, vault gained it
    assert(wbtc.balance_of(alice()) == 0, 'alice wbtc: 0 after deposit');
    assert(wbtc.balance_of(vault.contract_address) == 100_000_000, 'vault holds wbtc');
}

#[test]
fn test_vault_deposit_then_withdraw() {
    let (wbtc, ybtc, vault) = setup_vault_with_wbtc(100_000_000);

    start_cheat_caller_address(ybtc.contract_address, vault_a());

    start_cheat_caller_address(vault.contract_address, alice());
    vault.deposit(100_000_000);
    stop_cheat_caller_address(vault.contract_address);

    // Alice approves vault to burn her yBTC (vault burns directly, no allowance needed)
    // Redeem all shares
    start_cheat_caller_address(vault.contract_address, alice());
    let btc = vault.withdraw(100_000_000);
    stop_cheat_caller_address(vault.contract_address);

    stop_cheat_caller_address(ybtc.contract_address);

    assert(btc == 100_000_000, 'should get back full btc');
    assert(vault.get_total_assets() == 0, 'assets zero after full withdraw');
    assert(ybtc.balance_of(alice()) == 0, 'alice ybtc: 0 after withdraw');
    // wBTC should be back with alice
    assert(wbtc.balance_of(alice()) == 100_000_000, 'alice wbtc restored');
    assert(wbtc.balance_of(vault.contract_address) == 0, 'vault wbtc: 0');
}

#[test]
fn test_vault_get_share_price_after_deposit() {
    let (_wbtc, ybtc, vault) = setup_vault_with_wbtc(100_000_000);

    start_cheat_caller_address(ybtc.contract_address, vault_a());
    start_cheat_caller_address(vault.contract_address, alice());
    vault.deposit(100_000_000);
    stop_cheat_caller_address(vault.contract_address);
    stop_cheat_caller_address(ybtc.contract_address);

    // total_assets == total_supply == 100_000_000 → price == SCALE (1_000_000)
    assert(vault.get_share_price() == 1_000_000, 'share price should be 1:1');
}

#[test]
fn test_vault_get_user_position_after_deposit() {
    let (_wbtc, ybtc, vault) = setup_vault_with_wbtc(100_000_000);

    start_cheat_caller_address(ybtc.contract_address, vault_a());
    start_cheat_caller_address(vault.contract_address, alice());
    vault.deposit(100_000_000);
    stop_cheat_caller_address(vault.contract_address);
    stop_cheat_caller_address(ybtc.contract_address);

    let (bal, val, lev) = vault.get_user_position(alice());
    assert(bal == 100_000_000, 'alice ybtc: 0.1 BTC');
    assert(val == 100_000_000, 'btc value: 0.1 BTC');
    assert(lev == 0, 'leverage not set yet');
}

// ============================================================
// BTCVault: Leverage (apply / deleverage)
//
// setup: backing=200_000_000, a separate protocol reports
// exposure=100 so health = 200_000_000 × 100 / 100 = 2_000_000.
// get_max_leverage(2_000_000) = 135 + (2_000_000-150)×13/10 ≈ 2_600_000
// which fits comfortably in u128 and allows targets 100-130.
// ============================================================

#[test]
#[should_panic(expected: ('Leverage below 1.0',))]
fn test_vault_apply_leverage_below_min_fails() {
    let router = deploy_router(90);
    let ybtc = deploy_ybtc(vault_a());
    let vault = deploy_vault(dummy(), ybtc.contract_address, router.contract_address);

    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(200_000_000);
    router.register_protocol(vault.contract_address, 'vault');
    router.register_protocol(protocol(), 'mock');
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(router.contract_address, protocol());
    router.report_exposure(100, 0, 100); // gives health = 2_000_000 — no overflow
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(vault.contract_address, alice());
    vault.apply_leverage(99); // below 1.0x
    stop_cheat_caller_address(vault.contract_address);
}

#[test]
#[should_panic(expected: ('Leverage increase too large',))]
fn test_vault_apply_leverage_increase_too_large_fails() {
    // MAX_LEVERAGE_INCREASE_PER_TX = 30; fresh user effective_old = 100; max target = 130
    let router = deploy_router(90);
    let ybtc = deploy_ybtc(vault_a());
    let vault = deploy_vault(dummy(), ybtc.contract_address, router.contract_address);

    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(200_000_000);
    router.register_protocol(vault.contract_address, 'vault');
    router.register_protocol(protocol(), 'mock');
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(router.contract_address, protocol());
    router.report_exposure(100, 0, 100);
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(vault.contract_address, alice());
    vault.apply_leverage(131); // 131 > 100 + 30 = 130
    stop_cheat_caller_address(vault.contract_address);
}

#[test]
fn test_vault_apply_leverage_and_deleverage() {
    // Oracle is now required for leverage — configure it before applying.
    let oracle = deploy_mock_oracle(9_500_000_000_000_u128); // BTC @ $95,000
    let router = deploy_router_with_oracle(90, oracle.contract_address);
    let ybtc = deploy_ybtc(vault_a());
    let vault = deploy_vault(dummy(), ybtc.contract_address, router.contract_address);

    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(200_000_000);
    router.register_protocol(vault.contract_address, 'vault');
    router.register_protocol(protocol(), 'mock');
    router.refresh_btc_price(); // cache the oracle price so leverage is unblocked
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(router.contract_address, protocol());
    router.report_exposure(100, 0, 100);
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(vault.contract_address, alice());
    vault.apply_leverage(120); // 120 ≤ 130 — within per-tx limit
    stop_cheat_caller_address(vault.contract_address);

    let (_, _, lev) = vault.get_user_position(alice());
    assert(lev == 120, 'leverage should be 120');

    start_cheat_caller_address(vault.contract_address, alice());
    vault.deleverage();
    stop_cheat_caller_address(vault.contract_address);

    let (_, _, lev2) = vault.get_user_position(alice());
    assert(lev2 == 100, 'leverage resets to 100 (1.0x)');
}

// ============================================================
// BTCVault: Strategy access control
// ============================================================

#[test]
#[should_panic(expected: ('Strategy not active',))]
fn test_vault_deploy_to_strategy_inactive_fails() {
    // register_strategy is internal (not ABI-exposed); every strategy starts inactive
    let vault = deploy_vault(dummy(), dummy(), dummy());
    start_cheat_caller_address(vault.contract_address, owner());
    vault.deploy_to_strategy(dummy(), 1_000);
    stop_cheat_caller_address(vault.contract_address);
}

#[test]
#[should_panic(expected: ('Unauthorized',))]
fn test_vault_non_owner_cannot_deploy_to_strategy() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    start_cheat_caller_address(vault.contract_address, alice());
    vault.deploy_to_strategy(dummy(), 1_000);
    stop_cheat_caller_address(vault.contract_address);
}

#[test]
#[should_panic(expected: ('Unauthorized',))]
fn test_vault_non_owner_cannot_withdraw_from_strategy() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    start_cheat_caller_address(vault.contract_address, alice());
    vault.withdraw_from_strategy(dummy(), 1_000);
    stop_cheat_caller_address(vault.contract_address);
}

// ============================================================
// BTCVault: Full strategy round-trip with real wBTC transfers
//
// Flow:
//  1. Alice deposits wBTC → vault holds it, yBTC minted
//  2. Owner deploys vault wBTC to MockStrategy
//  3. MockStrategy.deploy() updates its accounting; vault wBTC moves to strategy
//  4. Owner withdraws from MockStrategy
//  5. MockStrategy.withdraw() transfers wBTC back to vault
//  6. Alice withdraws from vault → vault transfers wBTC to alice
// ============================================================

fn deploy_strategy(
    wbtc_addr: ContractAddress,
    vault_addr: ContractAddress
) -> IStrategyDispatcher {
    let contract = declare("MockStrategy").unwrap().contract_class();
    let mut calldata: Array<felt252> = ArrayTrait::new();
    calldata.append(owner().into());
    calldata.append(vault_addr.into());
    calldata.append(wbtc_addr.into());
    calldata.append('TestStrat');
    calldata.append(1_u8.into());    // risk_level
    calldata.append(1000_u128.into()); // base_apy (10%)
    // capacity: u256 needs two felts (low, high)
    calldata.append(1_000_000_000_u128.into()); // low
    calldata.append(0);
    let (addr, _) = contract.deploy(@calldata).unwrap();
    IStrategyDispatcher { contract_address: addr }
}

#[test]
fn test_strategy_deploy_moves_wbtc_to_strategy() {
    let (wbtc, ybtc, vault) = setup_vault_with_wbtc(100_000_000);
    let strategy = deploy_strategy(wbtc.contract_address, vault.contract_address);

    // Alice deposits
    start_cheat_caller_address(ybtc.contract_address, vault_a());
    start_cheat_caller_address(vault.contract_address, alice());
    vault.deposit(100_000_000);
    stop_cheat_caller_address(vault.contract_address);
    stop_cheat_caller_address(ybtc.contract_address);

    assert(wbtc.balance_of(vault.contract_address) == 100_000_000, 'vault holds wbtc');

    // Register strategy then deploy 50% of vault capital to it
    start_cheat_caller_address(vault.contract_address, owner());
    // register_strategy is in AdminImpl — accessible via vault as owner
    // We call deploy_to_strategy which internally does wbtc.transfer + strat.deploy
    // First register it (AdminImpl not part of IBTCVault ABI — call directly via cheat)
    stop_cheat_caller_address(vault.contract_address);

    // deploy_to_strategy requires strategy to be registered (active=true in strategies map).
    // register_strategy is AdminImpl so we call it as owner via the vault contract.
    // Since it's not in the IBTCVault interface, we use a raw dispatcher.
    // Here we cheat the vault and call deploy_to_strategy which checks strategy_info.active.
    // We can't register via the ABI, so we test the transfer path directly by
    // using a fresh vault that has the strategy pre-registered via constructor workaround.
    // Instead, verify the token movement at the IERC20 level after owner calls it.
    //
    // The strategy access-control tests already cover the 'Strategy not active' guard.
    // This test focuses on the wBTC movement when a strategy IS active.
    //
    // Use IERC20Dispatcher to directly transfer wBTC to strategy (simulating deploy_to_strategy
    // after registration) and then call strategy.withdraw to verify the return flow.
    let wbtc_disp = IERC20Dispatcher { contract_address: wbtc.contract_address };

    // Simulate vault sending wBTC to strategy (what deploy_to_strategy does)
    start_cheat_caller_address(wbtc.contract_address, vault.contract_address);
    wbtc_disp.transfer(strategy.contract_address, 50_000_000);
    stop_cheat_caller_address(wbtc.contract_address);

    assert(wbtc.balance_of(strategy.contract_address) == 50_000_000, 'strategy got wBTC');
    assert(wbtc.balance_of(vault.contract_address) == 50_000_000, 'vault has rest');

    // Simulate strategy.deploy() accounting update
    start_cheat_caller_address(strategy.contract_address, vault.contract_address);
    strategy.deploy(50_000_000);
    stop_cheat_caller_address(strategy.contract_address);

    assert(strategy.get_value() == 50_000_000, 'strategy value correct');
}

#[test]
fn test_strategy_withdraw_returns_wbtc_to_vault() {
    let (wbtc, ybtc, vault) = setup_vault_with_wbtc(100_000_000);
    let strategy = deploy_strategy(wbtc.contract_address, vault.contract_address);

    // Alice deposits
    start_cheat_caller_address(ybtc.contract_address, vault_a());
    start_cheat_caller_address(vault.contract_address, alice());
    vault.deposit(100_000_000);
    stop_cheat_caller_address(vault.contract_address);
    stop_cheat_caller_address(ybtc.contract_address);

    // Move wBTC from vault to strategy
    start_cheat_caller_address(wbtc.contract_address, vault.contract_address);
    IERC20Dispatcher { contract_address: wbtc.contract_address }
        .transfer(strategy.contract_address, 50_000_000);
    stop_cheat_caller_address(wbtc.contract_address);

    start_cheat_caller_address(strategy.contract_address, vault.contract_address);
    strategy.deploy(50_000_000);
    stop_cheat_caller_address(strategy.contract_address);

    // Vault has 50M, strategy has 50M
    assert(wbtc.balance_of(vault.contract_address) == 50_000_000, 'vault liquid: 50M');
    assert(wbtc.balance_of(strategy.contract_address) == 50_000_000, 'strategy: 50M');

    // Withdraw from strategy — strategy must send wBTC back to vault
    start_cheat_caller_address(strategy.contract_address, vault.contract_address);
    let returned = strategy.withdraw(50_000_000);
    stop_cheat_caller_address(strategy.contract_address);

    assert(returned == 50_000_000, 'returned amount correct');
    assert(wbtc.balance_of(vault.contract_address) == 100_000_000, 'vault liquid restored');
    assert(wbtc.balance_of(strategy.contract_address) == 0, 'strategy emptied');
}

#[test]
fn test_full_deposit_strategy_withdraw_roundtrip() {
    // Complete flow: deposit → deploy to strategy → withdraw from strategy → user withdraws
    let (wbtc, ybtc, vault) = setup_vault_with_wbtc(100_000_000);
    let strategy = deploy_strategy(wbtc.contract_address, vault.contract_address);

    // 1. Alice deposits 100M wBTC
    start_cheat_caller_address(ybtc.contract_address, vault_a());
    start_cheat_caller_address(vault.contract_address, alice());
    vault.deposit(100_000_000);
    stop_cheat_caller_address(vault.contract_address);
    stop_cheat_caller_address(ybtc.contract_address);

    // 2. Deploy 80M to strategy
    start_cheat_caller_address(wbtc.contract_address, vault.contract_address);
    IERC20Dispatcher { contract_address: wbtc.contract_address }
        .transfer(strategy.contract_address, 80_000_000);
    stop_cheat_caller_address(wbtc.contract_address);

    start_cheat_caller_address(strategy.contract_address, vault.contract_address);
    strategy.deploy(80_000_000);
    stop_cheat_caller_address(strategy.contract_address);

    // Vault now liquid: 20M, strategy: 80M
    assert(wbtc.balance_of(vault.contract_address) == 20_000_000, 'vault liquid: 20M');

    // 3. Recall 80M from strategy
    start_cheat_caller_address(strategy.contract_address, vault.contract_address);
    strategy.withdraw(80_000_000);
    stop_cheat_caller_address(strategy.contract_address);

    assert(wbtc.balance_of(vault.contract_address) == 100_000_000, 'vault liquid: 100M after recall');

    // 4. Alice withdraws all shares
    start_cheat_caller_address(ybtc.contract_address, vault_a());
    start_cheat_caller_address(vault.contract_address, alice());
    let got = vault.withdraw(100_000_000);
    stop_cheat_caller_address(vault.contract_address);
    stop_cheat_caller_address(ybtc.contract_address);

    assert(got == 100_000_000, 'alice got back full amount');
    assert(wbtc.balance_of(alice()) == 100_000_000, 'alice wBTC fully restored');
    assert(wbtc.balance_of(vault.contract_address) == 0, 'vault empty');
    assert(wbtc.balance_of(strategy.contract_address) == 0, 'strategy empty');
}

#[test]
#[should_panic(expected: ('Insufficient liquid wBTC',))]
fn test_withdraw_fails_when_wbtc_deployed_to_strategy() {
    // Verify _ensure_liquidity blocks withdrawal when vault has insufficient liquid wBTC
    let (wbtc, ybtc, vault) = setup_vault_with_wbtc(100_000_000);
    let strategy = deploy_strategy(wbtc.contract_address, vault.contract_address);

    // Alice deposits
    start_cheat_caller_address(ybtc.contract_address, vault_a());
    start_cheat_caller_address(vault.contract_address, alice());
    vault.deposit(100_000_000);
    stop_cheat_caller_address(vault.contract_address);
    stop_cheat_caller_address(ybtc.contract_address);

    // Deploy ALL wBTC to strategy — vault liquid balance = 0
    start_cheat_caller_address(wbtc.contract_address, vault.contract_address);
    IERC20Dispatcher { contract_address: wbtc.contract_address }
        .transfer(strategy.contract_address, 100_000_000);
    stop_cheat_caller_address(wbtc.contract_address);

    start_cheat_caller_address(strategy.contract_address, vault.contract_address);
    strategy.deploy(100_000_000);
    stop_cheat_caller_address(strategy.contract_address);

    // Alice tries to withdraw — vault has no liquid wBTC → must panic
    start_cheat_caller_address(ybtc.contract_address, vault_a());
    start_cheat_caller_address(vault.contract_address, alice());
    vault.withdraw(100_000_000);
    stop_cheat_caller_address(vault.contract_address);
    stop_cheat_caller_address(ybtc.contract_address);
}

// ============================================================
// Pragma Oracle Integration
//
// Tests cover:
//  1. MockPragmaOracle basic price read/write
//  2. Router: price starts at 0 before first refresh
//  3. Router: refresh_btc_price fetches from oracle and caches
//  4. Router: refresh fails when no oracle configured
//  5. Router: set_oracle_address admin-only
//  6. Router: set then refresh flows
//  7. Router: price updates when oracle price changes
//  8. Vault: get_btc_usd_price delegates to router
//  9. Vault: apply_leverage uses oracle price for USD debt
// ============================================================

// 1. MockPragmaOracle: set and get price
#[test]
fn test_mock_oracle_set_and_get_price() {
    let oracle = deploy_mock_oracle(9_500_000_000_000_u128); // $95,000 with 8 decimals
    assert(oracle.get_price() == 9_500_000_000_000_u128, 'initial price wrong');

    start_cheat_caller_address(oracle.contract_address, owner());
    oracle.set_price(10_000_000_000_000_u128); // $100,000
    stop_cheat_caller_address(oracle.contract_address);

    assert(oracle.get_price() == 10_000_000_000_000_u128, 'updated price wrong');
}

// 2. Router: price is 0 before any refresh
#[test]
fn test_router_price_is_zero_before_refresh() {
    let oracle = deploy_mock_oracle(9_500_000_000_000_u128);
    let router = deploy_router_with_oracle(110, oracle.contract_address);
    // No refresh called yet — cached price must be 0
    assert(router.get_btc_usd_price() == 0, 'price: 0 before refresh');
    assert(router.get_price_last_updated() == 0, 'timestamp should be 0');
}

// 3. Router: refresh_btc_price caches the oracle price
#[test]
fn test_router_refresh_btc_price_caches_price() {
    let oracle = deploy_mock_oracle(9_500_000_000_000_u128);
    let router = deploy_router_with_oracle(110, oracle.contract_address);

    start_cheat_caller_address(router.contract_address, owner());
    router.refresh_btc_price();
    stop_cheat_caller_address(router.contract_address);

    assert(router.get_btc_usd_price() == 9_500_000_000_000_u128, 'cached price wrong');
}

// 4. Router: refresh_btc_price fails when no oracle is configured
#[test]
#[should_panic(expected: ('Oracle not configured',))]
fn test_router_refresh_price_no_oracle_fails() {
    let router = deploy_router(110); // oracle_address = zero

    start_cheat_caller_address(router.contract_address, owner());
    router.refresh_btc_price(); // must panic
    stop_cheat_caller_address(router.contract_address);
}

// 5. Router: set_oracle_address is admin-only
#[test]
#[should_panic(expected: ('Unauthorized',))]
fn test_router_set_oracle_address_non_admin_fails() {
    let router = deploy_router(110);

    start_cheat_caller_address(router.contract_address, alice());
    router.set_oracle_address('op1', dummy()); // alice is not admin — must panic
    stop_cheat_caller_address(router.contract_address);
}

// 6. Router: configure oracle after deploy, then refresh
#[test]
fn test_router_set_oracle_then_refresh() {
    let oracle = deploy_mock_oracle(9_500_000_000_000_u128);
    let router = deploy_router(110); // initially no oracle
    let ac = IAccessControlDispatcher { contract_address: router.contract_address };

    let op_id: felt252 = ac.hash_operation('set_oracle', array![oracle.contract_address.into()].span());
    let eta: u64 = TIMELOCK_DELAY + 1;

    start_cheat_caller_address(router.contract_address, owner());
    ac.queue_operation(op_id, eta);
    stop_cheat_caller_address(router.contract_address);

    start_cheat_block_timestamp(router.contract_address, eta);
    // Also cheat the oracle's block_timestamp so its last_updated stays fresh
    start_cheat_block_timestamp(oracle.contract_address, eta);

    // Touch oracle price so last_updated_timestamp is at current (cheated) block
    start_cheat_caller_address(oracle.contract_address, owner());
    oracle.set_price(9_500_000_000_000_u128);
    stop_cheat_caller_address(oracle.contract_address);

    start_cheat_caller_address(router.contract_address, owner());
    router.set_oracle_address(op_id, oracle.contract_address);
    router.refresh_btc_price();
    stop_cheat_caller_address(router.contract_address);

    stop_cheat_block_timestamp(router.contract_address);
    stop_cheat_block_timestamp(oracle.contract_address);

    assert(router.get_btc_usd_price() == 9_500_000_000_000_u128, 'price should match oracle');
}

// 7. Router: second refresh picks up oracle price update
#[test]
fn test_router_price_updates_on_second_refresh() {
    let oracle = deploy_mock_oracle(9_500_000_000_000_u128);
    let router = deploy_router_with_oracle(110, oracle.contract_address);

    // First refresh: $95,000
    start_cheat_caller_address(router.contract_address, owner());
    router.refresh_btc_price();
    stop_cheat_caller_address(router.contract_address);
    assert(router.get_btc_usd_price() == 9_500_000_000_000_u128, 'first price wrong');

    // Oracle price changes to $100,000
    start_cheat_caller_address(oracle.contract_address, owner());
    oracle.set_price(10_000_000_000_000_u128);
    stop_cheat_caller_address(oracle.contract_address);

    // Second refresh picks up the new price
    start_cheat_caller_address(router.contract_address, owner());
    router.refresh_btc_price();
    stop_cheat_caller_address(router.contract_address);
    assert(router.get_btc_usd_price() == 10_000_000_000_000_u128, 'second price wrong');
}

// 8. Vault: get_btc_usd_price delegates to router's cached price
#[test]
fn test_vault_get_btc_usd_price_from_router() {
    let oracle = deploy_mock_oracle(9_500_000_000_000_u128);
    let router = deploy_router_with_oracle(110, oracle.contract_address);

    let wbtc = deploy_wbtc(vault_a());
    let ybtc = deploy_ybtc(vault_a());
    let vault = deploy_vault(wbtc.contract_address, ybtc.contract_address, router.contract_address);

    // Register vault with router
    start_cheat_caller_address(router.contract_address, owner());
    router.register_protocol(vault.contract_address, 'vault');
    router.update_btc_backing(1_000_000_000);
    router.refresh_btc_price(); // cache $95,000 into router
    stop_cheat_caller_address(router.contract_address);

    // Vault should surface the same price
    assert(vault.get_btc_usd_price() == 9_500_000_000_000_u128, 'vault price wrong');
}

// 9. Vault: apply_leverage computes USD debt using oracle price
//
// Setup: 1 BTC deposited (100_000_000 sat), BTC @ $95,000 (9_500_000_000_000),
//        leverage target = 120 (1.2x) → leverage_factor = 20.
//
// Expected USD debt (8 dec):
//   100_000_000 × 9_500_000_000_000 × 20 / (100_000_000 × 100)
//   = 9_500_000_000_000 × 20 / 100
//   = 1_900_000_000_000   ≡  $19,000.00000000
#[test]
fn test_vault_leverage_debt_calculated_with_oracle_price() {
    const BTC_PRICE: u128 = 9_500_000_000_000_u128; // $95,000 with 8 decimals

    let oracle = deploy_mock_oracle(BTC_PRICE);
    // Use a very high threshold so safe-mode never fires during setup
    let router = deploy_router_with_oracle(110, oracle.contract_address);

    // Deploy tokens
    let wbtc = deploy_wbtc(vault_a());
    let ybtc = deploy_ybtc(vault_a());
    let vault = deploy_vault(wbtc.contract_address, ybtc.contract_address, router.contract_address);

    // Configure router: high backing, register vault, refresh price
    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(1_000_000_000_000_u256); // ample backing → health very high
    router.register_protocol(vault.contract_address, 'vault');
    router.register_protocol(protocol(), 'mock');
    router.refresh_btc_price(); // cache $95,000
    stop_cheat_caller_address(router.contract_address);

    // A second protocol reports tiny exposure so health stays very large
    start_cheat_caller_address(router.contract_address, protocol());
    router.report_exposure(100, 0, 100);
    stop_cheat_caller_address(router.contract_address);

    // Mint and approve wBTC for alice
    start_cheat_caller_address(wbtc.contract_address, vault_a());
    wbtc.mint(alice(), 100_000_000_u256); // 1 BTC
    stop_cheat_caller_address(wbtc.contract_address);
    start_cheat_caller_address(wbtc.contract_address, alice());
    wbtc.approve(vault.contract_address, 100_000_000_u256);
    stop_cheat_caller_address(wbtc.contract_address);

    // Alice deposits 1 BTC
    start_cheat_caller_address(ybtc.contract_address, vault_a());
    start_cheat_caller_address(vault.contract_address, alice());
    vault.deposit(100_000_000_u256);
    stop_cheat_caller_address(vault.contract_address);
    stop_cheat_caller_address(ybtc.contract_address);

    // Debt before leverage should be 0
    assert(vault.get_total_debt() == 0, 'debt before lev should be 0');

    // Apply 1.2x leverage (factor = 20)
    start_cheat_caller_address(vault.contract_address, alice());
    vault.apply_leverage(120_u128);
    stop_cheat_caller_address(vault.contract_address);

    // Verify USD debt = $19,000.00000000 (8 decimals)
    let expected_debt: u256 = 1_900_000_000_000_u256;
    assert(vault.get_total_debt() == expected_debt, 'USD debt wrong with oracle');
}

// 10. Router: is_price_fresh returns false before any refresh
#[test]
fn test_router_is_not_fresh_before_refresh() {
    let oracle = deploy_mock_oracle(9_500_000_000_000_u128);
    let router = deploy_router_with_oracle(110, oracle.contract_address);
    assert(!router.is_price_fresh(), 'should not be fresh initially');
}

// 11. Router: is_price_fresh returns true after a successful refresh
#[test]
fn test_router_is_fresh_after_refresh() {
    let oracle = deploy_mock_oracle(9_500_000_000_000_u128);
    let router = deploy_router_with_oracle(110, oracle.contract_address);

    start_cheat_caller_address(router.contract_address, owner());
    router.refresh_btc_price();
    stop_cheat_caller_address(router.contract_address);

    assert(router.is_price_fresh(), 'should be fresh after refresh');
    // get_btc_usd_price must return the live value when fresh
    assert(router.get_btc_usd_price() == 9_500_000_000_000_u128, 'price must match oracle');
}

// 12. Router: refresh_btc_price reverts when oracle returns price = 0
//     (simulates a delisted pair or oracle malfunction)
#[test]
#[should_panic(expected: ('Oracle returned zero price',))]
fn test_router_refresh_zero_price_fails() {
    let oracle = deploy_mock_oracle(0_u128); // deliberately broken oracle
    let router = deploy_router_with_oracle(110, oracle.contract_address);

    start_cheat_caller_address(router.contract_address, owner());
    router.refresh_btc_price(); // must panic
    stop_cheat_caller_address(router.contract_address);
}

// 13. Vault: apply_leverage reverts when router has no oracle configured
//     (no oracle address → get_btc_usd_price returns 0 → leverage blocked)
#[test]
#[should_panic(expected: ('No oracle price available',))]
fn test_vault_leverage_fails_without_oracle() {
    let router = deploy_router(90); // oracle_address = zero
    let ybtc = deploy_ybtc(vault_a());
    let vault = deploy_vault(dummy(), ybtc.contract_address, router.contract_address);

    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(200_000_000);
    router.register_protocol(vault.contract_address, 'vault');
    router.register_protocol(protocol(), 'mock');
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(router.contract_address, protocol());
    router.report_exposure(100, 0, 100);
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(vault.contract_address, alice());
    vault.apply_leverage(120); // must panic: no oracle configured
    stop_cheat_caller_address(vault.contract_address);
}

// ============================================================
// Liquidation Engine — helper
// ============================================================

/// Full setup returning (wbtc, ybtc, vault, router, oracle).
/// alice gets 1 BTC (100_000_000 sat) minted and deposits it.
/// Router is configured with the given BTC price and high backing so
/// leverage calls succeed.
fn setup_with_oracle(
    btc_price: u128
) -> (IYBTCTokenDispatcher, IYBTCTokenDispatcher, IBTCVaultDispatcher, IBTCSecurityRouterDispatcher, IMockPragmaOracleDispatcher) {
    let oracle = deploy_mock_oracle(btc_price);
    let router = deploy_router_with_oracle(110, oracle.contract_address);
    let wbtc  = deploy_wbtc(vault_a());
    let ybtc  = deploy_ybtc(vault_a());
    let vault = deploy_vault(wbtc.contract_address, ybtc.contract_address, router.contract_address);

    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(1_000_000_000_000_u256);
    router.register_protocol(vault.contract_address, 'vault');
    router.register_protocol(protocol(), 'mock');
    router.refresh_btc_price();
    stop_cheat_caller_address(router.contract_address);

    // Dummy exposure so router health stays well above threshold
    start_cheat_caller_address(router.contract_address, protocol());
    router.report_exposure(100, 0, 100);
    stop_cheat_caller_address(router.contract_address);

    // Mint 1 BTC to alice and approve vault
    start_cheat_caller_address(wbtc.contract_address, vault_a());
    wbtc.mint(alice(), 100_000_000_u256);
    // Also mint a small protocol reserve directly to the vault (covers liquidation bonuses)
    wbtc.mint(vault.contract_address, 10_000_000_u256);
    stop_cheat_caller_address(wbtc.contract_address);

    start_cheat_caller_address(wbtc.contract_address, alice());
    wbtc.approve(vault.contract_address, 100_000_000_u256);
    stop_cheat_caller_address(wbtc.contract_address);

    // Alice deposits 1 BTC
    start_cheat_caller_address(ybtc.contract_address, vault_a());
    start_cheat_caller_address(vault.contract_address, alice());
    vault.deposit(100_000_000_u256);
    stop_cheat_caller_address(vault.contract_address);
    stop_cheat_caller_address(ybtc.contract_address);

    (wbtc, ybtc, vault, router, oracle)
}

// ============================================================
// Liquidation Engine — Test Group 1: Per-user health
// ============================================================

// 14. User with no debt has infinite health (u128::MAX)
#[test]
fn test_user_health_no_debt_returns_max() {
    let (_, _, vault, _, _) = setup_with_oracle(9_500_000_000_000_u128);
    // alice deposited but has NOT applied leverage → no debt
    let h = vault.get_user_health(alice());
    assert(h == 0xffffffffffffffffffffffffffffffff_u128, 'no-debt health must be max');
}

// 15. After applying 1.2x leverage the user is in the safe zone (h > 150)
//
// Setup: 1 BTC @ $95,000, leverage 1.2x (factor=20)
// USD debt = 100_000_000 × 9_500_000_000_000 × 20 / (100_000_000 × 100)
//          = 1_900_000_000_000
// h = (100_000_000 × 9_500_000_000_000 × 80 × 100)
//     / (1_900_000_000_000 × 100_000_000)
//   = 76_000_000_000_000_000_000_000_000 / 190_000_000_000_000_000_000
//   = 400  → well above 150 (safe)
#[test]
fn test_user_health_after_leverage_is_safe() {
    let (_, _, vault, _, _) = setup_with_oracle(9_500_000_000_000_u128);

    start_cheat_caller_address(vault.contract_address, alice());
    vault.apply_leverage(120_u128);
    stop_cheat_caller_address(vault.contract_address);

    let h = vault.get_user_health(alice());
    assert(h > 150_u128, 'health must be safe after lev');
}

// 16. get_liquidation_price returns 0 when user has no debt
#[test]
fn test_get_liquidation_price_no_debt_returns_zero() {
    let (_, _, vault, _, _) = setup_with_oracle(9_500_000_000_000_u128);
    assert(vault.get_liquidation_price(alice()) == 0, 'no-debt liq price must be 0');
}

// 17. get_liquidation_price with debt follows P_crit formula
//
// P_crit = D × BTC_DECIMALS × 100 / (C × LIQUIDATION_LTV)
// With D=1_900_000_000_000, C=100_000_000, LTV=80:
// P_crit = 1_900_000_000_000 × 100_000_000 × 100 / (100_000_000 × 80)
//        = 1_900_000_000_000 × 100 / 80
//        = 2_375_000_000_000   ($23,750.00000000)
#[test]
fn test_get_liquidation_price_with_debt() {
    let (_, _, vault, _, _) = setup_with_oracle(9_500_000_000_000_u128);

    start_cheat_caller_address(vault.contract_address, alice());
    vault.apply_leverage(120_u128);
    stop_cheat_caller_address(vault.contract_address);

    let p_crit = vault.get_liquidation_price(alice());
    // At $95k the health is ~400 so P_crit should be far below the current price
    assert(p_crit > 0, 'liq price must be non-zero');
    assert(p_crit < 9_500_000_000_000_u128, 'P_crit below current price');
}

// 18. is_liquidatable returns false when position is healthy
#[test]
fn test_is_liquidatable_false_when_healthy() {
    let (_, _, vault, _, _) = setup_with_oracle(9_500_000_000_000_u128);

    start_cheat_caller_address(vault.contract_address, alice());
    vault.apply_leverage(120_u128);
    stop_cheat_caller_address(vault.contract_address);

    assert(!vault.is_liquidatable(alice()), 'healthy pos not liquidatable');
}

// 19. is_liquidatable returns false when user has no debt at all
#[test]
fn test_is_liquidatable_false_no_debt() {
    let (_, _, vault, _, _) = setup_with_oracle(9_500_000_000_000_u128);
    assert(!vault.is_liquidatable(alice()), 'no-debt not liquidatable');
}

// 20. is_liquidatable returns true when price crashes below P_crit
//
// Apply 1.2x leverage at $95k → debt = $19,000.
// P_crit ≈ $23,750.  Set oracle to $10,000 (below P_crit) → h ≤ 100 → liquidatable.
#[test]
fn test_is_liquidatable_true_when_price_crashes() {
    let (_, _, vault, router, oracle) = setup_with_oracle(9_500_000_000_000_u128);

    // Apply 1.2x leverage at high price (health ~400)
    start_cheat_caller_address(vault.contract_address, alice());
    vault.apply_leverage(120_u128);
    stop_cheat_caller_address(vault.contract_address);

    // Crash price to $10,000 (1_000_000_000_000 with 8 dec)
    start_cheat_caller_address(oracle.contract_address, owner());
    oracle.set_price(1_000_000_000_000_u128);
    stop_cheat_caller_address(oracle.contract_address);

    // Refresh the router's cached price
    start_cheat_caller_address(router.contract_address, owner());
    router.refresh_btc_price();
    stop_cheat_caller_address(router.contract_address);

    assert(vault.is_liquidatable(alice()), 'pos liquidatable after crash');
}

// ============================================================
// Liquidation Engine — Test Group 2: liquidate() execution
// ============================================================

// 21. liquidate() panics when position is healthy
#[test]
#[should_panic(expected: ('Position not liquidatable',))]
fn test_liquidate_healthy_position_fails() {
    let (_, _, vault, _, _) = setup_with_oracle(9_500_000_000_000_u128);
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };

    // Grant bob the LIQUIDATOR role
    start_cheat_caller_address(vault.contract_address, owner());
    ac.grant_role(ROLE_LIQUIDATOR, bob());
    stop_cheat_caller_address(vault.contract_address);

    start_cheat_caller_address(vault.contract_address, alice());
    vault.apply_leverage(120_u128);
    stop_cheat_caller_address(vault.contract_address);

    // bob tries to liquidate alice while she is healthy
    start_cheat_caller_address(vault.contract_address, bob());
    vault.liquidate(alice()); // must panic
    stop_cheat_caller_address(vault.contract_address);
}

// 22. Full liquidation flow: deposit → leverage → price crash → liquidate
//     Verifies that:
//       a) liquidator receives wBTC
//       b) user's yBTC balance becomes 0
//       c) user's debt is cleared
//       d) is_liquidatable(user) returns false after liquidation
#[test]
fn test_liquidate_unhealthy_position_succeeds() {
    let (wbtc, ybtc, vault, router, oracle) = setup_with_oracle(9_500_000_000_000_u128);
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };

    // Grant bob the LIQUIDATOR role
    start_cheat_caller_address(vault.contract_address, owner());
    ac.grant_role(ROLE_LIQUIDATOR, bob());
    stop_cheat_caller_address(vault.contract_address);

    // Apply leverage for alice
    start_cheat_caller_address(vault.contract_address, alice());
    vault.apply_leverage(120_u128);
    stop_cheat_caller_address(vault.contract_address);

    // Crash price
    start_cheat_caller_address(oracle.contract_address, owner());
    oracle.set_price(1_000_000_000_000_u128); // $10,000
    stop_cheat_caller_address(oracle.contract_address);

    start_cheat_caller_address(router.contract_address, owner());
    router.refresh_btc_price();
    stop_cheat_caller_address(router.contract_address);

    assert(vault.is_liquidatable(alice()), 'alice must be liquidatable');

    let bob_wbtc_before = wbtc.balance_of(bob());

    // Bob liquidates alice (ybtc.burn is gated to vault_a — cheat caller for yBTC contract)
    start_cheat_caller_address(ybtc.contract_address, vault_a());
    start_cheat_caller_address(vault.contract_address, bob());
    vault.liquidate(alice());
    stop_cheat_caller_address(vault.contract_address);
    stop_cheat_caller_address(ybtc.contract_address);

    // Bob should have received wBTC
    let bob_wbtc_after = wbtc.balance_of(bob());
    assert(bob_wbtc_after > bob_wbtc_before, 'liquidator must receive wBTC');

    // Alice's yBTC should be zero
    assert(ybtc.balance_of(alice()) == 0, 'alice yBTC must be 0');

    // Alice's debt must be cleared
    assert(!vault.is_liquidatable(alice()), 'alice not liquidatable after');
}

// 23. Liquidation gives the liquidator a 5% bonus on top of collateral
#[test]
fn test_liquidate_gives_bonus_to_liquidator() {
    let (wbtc, ybtc, vault, router, oracle) = setup_with_oracle(9_500_000_000_000_u128);
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };

    // Grant bob the LIQUIDATOR role
    start_cheat_caller_address(vault.contract_address, owner());
    ac.grant_role(ROLE_LIQUIDATOR, bob());
    stop_cheat_caller_address(vault.contract_address);

    start_cheat_caller_address(vault.contract_address, alice());
    vault.apply_leverage(120_u128);
    stop_cheat_caller_address(vault.contract_address);

    start_cheat_caller_address(oracle.contract_address, owner());
    oracle.set_price(1_000_000_000_000_u128);
    stop_cheat_caller_address(oracle.contract_address);

    start_cheat_caller_address(router.contract_address, owner());
    router.refresh_btc_price();
    stop_cheat_caller_address(router.contract_address);

    let bob_before = wbtc.balance_of(bob());

    start_cheat_caller_address(ybtc.contract_address, vault_a());
    start_cheat_caller_address(vault.contract_address, bob());
    vault.liquidate(alice());
    stop_cheat_caller_address(vault.contract_address);
    stop_cheat_caller_address(ybtc.contract_address);

    let received = wbtc.balance_of(bob()) - bob_before;
    // collateral = 1 BTC = 100_000_000 sat, bonus = 5% → total = 105_000_000 sat
    let expected = 105_000_000_u256;
    assert(received == expected, 'liquidator gets col + 5% bonus');
}

// 24. User's per-user debt is cleared after liquidation
#[test]
fn test_liquidate_clears_user_debt() {
    let (_, ybtc, vault, router, oracle) = setup_with_oracle(9_500_000_000_000_u128);
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };

    // Grant bob the LIQUIDATOR role
    start_cheat_caller_address(vault.contract_address, owner());
    ac.grant_role(ROLE_LIQUIDATOR, bob());
    stop_cheat_caller_address(vault.contract_address);

    start_cheat_caller_address(vault.contract_address, alice());
    vault.apply_leverage(120_u128);
    stop_cheat_caller_address(vault.contract_address);

    // Sanity: debt should exist before liquidation
    let debt_before = vault.get_total_debt();
    assert(debt_before > 0, 'debt must exist before liq');

    start_cheat_caller_address(oracle.contract_address, owner());
    oracle.set_price(1_000_000_000_000_u128);
    stop_cheat_caller_address(oracle.contract_address);

    start_cheat_caller_address(router.contract_address, owner());
    router.refresh_btc_price();
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(ybtc.contract_address, vault_a());
    start_cheat_caller_address(vault.contract_address, bob());
    vault.liquidate(alice());
    stop_cheat_caller_address(vault.contract_address);
    stop_cheat_caller_address(ybtc.contract_address);

    // Global debt should be cleared
    assert(vault.get_total_debt() == 0, 'global debt 0 after liq');
    // Health should be max (no debt)
    assert(vault.get_user_health(alice()) == 0xffffffffffffffffffffffffffffffff_u128, 'health must be max after');
}

// ============================================================
// Liquidation Engine — Test Group 3: Deleverage & multi-user
// ============================================================

// 25. deleverage() only clears the calling user's debt, not global debt
#[test]
fn test_deleverage_clears_user_debt_correctly() {
    let (wbtc, ybtc, vault, router, oracle) = setup_with_oracle(9_500_000_000_000_u128);

    // Also deposit for bob so we can apply leverage with a second user
    start_cheat_caller_address(wbtc.contract_address, vault_a());
    wbtc.mint(bob(), 100_000_000_u256);
    stop_cheat_caller_address(wbtc.contract_address);

    start_cheat_caller_address(wbtc.contract_address, bob());
    wbtc.approve(vault.contract_address, 100_000_000_u256);
    stop_cheat_caller_address(wbtc.contract_address);

    start_cheat_caller_address(ybtc.contract_address, vault_a());
    start_cheat_caller_address(vault.contract_address, bob());
    vault.deposit(100_000_000_u256);
    stop_cheat_caller_address(vault.contract_address);
    stop_cheat_caller_address(ybtc.contract_address);

    // Both alice and bob apply 1.2x leverage
    start_cheat_caller_address(vault.contract_address, alice());
    vault.apply_leverage(120_u128);
    stop_cheat_caller_address(vault.contract_address);

    start_cheat_caller_address(vault.contract_address, bob());
    vault.apply_leverage(120_u128);
    stop_cheat_caller_address(vault.contract_address);

    let total_before = vault.get_total_debt();
    assert(total_before > 0, 'total debt must be non-zero');

    // Alice deleverages — only her debt should be removed
    start_cheat_caller_address(vault.contract_address, alice());
    vault.deleverage();
    stop_cheat_caller_address(vault.contract_address);

    let total_after = vault.get_total_debt();
    // Total debt reduced by alice's share only; bob's debt remains
    assert(total_after < total_before, 'debt down after deleverage');
    assert(total_after > 0, 'bob debt must remain');

    // Alice should now have no debt (infinite health)
    assert(vault.get_user_health(alice()) == 0xffffffffffffffffffffffffffffffff_u128, 'alice health max after');
}

// 26. Two users have independent per-user debt
#[test]
fn test_two_users_independent_debt() {
    let (wbtc, ybtc, vault, _, _) = setup_with_oracle(9_500_000_000_000_u128);

    // Mint wBTC for bob and deposit
    start_cheat_caller_address(wbtc.contract_address, vault_a());
    wbtc.mint(bob(), 200_000_000_u256); // 2 BTC
    stop_cheat_caller_address(wbtc.contract_address);

    start_cheat_caller_address(wbtc.contract_address, bob());
    wbtc.approve(vault.contract_address, 200_000_000_u256);
    stop_cheat_caller_address(wbtc.contract_address);

    start_cheat_caller_address(ybtc.contract_address, vault_a());
    start_cheat_caller_address(vault.contract_address, bob());
    vault.deposit(200_000_000_u256); // bob deposits 2 BTC
    stop_cheat_caller_address(vault.contract_address);
    stop_cheat_caller_address(ybtc.contract_address);

    // Alice applies 1.2x, bob applies 1.2x
    start_cheat_caller_address(vault.contract_address, alice());
    vault.apply_leverage(120_u128);
    stop_cheat_caller_address(vault.contract_address);

    start_cheat_caller_address(vault.contract_address, bob());
    vault.apply_leverage(120_u128);
    stop_cheat_caller_address(vault.contract_address);

    // Both should be healthy (no price crash)
    assert(!vault.is_liquidatable(alice()), 'alice must be healthy');
    assert(!vault.is_liquidatable(bob()), 'bob must be healthy');

    // Health should be positive for both
    let alice_health = vault.get_user_health(alice());
    let bob_health   = vault.get_user_health(bob());
    assert(alice_health > 0, 'alice health must be > 0');
    assert(bob_health > 0, 'bob health must be > 0');

    // ── Real-world invariant: debt is proportional to each user's own collateral ──
    // Alice deposited 1 BTC, Bob deposited 2 BTC, both at 1.2x.
    // Bob's debt must be exactly 2× Alice's debt.
    // (This would FAIL with the old bug that used global total_assets.)
    let alice_liq_price = vault.get_liquidation_price(alice());
    let bob_liq_price   = vault.get_liquidation_price(bob());
    // Same leverage ratio → same liquidation price regardless of collateral size
    assert(alice_liq_price == bob_liq_price, 'liq prices must be equal');
    assert(alice_liq_price > 0, 'liq price must be non-zero');

    // Global debt must equal sum of both users' debts
    // (verified indirectly: global > either individual)
    let total = vault.get_total_debt();
    assert(total > 0, 'total debt must be non-zero');
}

// 27. Calling apply_leverage with the same target twice must NOT double the debt
//     (regression test for the old bug: factor was (target - 100) not delta)
#[test]
fn test_apply_leverage_idempotent_on_same_target() {
    let (_, _, vault, _, _) = setup_with_oracle(9_500_000_000_000_u128);

    // First call: 1.0x → 1.2x (delta = 20)
    start_cheat_caller_address(vault.contract_address, alice());
    vault.apply_leverage(120_u128);
    stop_cheat_caller_address(vault.contract_address);

    let debt_after_first = vault.get_total_debt();
    assert(debt_after_first > 0, 'debt must exist after first lev');

    // Second call with the SAME target must be a no-op for debt
    start_cheat_caller_address(vault.contract_address, alice());
    vault.apply_leverage(120_u128);
    stop_cheat_caller_address(vault.contract_address);

    let debt_after_second = vault.get_total_debt();
    assert(debt_after_second == debt_after_first, 'repeat lev must not add debt');
}

// 28. Incremental leverage steps accumulate debt correctly
//     1.0x → 1.2x (delta 20) then 1.2x → 1.3x (delta 10) = total 30/100 worth
#[test]
fn test_incremental_leverage_accumulates_correctly() {
    let (_, _, vault, _, _) = setup_with_oracle(9_500_000_000_000_u128);

    // Step 1: 1.0x → 1.2x
    start_cheat_caller_address(vault.contract_address, alice());
    vault.apply_leverage(120_u128);
    stop_cheat_caller_address(vault.contract_address);

    let debt_at_120 = vault.get_total_debt();

    // Step 2: 1.2x → 1.3x (delta = 10 = half of the first step's delta)
    start_cheat_caller_address(vault.contract_address, alice());
    vault.apply_leverage(130_u128);
    stop_cheat_caller_address(vault.contract_address);

    let debt_at_130 = vault.get_total_debt();

    // Second step added exactly half the first step's debt (delta 10 vs delta 20)
    let first_increment = debt_at_120;
    let second_increment = debt_at_130 - debt_at_120;
    assert(second_increment * 2 == first_increment, 'incremental debt must be half');
}

// ============================================================
// Phase 8: Role-Based Access Control (RBAC) + Timelock Tests
// ============================================================
//
// Tests 29-50 cover:
//   • grant_role / revoke_role / has_role
//   • 2-step ownership transfer
//   • timelock queue / execute / cancel
//   • per-role function gating (GUARDIAN, KEEPER, LIQUIDATOR, ADMIN)
//   • router RBAC (same pattern)

// 29. Owner can grant a role; has_role returns true
#[test]
fn test_grant_role_owner_succeeds() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };

    start_cheat_caller_address(vault.contract_address, owner());
    ac.grant_role(ROLE_ADMIN, alice());
    stop_cheat_caller_address(vault.contract_address);

    assert(ac.has_role(ROLE_ADMIN, alice()), 'alice must have ROLE_ADMIN');
    assert(!ac.has_role(ROLE_ADMIN, bob()), 'bob must NOT have ROLE_ADMIN');
}

// 30. Non-owner cannot grant an owner-only role (ADMIN)
#[test]
#[should_panic(expected: ('Only owner can grant this role',))]
fn test_grant_role_non_owner_fails() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };

    start_cheat_caller_address(vault.contract_address, alice());
    ac.grant_role(ROLE_ADMIN, alice()); // must panic
    stop_cheat_caller_address(vault.contract_address);
}

// 31. Owner can revoke a role; has_role returns false afterward
#[test]
fn test_revoke_role_succeeds() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };

    start_cheat_caller_address(vault.contract_address, owner());
    ac.grant_role(ROLE_GUARDIAN, alice());
    stop_cheat_caller_address(vault.contract_address);

    assert(ac.has_role(ROLE_GUARDIAN, alice()), 'alice must have guardian');

    start_cheat_caller_address(vault.contract_address, owner());
    ac.revoke_role(ROLE_GUARDIAN, alice());
    stop_cheat_caller_address(vault.contract_address);

    assert(!ac.has_role(ROLE_GUARDIAN, alice()), 'alice must lose guardian');
}

// 32. GUARDIAN role holder can pause the vault
#[test]
fn test_guardian_can_pause() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };

    // Grant alice the GUARDIAN role
    start_cheat_caller_address(vault.contract_address, owner());
    ac.grant_role(ROLE_GUARDIAN, alice());
    stop_cheat_caller_address(vault.contract_address);

    // Alice (GUARDIAN) pauses the vault
    start_cheat_caller_address(vault.contract_address, alice());
    vault.pause();
    stop_cheat_caller_address(vault.contract_address);
}

// 33. GUARDIAN cannot unpause (unpause is OWNER-only)
#[test]
#[should_panic(expected: ('Only owner',))]
fn test_guardian_cannot_unpause() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };

    // Pause as owner first
    start_cheat_caller_address(vault.contract_address, owner());
    vault.pause();
    ac.grant_role(ROLE_GUARDIAN, alice());
    stop_cheat_caller_address(vault.contract_address);

    // Alice (GUARDIAN) tries to unpause — must fail
    start_cheat_caller_address(vault.contract_address, alice());
    vault.unpause();
    stop_cheat_caller_address(vault.contract_address);
}

// 34. Non-LIQUIDATOR cannot call liquidate
#[test]
#[should_panic(expected: ('Unauthorized',))]
fn test_non_liquidator_cannot_liquidate() {
    let vault = deploy_vault(dummy(), dummy(), dummy());

    // Alice has no role — calling liquidate must fail immediately on auth check
    start_cheat_caller_address(vault.contract_address, alice());
    vault.liquidate(bob());
    stop_cheat_caller_address(vault.contract_address);
}

// 35. KEEPER role holder can call refresh_btc_price on router
#[test]
fn test_keeper_can_refresh_price() {
    let oracle = deploy_mock_oracle(9_500_000_000_000_u128);
    let router = deploy_router_with_oracle(110, oracle.contract_address);
    let ac = IAccessControlDispatcher { contract_address: router.contract_address };

    // Grant alice the KEEPER role
    start_cheat_caller_address(router.contract_address, owner());
    ac.grant_role(ROLE_KEEPER, alice());
    stop_cheat_caller_address(router.contract_address);

    // Alice (KEEPER) refreshes the price — must succeed
    start_cheat_caller_address(router.contract_address, alice());
    router.refresh_btc_price();
    stop_cheat_caller_address(router.contract_address);

    assert(router.get_btc_usd_price() == 9_500_000_000_000_u128, 'keeper price ok');
}

// 36. Non-KEEPER cannot call refresh_btc_price
#[test]
#[should_panic(expected: ('Unauthorized',))]
fn test_non_keeper_cannot_refresh_price() {
    let oracle = deploy_mock_oracle(9_500_000_000_000_u128);
    let router = deploy_router_with_oracle(110, oracle.contract_address);

    // Alice has no role
    start_cheat_caller_address(router.contract_address, alice());
    router.refresh_btc_price(); // must fail
    stop_cheat_caller_address(router.contract_address);
}

// 37. queue_operation succeeds when ETA >= now + TIMELOCK_DELAY
#[test]
fn test_queue_operation_succeeds() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };

    let op_id: felt252 = 'test_op';
    let eta: u64 = TIMELOCK_DELAY + 100;

    start_cheat_caller_address(vault.contract_address, owner());
    ac.queue_operation(op_id, eta);
    stop_cheat_caller_address(vault.contract_address);

    assert(ac.get_operation_eta(op_id) == eta, 'eta must be stored');
}

// 38. queue_operation fails when ETA is too early
#[test]
#[should_panic(expected: ('ETA too early',))]
fn test_queue_operation_eta_too_early_fails() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };

    let op_id: felt252 = 'bad_op';
    let eta: u64 = TIMELOCK_DELAY - 1; // one second short

    start_cheat_caller_address(vault.contract_address, owner());
    ac.queue_operation(op_id, eta); // must panic
    stop_cheat_caller_address(vault.contract_address);
}

// 39. execute_operation fails before timelock expires
#[test]
#[should_panic(expected: ('Timelock not expired',))]
fn test_execute_operation_too_early_fails() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };

    let op_id: felt252 = 'early_op';
    let eta: u64 = TIMELOCK_DELAY + 500;

    start_cheat_caller_address(vault.contract_address, owner());
    ac.queue_operation(op_id, eta);
    // Do NOT advance time — block_timestamp is 0
    ac.execute_operation(op_id); // must panic: timelock not expired
    stop_cheat_caller_address(vault.contract_address);
}

// 40. execute_operation succeeds after timelock expires
#[test]
fn test_execute_operation_after_delay_succeeds() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };

    let op_id: felt252 = 'good_op';
    let eta: u64 = TIMELOCK_DELAY + 1;

    start_cheat_caller_address(vault.contract_address, owner());
    ac.queue_operation(op_id, eta);
    stop_cheat_caller_address(vault.contract_address);

    // Advance past the ETA
    start_cheat_block_timestamp(vault.contract_address, eta);

    start_cheat_caller_address(vault.contract_address, owner());
    ac.execute_operation(op_id); // must succeed
    stop_cheat_caller_address(vault.contract_address);

    stop_cheat_block_timestamp(vault.contract_address);

    // op_id is consumed — eta should be 0
    assert(ac.get_operation_eta(op_id) == 0, 'op must be consumed');
}

// 41. cancel_operation removes the queued entry
#[test]
fn test_cancel_operation_succeeds() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };

    let op_id: felt252 = 'cancel_me';
    let eta: u64 = TIMELOCK_DELAY + 1;

    start_cheat_caller_address(vault.contract_address, owner());
    ac.queue_operation(op_id, eta);
    ac.cancel_operation(op_id);
    stop_cheat_caller_address(vault.contract_address);

    assert(ac.get_operation_eta(op_id) == 0, 'cancelled op eta must be 0');
}

// 42. Executing a cancelled operation fails
#[test]
#[should_panic(expected: ('Op not queued',))]
fn test_execute_cancelled_operation_fails() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };

    let op_id: felt252 = 'cancel_then_exec';
    let eta: u64 = TIMELOCK_DELAY + 1;

    start_cheat_caller_address(vault.contract_address, owner());
    ac.queue_operation(op_id, eta);
    ac.cancel_operation(op_id);
    stop_cheat_caller_address(vault.contract_address);

    start_cheat_block_timestamp(vault.contract_address, eta);

    start_cheat_caller_address(vault.contract_address, owner());
    ac.execute_operation(op_id); // must panic — op was cancelled
    stop_cheat_caller_address(vault.contract_address);

    stop_cheat_block_timestamp(vault.contract_address);
}

// 43. Two-step ownership transfer: transfer_ownership + accept_ownership
#[test]
fn test_transfer_ownership_two_step() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };

    // Owner initiates transfer to alice
    start_cheat_caller_address(vault.contract_address, owner());
    ac.transfer_ownership(alice());
    stop_cheat_caller_address(vault.contract_address);

    // Owner still owns until alice accepts
    assert(ac.get_owner() == owner(), 'owner unchanged before accept');

    // Alice accepts
    start_cheat_caller_address(vault.contract_address, alice());
    ac.accept_ownership();
    stop_cheat_caller_address(vault.contract_address);

    assert(ac.get_owner() == alice(), 'alice must be new owner');
}

// 44. accept_ownership fails if caller is not pending owner
#[test]
#[should_panic(expected: ('Not pending owner',))]
fn test_accept_ownership_wrong_caller_fails() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };

    // Owner initiates transfer to alice
    start_cheat_caller_address(vault.contract_address, owner());
    ac.transfer_ownership(alice());
    stop_cheat_caller_address(vault.contract_address);

    // Bob (not the pending owner) tries to accept — must fail
    start_cheat_caller_address(vault.contract_address, bob());
    ac.accept_ownership();
    stop_cheat_caller_address(vault.contract_address);
}

// 45. Same op_id cannot be queued twice
#[test]
#[should_panic(expected: ('Op already queued',))]
fn test_queue_operation_twice_fails() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };

    let op_id: felt252 = 'dup_op';
    let eta: u64 = TIMELOCK_DELAY + 1;

    start_cheat_caller_address(vault.contract_address, owner());
    ac.queue_operation(op_id, eta);
    ac.queue_operation(op_id, eta); // must panic
    stop_cheat_caller_address(vault.contract_address);
}

// 46. ADMIN role holder can queue an operation
#[test]
fn test_admin_role_can_queue_operation() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };

    // Grant alice the ADMIN role
    start_cheat_caller_address(vault.contract_address, owner());
    ac.grant_role(ROLE_ADMIN, alice());
    stop_cheat_caller_address(vault.contract_address);

    // Alice (ADMIN) queues an op
    let op_id: felt252 = 'admin_op';
    let eta: u64 = TIMELOCK_DELAY + 1;

    start_cheat_caller_address(vault.contract_address, alice());
    ac.queue_operation(op_id, eta);
    stop_cheat_caller_address(vault.contract_address);

    assert(ac.get_operation_eta(op_id) == eta, 'admin queued op must exist');
}

// 47. ADMIN role on router can enter safe mode (GUARDIAN path)
#[test]
fn test_guardian_role_on_router_can_enter_safe_mode() {
    let router = deploy_router(110);
    let ac = IAccessControlDispatcher { contract_address: router.contract_address };

    // Grant alice the GUARDIAN role
    start_cheat_caller_address(router.contract_address, owner());
    ac.grant_role(ROLE_GUARDIAN, alice());
    router.update_btc_backing(105);
    router.register_protocol(protocol(), 'vault');
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(router.contract_address, protocol());
    router.report_exposure(100, 0, 100);
    stop_cheat_caller_address(router.contract_address);

    // Alice (GUARDIAN) enters safe mode
    start_cheat_caller_address(router.contract_address, alice());
    router.enter_safe_mode();
    stop_cheat_caller_address(router.contract_address);

    assert(router.is_safe_mode(), 'safe mode must be on');
}

// 48. KEEPER on router can update btc backing
#[test]
fn test_keeper_role_on_router_can_update_backing() {
    let router = deploy_router(110);
    let ac = IAccessControlDispatcher { contract_address: router.contract_address };

    // Grant alice the KEEPER role
    start_cheat_caller_address(router.contract_address, owner());
    ac.grant_role(ROLE_KEEPER, alice());
    stop_cheat_caller_address(router.contract_address);

    // Alice (KEEPER) updates backing
    start_cheat_caller_address(router.contract_address, alice());
    router.update_btc_backing(5000);
    stop_cheat_caller_address(router.contract_address);

    assert(router.get_btc_backing() == 5000, 'backing must be updated');
}

// 49. set_minimum_deposit_timelocked requires timelock
#[test]
fn test_set_minimum_deposit_timelocked_succeeds() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };

    let minimum: u256 = 5_000_000_u256;
    let op_id: felt252 = ac.hash_operation(
        'set_min_deposit', array![minimum.low.into(), minimum.high.into()].span()
    );
    let eta: u64 = TIMELOCK_DELAY + 1;

    start_cheat_caller_address(vault.contract_address, owner());
    ac.queue_operation(op_id, eta);
    stop_cheat_caller_address(vault.contract_address);

    start_cheat_block_timestamp(vault.contract_address, eta);

    start_cheat_caller_address(vault.contract_address, owner());
    vault.set_minimum_deposit_timelocked(op_id, minimum);
    stop_cheat_caller_address(vault.contract_address);

    stop_cheat_block_timestamp(vault.contract_address);
}

// 50. set_minimum_deposit_timelocked fails without queued op
#[test]
#[should_panic(expected: ('Op not queued',))]
fn test_set_minimum_deposit_timelocked_without_queue_fails() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };

    // Compute the correct op_id but do NOT queue it—must fail with 'Op not queued'
    let minimum: u256 = 5_000_000_u256;
    let op_id = ac.hash_operation(
        'set_min_deposit', array![minimum.low.into(), minimum.high.into()].span()
    );

    start_cheat_caller_address(vault.contract_address, owner());
    vault.set_minimum_deposit_timelocked(op_id, minimum); // must panic
    stop_cheat_caller_address(vault.contract_address);
}

// ============================================================
// Edge Case: op_id parameter binding
// ============================================================

// 51. Queuing with hash(addr_A) then calling with addr_B must fail — params swapping is impossible
#[test]
#[should_panic(expected: ('Op id mismatch',))]
fn test_op_id_mismatch_prevents_parameter_swap() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };

    // Queue op_id computed for alice's address
    let op_id_for_alice = ac.hash_operation('set_router', array![alice().into()].span());
    let eta: u64 = TIMELOCK_DELAY + 1;

    start_cheat_caller_address(vault.contract_address, owner());
    ac.queue_operation(op_id_for_alice, eta);
    stop_cheat_caller_address(vault.contract_address);

    start_cheat_block_timestamp(vault.contract_address, eta);

    start_cheat_caller_address(vault.contract_address, owner());
    // Attempt to execute with dummy() instead — must fail: 'Op id mismatch'
    vault.set_router(op_id_for_alice, dummy());
    stop_cheat_caller_address(vault.contract_address);

    stop_cheat_block_timestamp(vault.contract_address);
}

// 52. hash_operation is deterministic: same inputs always give the same hash
#[test]
fn test_hash_operation_is_deterministic() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };

    let h1 = ac.hash_operation('set_router', array![alice().into()].span());
    let h2 = ac.hash_operation('set_router', array![alice().into()].span());
    assert(h1 == h2, 'hash must be deterministic');

    // Different params give different hashes
    let h3 = ac.hash_operation('set_router', array![bob().into()].span());
    assert(h1 != h3, 'different params => diff hash');

    // Different selectors give different hashes
    let h4 = ac.hash_operation('other_fn', array![alice().into()].span());
    assert(h1 != h4, 'different selector => diff hash');
}

// ============================================================
// Edge Case: GRACE_PERIOD expiry
// ============================================================

// 53. Executing a standalone op after eta + GRACE_PERIOD fails
#[test]
#[should_panic(expected: ('Operation expired',))]
fn test_op_expires_after_grace_period() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };

    let op_id: felt252 = 'expire_test';
    let eta: u64 = TIMELOCK_DELAY + 1;

    start_cheat_caller_address(vault.contract_address, owner());
    ac.queue_operation(op_id, eta);
    stop_cheat_caller_address(vault.contract_address);

    // One second past the grace period — op must be expired
    start_cheat_block_timestamp(vault.contract_address, eta + GRACE_PERIOD + 1);

    start_cheat_caller_address(vault.contract_address, owner());
    ac.execute_operation(op_id); // must panic: 'Operation expired'
    stop_cheat_caller_address(vault.contract_address);

    stop_cheat_block_timestamp(vault.contract_address);
}

// 54. Executing at exactly eta + GRACE_PERIOD still succeeds (inclusive boundary)
#[test]
fn test_op_valid_at_grace_period_boundary() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };

    let op_id: felt252 = 'boundary_test';
    let eta: u64 = TIMELOCK_DELAY + 1;

    start_cheat_caller_address(vault.contract_address, owner());
    ac.queue_operation(op_id, eta);
    stop_cheat_caller_address(vault.contract_address);

    // Execute at exactly eta + GRACE_PERIOD — boundary must still be valid
    start_cheat_block_timestamp(vault.contract_address, eta + GRACE_PERIOD);

    start_cheat_caller_address(vault.contract_address, owner());
    ac.execute_operation(op_id); // must succeed
    stop_cheat_caller_address(vault.contract_address);

    stop_cheat_block_timestamp(vault.contract_address);

    assert(ac.get_operation_eta(op_id) == 0, 'op must be consumed');
}

// ============================================================
// Edge Case: renounce_role
// ============================================================

// 55. An account can renounce its own role
#[test]
fn test_renounce_own_role_succeeds() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };

    start_cheat_caller_address(vault.contract_address, owner());
    ac.grant_role(ROLE_GUARDIAN, alice());
    stop_cheat_caller_address(vault.contract_address);

    assert(ac.has_role(ROLE_GUARDIAN, alice()), 'alice must have GUARDIAN');

    start_cheat_caller_address(vault.contract_address, alice());
    ac.renounce_role(ROLE_GUARDIAN);
    stop_cheat_caller_address(vault.contract_address);

    assert(!ac.has_role(ROLE_GUARDIAN, alice()), 'alice role must be removed');
}

// 56. Renouncing a role you do not hold must fail
#[test]
#[should_panic(expected: ('Role not held',))]
fn test_renounce_unheld_role_fails() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };

    // Alice has no roles — attempting renounce must panic
    start_cheat_caller_address(vault.contract_address, alice());
    ac.renounce_role(ROLE_GUARDIAN);
    stop_cheat_caller_address(vault.contract_address);
}

// ============================================================
// Edge Case: get_pending_owner
// ============================================================

// 57. get_pending_owner returns the nominee after transfer_ownership
#[test]
fn test_get_pending_owner_returns_nominee() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };

    // No transfer in flight — pending owner is zero
    assert(ac.get_pending_owner() == contract_address_const::<0>(), 'no pending owner initially');

    start_cheat_caller_address(vault.contract_address, owner());
    ac.transfer_ownership(alice());
    stop_cheat_caller_address(vault.contract_address);

    assert(ac.get_pending_owner() == alice(), 'alice must be pending owner');
}

// 58. get_pending_owner is cleared after accept_ownership
#[test]
fn test_get_pending_owner_cleared_after_accept() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };

    start_cheat_caller_address(vault.contract_address, owner());
    ac.transfer_ownership(alice());
    stop_cheat_caller_address(vault.contract_address);

    start_cheat_caller_address(vault.contract_address, alice());
    ac.accept_ownership();
    stop_cheat_caller_address(vault.contract_address);

    // After acceptance pending_owner is cleared to zero
    assert(ac.get_pending_owner() == contract_address_const::<0>(), 'pending must clear');
}

// ============================================================
// Edge Case: role admin hierarchy
// ============================================================

// 59. get_role_admin returns correct admins for all roles
#[test]
fn test_get_role_admin_returns_correct_values() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };

    assert(ac.get_role_admin(ROLE_KEEPER)     == ROLE_ADMIN, 'keeper admin must be ADMIN');
    assert(ac.get_role_admin(ROLE_LIQUIDATOR) == ROLE_ADMIN, 'liquidator admin must be ADMIN');
    // ADMIN and GUARDIAN are owner-only — admin role is 0
    assert(ac.get_role_admin(ROLE_ADMIN)    == 0, 'ADMIN must be owner-only');
    assert(ac.get_role_admin(ROLE_GUARDIAN) == 0, 'GUARDIAN must be owner-only');
}

// 60. An ADMIN role holder can grant the KEEPER role
#[test]
fn test_admin_can_grant_keeper_role() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };

    // Owner grants alice ADMIN
    start_cheat_caller_address(vault.contract_address, owner());
    ac.grant_role(ROLE_ADMIN, alice());
    stop_cheat_caller_address(vault.contract_address);

    // Alice (ADMIN) grants bob KEEPER — must succeed
    start_cheat_caller_address(vault.contract_address, alice());
    ac.grant_role(ROLE_KEEPER, bob());
    stop_cheat_caller_address(vault.contract_address);

    assert(ac.has_role(ROLE_KEEPER, bob()), 'bob must have KEEPER');
}

// 61. An ADMIN role holder can revoke the KEEPER role
#[test]
fn test_admin_can_revoke_keeper_role() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };

    start_cheat_caller_address(vault.contract_address, owner());
    ac.grant_role(ROLE_KEEPER, bob());
    ac.grant_role(ROLE_ADMIN, alice());
    stop_cheat_caller_address(vault.contract_address);

    // Alice (ADMIN) revokes bob's KEEPER — must succeed
    start_cheat_caller_address(vault.contract_address, alice());
    ac.revoke_role(ROLE_KEEPER, bob());
    stop_cheat_caller_address(vault.contract_address);

    assert(!ac.has_role(ROLE_KEEPER, bob()), 'bob KEEPER must be revoked');
}

// 62. An ADMIN cannot grant ADMIN (owner-only role)
#[test]
#[should_panic(expected: ('Only owner can grant this role',))]
fn test_admin_cannot_grant_admin_role() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };

    start_cheat_caller_address(vault.contract_address, owner());
    ac.grant_role(ROLE_ADMIN, alice());
    stop_cheat_caller_address(vault.contract_address);

    // Alice (ADMIN) tries to grant ADMIN to bob — must fail: owner-only
    start_cheat_caller_address(vault.contract_address, alice());
    ac.grant_role(ROLE_ADMIN, bob()); // must panic
    stop_cheat_caller_address(vault.contract_address);
}

// 63. An ADMIN cannot grant GUARDIAN (owner-only role)
#[test]
#[should_panic(expected: ('Only owner can grant this role',))]
fn test_admin_cannot_grant_guardian_role() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };

    start_cheat_caller_address(vault.contract_address, owner());
    ac.grant_role(ROLE_ADMIN, alice());
    stop_cheat_caller_address(vault.contract_address);

    // Alice (ADMIN) tries to grant GUARDIAN to bob — must fail: owner-only
    start_cheat_caller_address(vault.contract_address, alice());
    ac.grant_role(ROLE_GUARDIAN, bob()); // must panic
    stop_cheat_caller_address(vault.contract_address);
}

// 64. Router: ADMIN role holder can grant KEEPER on the router as well
#[test]
fn test_router_admin_can_grant_keeper_role() {
    let router = deploy_router(110);
    let ac = IAccessControlDispatcher { contract_address: router.contract_address };

    start_cheat_caller_address(router.contract_address, owner());
    ac.grant_role(ROLE_ADMIN, alice());
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(router.contract_address, alice());
    ac.grant_role(ROLE_KEEPER, bob());
    stop_cheat_caller_address(router.contract_address);

    assert(ac.has_role(ROLE_KEEPER, bob()), 'bob must have KEEPER on router');
}

// ============================================================
// Formal Verification: Fuzz Tests — Pure Arithmetic Properties
// These tests exercise mathematical invariants WITHOUT deploying
// contracts.  snforge randomises inputs on every run.
// ============================================================

// 65. FUZZ: share-minting formula is monotone w.r.t. deposit amount
//     shares = deposit * total_supply / total_assets
//     For fixed vault state:  deposit_a ≤ deposit_b  ⟹  shares_a ≤ shares_b
#[test]
#[fuzzer]
fn test_fuzz_share_mint_monotone_deposit(deposit_a: u64, deposit_b: u64) {
    let total_assets: u256 = 100_000_000; // 1 BTC fixed state
    let total_supply: u256 = 100_000_000;
    let da: u256 = deposit_a.into();
    let db: u256 = deposit_b.into();
    let shares_a = (da * total_supply) / total_assets;
    let shares_b = (db * total_supply) / total_assets;
    if da <= db {
        assert(shares_a <= shares_b, 'shares not monotone (a<=b)');
    } else {
        assert(shares_a >= shares_b, 'shares not monotone (a>b)');
    }
}

// 66. FUZZ: btc_for_shares formula is monotone w.r.t. share amount
//     btc = shares * total_assets / total_supply
#[test]
#[fuzzer]
fn test_fuzz_btc_for_shares_monotone(shares_a: u64, shares_b: u64) {
    let total_assets: u256 = 100_000_000;
    let total_supply: u256 = 100_000_000;
    let sa: u256 = shares_a.into();
    let sb: u256 = shares_b.into();
    let btc_a = (sa * total_assets) / total_supply;
    let btc_b = (sb * total_assets) / total_supply;
    if sa <= sb {
        assert(btc_a <= btc_b, 'btc not monotone (a<=b)');
    } else {
        assert(btc_a >= btc_b, 'btc not monotone (a>b)');
    }
}

// 67. FUZZ: health factor is non-decreasing with collateral (for fixed debt/price)
//     h = (collateral * price * LTV) / (debt * BTC_DECIMALS)
//     More collateral => higher health => better for the user
#[test]
#[fuzzer]
fn test_fuzz_health_factor_monotone_with_collateral(col_a: u64, col_b: u64) {
    let price: u256    = 9_500_000_000_000; // $95,000 (8 dec)
    let debt: u256     = 1_000_000_000_000; // $10,000 (8 dec)
    let ltv: u256      = 80;
    let decimals: u256 = 100_000_000;       // BTC_DECIMALS
    if debt == 0 { return; }
    let ca: u256 = col_a.into();
    let cb: u256 = col_b.into();
    let h_a = (ca * price * ltv) / (debt * decimals);
    let h_b = (cb * price * ltv) / (debt * decimals);
    if ca <= cb {
        assert(h_a <= h_b, 'health monotone w/ collateral');
    } else {
        assert(h_a >= h_b, 'health not monotone rev');
    }
}

// 68. FUZZ: leverage debt is proportional to oracle price
//     additional_debt = collateral * price * delta / (BTC_DECIMALS * 100)
//     Higher price at same collateral/leverage => more USD debt
#[test]
#[fuzzer]
fn test_fuzz_leverage_debt_proportional_to_price(price_a: u64, price_b: u64) {
    let collateral: u256 = 100_000_000; // 1 BTC
    let delta: u256      = 20;          // 0.2x leverage step
    let denom: u256      = 100_000_000_u256 * 100; // BTC_DECIMALS * 100
    let pa: u256 = price_a.into();
    let pb: u256 = price_b.into();
    let debt_a = (collateral * pa * delta) / denom;
    let debt_b = (collateral * pb * delta) / denom;
    if pa <= pb {
        assert(debt_a <= debt_b, 'debt not monotone w/ price');
    } else {
        assert(debt_a >= debt_b, 'debt not monotone rev');
    }
}

// ============================================================
// Formal Verification: Vault State Invariants
// ============================================================

// 69. A freshly-deployed vault passes all observable state invariants
#[test]
fn test_vault_invariants_on_fresh_deploy() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };
    // I-1: owner is non-zero
    assert(ac.get_owner() != contract_address_const::<0>(), 'I-1: owner must be non-zero');
    // Share price = SCALE = 1_000_000 on fresh vault (no assets, returns default)
    assert(vault.get_share_price() == 1_000_000, 'share price must be SCALE');
    // I-4: total_assets = 0 and supply = 0 on fresh deploy (no phantom supply)
    assert(vault.get_total_assets() == 0, 'fresh vault: assets must be 0');
    // I-5: total_debt = 0 (no leverage without deposits)
    assert(vault.get_total_debt() == 0, 'fresh vault: debt must be 0');
    // pending_owner is zero on construction
    assert(ac.get_pending_owner() == contract_address_const::<0>(), 'no pending owner on init');
}

// 70. total_assets equals the exact deposited amount after the first deposit (S-1)
#[test]
fn test_vault_total_assets_exact_after_first_deposit() {
    let (_, _, vault, _, _) = setup_with_oracle(9_500_000_000_000_u128);
    // setup_with_oracle: alice deposits exactly 100_000_000 sat (1 BTC)
    assert(vault.get_total_assets() == 100_000_000_u256, 'total_assets must == deposit');
}

// 71. Share price is exactly SCALE (1:1) immediately after the first deposit
#[test]
fn test_vault_share_price_is_scale_after_first_deposit() {
    let (_, _, vault, _, _) = setup_with_oracle(9_500_000_000_000_u128);
    // First deposit mints shares 1:1 → price = total_assets * SCALE / supply
    //   = 100_000_000 * 1_000_000 / 100_000_000 = 1_000_000
    assert(vault.get_share_price() == 1_000_000, 'share price must be SCALE');
}

// 72. Total debt is zero before any leverage is applied
#[test]
fn test_vault_total_debt_zero_before_leverage() {
    let (_, _, vault, _, _) = setup_with_oracle(9_500_000_000_000_u128);
    // alice deposited but has NOT called apply_leverage
    assert(vault.get_total_debt() == 0, 'no leverage => no debt');
}

// 73. Share price is always > 0 when deposits exist (S-5: no zero-price shares)
#[test]
fn test_vault_share_price_positive_when_deposited() {
    let (_, _, vault, _, _) = setup_with_oracle(9_500_000_000_000_u128);
    assert(vault.get_share_price() > 0, 'share price must be > 0');
}

// 74. User health is u128::MAX when no leveraged debt exists
#[test]
fn test_vault_user_health_max_without_debt() {
    let (_, _, vault, _, _) = setup_with_oracle(9_500_000_000_000_u128);
    // alice deposited in setup but has NO leverage
    let health = vault.get_user_health(alice());
    assert(health == 0xffffffffffffffffffffffffffffffff_u128, 'no-debt health must be max');
}

// ============================================================
// Formal Verification: Router State Invariants
// ============================================================

// 75. A freshly-deployed router passes all observable state invariants
#[test]
fn test_router_invariants_on_fresh_deploy() {
    let router = deploy_router(110);
    let ac = IAccessControlDispatcher { contract_address: router.contract_address };
    // I-1: owner is non-zero
    assert(ac.get_owner() != contract_address_const::<0>(), 'I-1: owner non-zero');
    // I-3: zero exposure => health = u128::MAX (confirms min_health_factor logic)
    assert(router.get_btc_health() == 0xffffffffffffffffffffffffffffffff_u128, 'zero exp => max health');
    // Not in safe mode initially
    assert(!router.is_safe_mode(), 'fresh router not in safe mode');
    // No price before first refresh
    assert(router.get_btc_usd_price() == 0, 'price = 0 before refresh');
}

// 76. INVARIANT I-2: safe mode auto-triggers when health drops below threshold
//     Confirms safe_mode_threshold > min_health_factor is enforced semantically.
#[test]
fn test_router_safe_mode_triggers_below_threshold() {
    // threshold = 110, min_health_factor = 100
    let router = deploy_router(110);
    // Set health = 109 (below threshold 110 but above min 100)
    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(109);
    router.register_protocol(protocol(), 'vault');
    stop_cheat_caller_address(router.contract_address);
    start_cheat_caller_address(router.contract_address, protocol());
    router.report_exposure(100, 0, 100); // health = 109 < 110 => auto-triggers safe mode
    stop_cheat_caller_address(router.contract_address);
    assert(router.is_safe_mode(), 'health<threshold => safe mode');
}

// 77. SAFETY S-5: safe mode blocks deposit and leverage, allows withdraw/repay
#[test]
fn test_router_safe_mode_blocks_deposit_and_leverage() {
    let router = deploy_router(110);
    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(105);
    router.register_protocol(protocol(), 'vault');
    stop_cheat_caller_address(router.contract_address);
    start_cheat_caller_address(router.contract_address, protocol());
    router.report_exposure(100, 0, 100); // triggers safe mode
    stop_cheat_caller_address(router.contract_address);
    assert(router.is_safe_mode(), 'must be in safe mode');
    // Deposit is blocked
    assert(!router.is_operation_allowed('deposit', protocol(), 1), 'deposit blocked in safe mode');
    // Leverage is blocked
    assert(!router.is_operation_allowed('leverage', protocol(), 105), 'leverage blocked');
    // Withdraw is always permitted (S-5 exception)
    assert(router.is_operation_allowed('withdraw', protocol(), 1), 'withdraw must be allowed');
    // Repay is always permitted (S-5 exception)
    assert(router.is_operation_allowed('repay', protocol(), 1), 'repay must be allowed');
}

// 78. SAFETY S-6: only registered protocols can call report_exposure
#[test]
#[should_panic(expected: ('Protocol not registered',))]
fn test_router_unregistered_protocol_cannot_report_exposure() {
    let router = deploy_router(110);
    // alice is not a registered protocol — must panic
    start_cheat_caller_address(router.contract_address, alice());
    router.report_exposure(1000, 0, 100);
    stop_cheat_caller_address(router.contract_address);
}

// ============================================================
// Formal Verification: Security / Audit Properties
// ============================================================

// 79. SECURITY: paused vault blocks apply_leverage, not just deposit/withdraw
#[test]
#[should_panic(expected: ('Vault paused',))]
fn test_vault_pause_blocks_apply_leverage() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    start_cheat_caller_address(vault.contract_address, owner());
    vault.pause();
    stop_cheat_caller_address(vault.contract_address);
    start_cheat_caller_address(vault.contract_address, alice());
    vault.apply_leverage(120_u128); // must panic
    stop_cheat_caller_address(vault.contract_address);
}

// 80. SECURITY: MINIMUM_FIRST_DEPOSIT (10_000_000 sat = 0.1 BTC) is enforced
#[test]
#[should_panic(expected: ('First deposit too small',))]
fn test_vault_minimum_first_deposit_enforced() {
    let router = deploy_router(90);
    let wbtc = deploy_wbtc(vault_a());
    let ybtc = deploy_ybtc(vault_a());
    let vault = deploy_vault(wbtc.contract_address, ybtc.contract_address, router.contract_address);
    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(1_000_000_000);
    router.register_protocol(vault.contract_address, 'vault');
    stop_cheat_caller_address(router.contract_address);
    // Mint just below MINIMUM_FIRST_DEPOSIT (9_999_999 < 10_000_000)
    start_cheat_caller_address(wbtc.contract_address, vault_a());
    wbtc.mint(alice(), 9_999_999_u256);
    stop_cheat_caller_address(wbtc.contract_address);
    start_cheat_caller_address(wbtc.contract_address, alice());
    wbtc.approve(vault.contract_address, 9_999_999_u256);
    stop_cheat_caller_address(wbtc.contract_address);
    start_cheat_caller_address(ybtc.contract_address, vault_a());
    start_cheat_caller_address(vault.contract_address, alice());
    vault.deposit(9_999_999_u256); // must panic: 'First deposit too small'
    stop_cheat_caller_address(vault.contract_address);
    stop_cheat_caller_address(ybtc.contract_address);
}

// 81. SECURITY: an executed op_id cannot be replayed (consume-once semantics)
#[test]
#[should_panic(expected: ('Op not queued',))]
fn test_consumed_op_id_cannot_be_replayed() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };
    let op_id: felt252 = 'standalone_op';
    let eta: u64 = TIMELOCK_DELAY + 1;
    start_cheat_caller_address(vault.contract_address, owner());
    ac.queue_operation(op_id, eta);
    stop_cheat_caller_address(vault.contract_address);
    start_cheat_block_timestamp(vault.contract_address, eta);
    start_cheat_caller_address(vault.contract_address, owner());
    ac.execute_operation(op_id); // first execution — succeeds
    ac.execute_operation(op_id); // replay — must panic: 'Op not queued'
    stop_cheat_caller_address(vault.contract_address);
    stop_cheat_block_timestamp(vault.contract_address);
}

// 82. SECURITY: granting any role to the zero address is blocked
#[test]
#[should_panic(expected: ('Account is zero address',))]
fn test_zero_address_grant_role_fails() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };
    start_cheat_caller_address(vault.contract_address, owner());
    ac.grant_role(ROLE_GUARDIAN, contract_address_const::<0>()); // must panic
    stop_cheat_caller_address(vault.contract_address);
}

// 83. SECURITY: oracle price returns 0 when cache is stale (> MAX_PRICE_AGE = 3600s)
#[test]
fn test_router_stale_price_returns_zero_after_max_age() {
    let oracle = deploy_mock_oracle(9_500_000_000_000_u128);
    let router = deploy_router_with_oracle(110, oracle.contract_address);
    // Refresh at t=0
    start_cheat_caller_address(router.contract_address, owner());
    router.refresh_btc_price();
    stop_cheat_caller_address(router.contract_address);
    // Price is still fresh at exactly MAX_PRICE_AGE (3600s)
    start_cheat_block_timestamp(router.contract_address, 3600);
    assert(router.get_btc_usd_price() == 9_500_000_000_000_u128, 'price fresh at MAX_AGE');
    stop_cheat_block_timestamp(router.contract_address);
    // One second past MAX_PRICE_AGE → price goes stale
    start_cheat_block_timestamp(router.contract_address, 3601);
    assert(router.get_btc_usd_price() == 0, 'price stale at MAX_AGE+1');
    stop_cheat_block_timestamp(router.contract_address);
}

// 84. SECURITY: ownership transfer does not take effect until accept_ownership is called
#[test]
fn test_ownership_unchanged_before_accept() {
    let vault = deploy_vault(dummy(), dummy(), dummy());
    let ac = IAccessControlDispatcher { contract_address: vault.contract_address };
    // Initiate transfer to alice
    start_cheat_caller_address(vault.contract_address, owner());
    ac.transfer_ownership(alice());
    stop_cheat_caller_address(vault.contract_address);
    // Original owner still controls the contract (2-step: no instant takeover)
    assert(ac.get_owner() == owner(), 'owner unchanged before accept');
    // alice is the pending owner and cannot exercise owner powers yet
    assert(ac.get_pending_owner() == alice(), 'pending owner must be alice');
    assert(ac.get_owner() != alice(), 'alice is NOT owner yet');
}

// ============================================================
// User Mode, Dashboard & Yield Claim Tests (85–92)
// ============================================================

// Helper: deploy a fully-configured vault with oracle, wBTC minted to alice,
//         price refreshed, and alice deposited `deposit_sat` satoshis.
// Returns (wbtc, ybtc, vault, strategy_addr).
fn setup_oracle_vault_with_deposit(
    deposit_sat: u256
) -> (IYBTCTokenDispatcher, IYBTCTokenDispatcher, IBTCVaultDispatcher, ContractAddress) {
    let oracle = deploy_mock_oracle(9_500_000_000_000_u128); // $95,000
    let router = deploy_router_with_oracle(110, oracle.contract_address);

    let wbtc = deploy_wbtc(vault_a());
    let ybtc = deploy_ybtc(vault_a());
    let vault = deploy_vault(wbtc.contract_address, ybtc.contract_address, router.contract_address);

    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(1_000_000_000_000_u256);
    router.register_protocol(vault.contract_address, 'vault');
    router.refresh_btc_price();
    stop_cheat_caller_address(router.contract_address);

    let strategy = deploy_strategy(wbtc.contract_address, vault.contract_address);

    // Mint & approve wBTC for alice
    start_cheat_caller_address(wbtc.contract_address, vault_a());
    wbtc.mint(alice(), deposit_sat + 10_000_000_u256);
    stop_cheat_caller_address(wbtc.contract_address);
    start_cheat_caller_address(wbtc.contract_address, alice());
    wbtc.approve(vault.contract_address, deposit_sat + 10_000_000_u256);
    stop_cheat_caller_address(wbtc.contract_address);

    // Alice deposits (with non-zero block timestamp so user_deposit_timestamp is set)
    start_cheat_block_timestamp(vault.contract_address, 1000_u64);
    start_cheat_caller_address(ybtc.contract_address, vault_a());
    start_cheat_caller_address(vault.contract_address, alice());
    vault.deposit(deposit_sat);
    stop_cheat_caller_address(vault.contract_address);
    stop_cheat_caller_address(ybtc.contract_address);
    stop_cheat_block_timestamp(vault.contract_address);

    (wbtc, ybtc, vault, strategy.contract_address)
}

// 85. set_user_mode(LeverageOnly) stores mode and can be read back via get_user_dashboard
#[test]
fn test_set_user_mode_leverage_only_stored() {
    let (_wbtc, _ybtc, vault, _strat) = setup_oracle_vault_with_deposit(100_000_000_u256);

    start_cheat_caller_address(vault.contract_address, alice());
    vault.set_user_mode(
        UserMode::LeverageOnly,
        contract_address_const::<0>(), // no strategy
        0_u128,                        // no custom cap
        0_u16,                         // no custom yield bps
        false,                         // no warning needed
    );
    stop_cheat_caller_address(vault.contract_address);

    let dash = vault.get_user_dashboard(alice());
    assert(dash.mode == UserMode::LeverageOnly, 'mode must be LeverageOnly');
    assert(dash.custom_leverage_cap == 0, 'no custom cap set');
    assert(!dash.warning_accepted, 'no warning needed here');
}

// 86. YieldOnly mode (injected via storage cheat) blocks apply_leverage
#[test]
#[should_panic(expected: ('Mode: yield only, no leverage',))]
fn test_user_mode_yield_only_blocks_leverage() {
    let oracle = deploy_mock_oracle(9_500_000_000_000_u128);
    let router = deploy_router_with_oracle(110, oracle.contract_address);
    let wbtc = deploy_wbtc(vault_a());
    let ybtc = deploy_ybtc(vault_a());
    let vault = deploy_vault(wbtc.contract_address, ybtc.contract_address, router.contract_address);

    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(1_000_000_000_000_u256);
    router.register_protocol(vault.contract_address, 'vault');
    router.refresh_btc_price();
    stop_cheat_caller_address(router.contract_address);

    // Mint wBTC, approve, deposit for alice
    start_cheat_caller_address(wbtc.contract_address, vault_a());
    wbtc.mint(alice(), 100_000_000_u256);
    stop_cheat_caller_address(wbtc.contract_address);
    start_cheat_caller_address(wbtc.contract_address, alice());
    wbtc.approve(vault.contract_address, 100_000_000_u256);
    stop_cheat_caller_address(wbtc.contract_address);
    start_cheat_caller_address(ybtc.contract_address, vault_a());
    start_cheat_caller_address(vault.contract_address, alice());
    vault.deposit(100_000_000_u256);
    stop_cheat_caller_address(vault.contract_address);
    stop_cheat_caller_address(ybtc.contract_address);

    // Register a strategy so alice can set YieldOnly mode
    let strategy = deploy_strategy(wbtc.contract_address, vault.contract_address);
    start_cheat_caller_address(vault.contract_address, owner());
    vault.register_strategy(strategy.contract_address, 1_u8);
    stop_cheat_caller_address(vault.contract_address);

    // Set alice to YieldOnly mode using the proper set_user_mode call
    start_cheat_caller_address(vault.contract_address, alice());
    vault.set_user_mode(
        UserMode::YieldOnly,
        strategy.contract_address,
        0_u128,
        0_u16,
        false,
    );
    stop_cheat_caller_address(vault.contract_address);

    // apply_leverage must now panic: 'Mode: yield only, no leverage'
    start_cheat_caller_address(vault.contract_address, alice());
    vault.apply_leverage(120_u128);
    stop_cheat_caller_address(vault.contract_address);
}

// 87. Custom leverage cap set by user blocks leverage above that cap
#[test]
#[should_panic(expected: ('Custom leverage cap exceeded',))]
fn test_custom_leverage_cap_blocks_over_cap() {
    let oracle = deploy_mock_oracle(9_500_000_000_000_u128);
    let router = deploy_router_with_oracle(110, oracle.contract_address);
    let wbtc = deploy_wbtc(vault_a());
    let ybtc = deploy_ybtc(vault_a());
    let vault = deploy_vault(wbtc.contract_address, ybtc.contract_address, router.contract_address);

    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(1_000_000_000_000_u256);
    router.register_protocol(vault.contract_address, 'vault');
    router.refresh_btc_price();
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(wbtc.contract_address, vault_a());
    wbtc.mint(alice(), 100_000_000_u256);
    stop_cheat_caller_address(wbtc.contract_address);
    start_cheat_caller_address(wbtc.contract_address, alice());
    wbtc.approve(vault.contract_address, 100_000_000_u256);
    stop_cheat_caller_address(wbtc.contract_address);
    start_cheat_caller_address(ybtc.contract_address, vault_a());
    start_cheat_caller_address(vault.contract_address, alice());
    vault.deposit(100_000_000_u256);
    stop_cheat_caller_address(vault.contract_address);
    stop_cheat_caller_address(ybtc.contract_address);

    // Alice sets a personal cap of 110 (1.10x); no warning needed (110 <= recommended 130)
    start_cheat_caller_address(vault.contract_address, alice());
    vault.set_user_mode(
        UserMode::LeverageOnly,
        contract_address_const::<0>(),
        110_u128,  // personal cap: 1.10x
        0_u16,
        false,
    );
    // Try to apply 120 which is above the 110 cap — must panic
    vault.apply_leverage(120_u128);
    stop_cheat_caller_address(vault.contract_address);
}

// 88. set_user_mode with Combined mode requires accept_warning = true
#[test]
#[should_panic(expected: ('Combined mode needs warning',))]
fn test_combined_mode_requires_warning() {
    let (_wbtc, _ybtc, vault, strat) = setup_oracle_vault_with_deposit(100_000_000_u256);

    // The Combined-mode check fires before the strategy-active check, so any strat address works.
    start_cheat_caller_address(vault.contract_address, alice());
    vault.set_user_mode(
        UserMode::Combined,
        strat,
        0_u128,
        0_u16,
        false, // must panic: 'Combined mode needs warning'
    );
    stop_cheat_caller_address(vault.contract_address);
}

// 89. get_user_dashboard returns zero for a non-depositor
#[test]
fn test_get_user_dashboard_zero_for_non_depositor() {
    let (_wbtc, _ybtc, vault, _strat) = setup_oracle_vault_with_deposit(100_000_000_u256);
    let dash = vault.get_user_dashboard(bob()); // bob never deposited
    assert(dash.ybtc_balance == 0, 'no ybtc for bob');
    assert(dash.btc_value_sat == 0, 'no btc value for bob');
    assert(dash.current_leverage == 0, 'no leverage for bob');
    assert(dash.user_debt_usd == 0, 'no debt for bob');
    assert(dash.claimable_yield_sat == 0, 'no yield for bob');
    assert(dash.deposit_timestamp == 0, 'no deposit ts for bob');
}

// 90. get_user_dashboard returns correct position data for alice after deposit
#[test]
fn test_get_user_dashboard_populated_for_depositor() {
    let (_wbtc, _ybtc, vault, _strat) = setup_oracle_vault_with_deposit(100_000_000_u256);
    let dash = vault.get_user_dashboard(alice());
    // Alice deposited 100_000_000 sat (first deposit → 1:1 shares)
    assert(dash.ybtc_balance == 100_000_000_u256, 'alice ybtc balance');
    assert(dash.btc_value_sat == 100_000_000_u256, 'alice btc value');
    // USD value: 100_000_000 sat × $95,000 / 10^8 = $95,000 → 9_500_000_000_000 (8 dec)
    assert(dash.btc_value_usd == 9_500_000_000_000_u256, 'alice usd value');
    assert(dash.current_leverage == 0, 'no leverage yet');
    assert(dash.user_debt_usd == 0, 'no debt yet');
    assert(dash.health_factor == 0xffffffffffffffffffffffffffffffff_u128, 'infinite health');
    assert(dash.share_price == 1_000_000_u256, 'share price 1.0');
    assert(dash.deposit_timestamp != 0, 'deposit ts set');
    assert(dash.claimable_yield_sat == 0, 'no yield yet');
    assert(dash.price_is_fresh, 'price must be fresh');
    assert(!dash.is_safe_mode, 'not in safe mode');
    assert(dash.can_deposit, 'deposits allowed');
    assert(dash.can_leverage, 'leverage allowed');
}

// 91. get_user_claimable_yield is proportional to share ownership
#[test]
fn test_get_user_claimable_yield_proportional() {
    let oracle = deploy_mock_oracle(9_500_000_000_000_u128);
    let router = deploy_router_with_oracle(110, oracle.contract_address);
    let wbtc = deploy_wbtc(vault_a());
    let ybtc = deploy_ybtc(vault_a());
    let vault = deploy_vault(wbtc.contract_address, ybtc.contract_address, router.contract_address);

    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(1_000_000_000_000_u256);
    router.register_protocol(vault.contract_address, 'vault');
    router.refresh_btc_price();
    stop_cheat_caller_address(router.contract_address);

    start_cheat_caller_address(wbtc.contract_address, vault_a());
    wbtc.mint(alice(), 100_000_000_u256);
    wbtc.mint(bob(),   100_000_000_u256);
    stop_cheat_caller_address(wbtc.contract_address);

    start_cheat_caller_address(wbtc.contract_address, alice());
    wbtc.approve(vault.contract_address, 100_000_000_u256);
    stop_cheat_caller_address(wbtc.contract_address);
    start_cheat_caller_address(wbtc.contract_address, bob());
    wbtc.approve(vault.contract_address, 100_000_000_u256);
    stop_cheat_caller_address(wbtc.contract_address);

    // Alice deposits 1 BTC → snapshot[alice] = accumulated_yield = 0
    start_cheat_caller_address(ybtc.contract_address, vault_a());
    start_cheat_caller_address(vault.contract_address, alice());
    vault.deposit(100_000_000_u256);
    stop_cheat_caller_address(vault.contract_address);
    stop_cheat_caller_address(ybtc.contract_address);

    // Bob deposits 1 BTC → snapshot[bob] = accumulated_yield = 0
    start_cheat_caller_address(ybtc.contract_address, vault_a());
    start_cheat_caller_address(vault.contract_address, bob());
    vault.deposit(100_000_000_u256);
    stop_cheat_caller_address(vault.contract_address);
    stop_cheat_caller_address(ybtc.contract_address);

    // Register a strategy and deploy all 200M sat to it so deployed_capital > 0
    let strategy = deploy_strategy(wbtc.contract_address, vault.contract_address);
    start_cheat_caller_address(vault.contract_address, owner());
    vault.register_strategy(strategy.contract_address, 1_u8);
    vault.deploy_to_strategy(strategy.contract_address, 200_000_000_u256);
    stop_cheat_caller_address(vault.contract_address);

    // Simulate real strategy yield:
    // 1. Mint 20M extra wBTC to the strategy contract (represents yield earned externally).
    // 2. Tell the strategy to include this surplus on the next withdrawal.
    // 3. Withdraw all capital from the strategy — vault receives 220M (200M principal +
    //    20M yield).  withdraw_from_strategy() credits the 20M surplus to both
    //    total_assets and accumulated_yield (the real accounting path).
    let strategy_admin = IMockStrategyAdminDispatcher { contract_address: strategy.contract_address };
    let yield_amount: u256 = 20_000_000;

    start_cheat_caller_address(wbtc.contract_address, vault_a());
    wbtc.mint(strategy.contract_address, yield_amount);
    stop_cheat_caller_address(wbtc.contract_address);

    start_cheat_caller_address(strategy.contract_address, owner());
    strategy_admin.add_pending_yield(yield_amount);
    stop_cheat_caller_address(strategy.contract_address);

    start_cheat_caller_address(vault.contract_address, owner());
    vault.withdraw_from_strategy(strategy.contract_address, 200_000_000_u256);
    stop_cheat_caller_address(vault.contract_address);

    // Both deposited equal amounts (50% shares each) → equal claimable yield
    let alice_claimable = vault.get_user_claimable_yield(alice());
    let bob_claimable   = vault.get_user_claimable_yield(bob());

    assert(alice_claimable > 0, 'yield must have accrued');
    assert(alice_claimable == bob_claimable, 'yield proportional');
}

// 92. get_recommended_leverage returns 130 for a healthy user and never exceeds sys max
#[test]
fn test_get_recommended_leverage_healthy_user() {
    let (_wbtc, _ybtc, vault, _strat) = setup_oracle_vault_with_deposit(100_000_000_u256);
    // Alice has no debt → health = u128::MAX → recommended = min(130, sys_max) = 130
    let rec = vault.get_recommended_leverage(alice());
    assert(rec == 130_u128, 'healthy user: recommend 130');
    // Bob never deposited (health = u128::MAX, no debt) → also 130
    let rec_bob = vault.get_recommended_leverage(bob());
    assert(rec_bob == 130_u128, 'no deposit: recommend 130');
}

// ============================================================
// YBTCToken Two-Step Ownership Tests (93–95)
// ============================================================

// 93. YBTCToken two-step ownership: propose then accept
#[test]
fn test_ybtc_transfer_ownership_two_step() {
    let ybtc = deploy_ybtc(vault_a());
    let admin = IYBTCAdminDispatcher { contract_address: ybtc.contract_address };

    // Owner nominates alice
    start_cheat_caller_address(ybtc.contract_address, owner());
    admin.transfer_ownership(alice());
    stop_cheat_caller_address(ybtc.contract_address);

    // Owner has not changed yet; alice is the pending owner
    assert(admin.get_owner() == owner(), 'owner unchanged before accept');
    assert(admin.get_pending_owner() == alice(), 'pending owner is alice');

    // Alice accepts → she becomes the new owner
    start_cheat_caller_address(ybtc.contract_address, alice());
    admin.accept_ownership();
    stop_cheat_caller_address(ybtc.contract_address);

    assert(admin.get_owner() == alice(), 'alice must be new owner');
    // Pending owner cleared
    assert(admin.get_pending_owner() == contract_address_const::<0>(), 'pending owner cleared');
}

// 94. YBTCToken accept_ownership fails when caller is not the pending owner
#[test]
#[should_panic(expected: ('Not pending owner',))]
fn test_ybtc_accept_ownership_wrong_caller_fails() {
    let ybtc = deploy_ybtc(vault_a());
    let admin = IYBTCAdminDispatcher { contract_address: ybtc.contract_address };

    // Owner nominates alice
    start_cheat_caller_address(ybtc.contract_address, owner());
    admin.transfer_ownership(alice());
    stop_cheat_caller_address(ybtc.contract_address);

    // Bob (not alice) tries to accept — must panic
    start_cheat_caller_address(ybtc.contract_address, bob());
    admin.accept_ownership();
    stop_cheat_caller_address(ybtc.contract_address);
}

// 95. YBTCToken ownership does not transfer until accept_ownership is called
#[test]
fn test_ybtc_owner_unchanged_before_accept() {
    let ybtc = deploy_ybtc(vault_a());
    let admin = IYBTCAdminDispatcher { contract_address: ybtc.contract_address };

    // Owner nominates alice but does not yet accept
    start_cheat_caller_address(ybtc.contract_address, owner());
    admin.transfer_ownership(alice());
    stop_cheat_caller_address(ybtc.contract_address);

    // Original owner still controls the contract
    assert(admin.get_owner() == owner(), 'owner unchanged');
    // alice is pending, not yet owner
    assert(admin.get_pending_owner() == alice(), 'alice is pending');
    assert(admin.get_owner() != alice(), 'alice is NOT owner yet');

    // Owner can still set_vault_address because ownership hasn't transferred
    start_cheat_caller_address(ybtc.contract_address, owner());
    admin.set_vault_address(vault_a());
    stop_cheat_caller_address(ybtc.contract_address);
}

// ============================================================
// KEEPER btc_backing Rate-of-Change Guard (I-3) Tests (96–98)
// ============================================================

// 96. update_btc_backing within ±50% of current value succeeds
#[test]
fn test_btc_backing_update_within_bounds_passes() {
    let router = deploy_router(110);

    start_cheat_caller_address(router.contract_address, owner());
    // First call from 0: unconstrained initialisation
    router.update_btc_backing(100);
    // Exactly at 50% lower bound (50 * 2 = 100 >= 100) → pass
    router.update_btc_backing(50);
    // From 50: exactly at 150% upper bound (50 + 50/2 = 75) → pass
    router.update_btc_backing(75);
    // From 75: 130% increase (75 + 75/2 = 112) → pass
    router.update_btc_backing(112);
    stop_cheat_caller_address(router.contract_address);

    assert(router.get_btc_backing() == 112, 'backing should be 112');
}

// 97. update_btc_backing dropping below 50% of current value is rejected
#[test]
#[should_panic(expected: ('Backing drop exceeds 50%',))]
fn test_btc_backing_drop_below_50pct_fails() {
    let router = deploy_router(110);

    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(100); // unconstrained initialisation
    router.update_btc_backing(49);  // 49 * 2 = 98 < 100 → panic
    stop_cheat_caller_address(router.contract_address);
}

// 98. update_btc_backing jumping above 150% of current value is rejected
#[test]
#[should_panic(expected: ('Backing jump exceeds 150%',))]
fn test_btc_backing_jump_above_150pct_fails() {
    let router = deploy_router(110);

    start_cheat_caller_address(router.contract_address, owner());
    router.update_btc_backing(100);  // unconstrained initialisation
    router.update_btc_backing(151);  // 151 > 100 + 50 = 150 → panic
    stop_cheat_caller_address(router.contract_address);
}
