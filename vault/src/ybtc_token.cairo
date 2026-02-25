use starknet::{ContractAddress, get_caller_address};
use starknet::storage::Map;

// =====================================
// YBTCToken Admin Interface (file-level so dispatcher types are crate-visible)
// =====================================

#[starknet::interface]
pub trait IYBTCAdmin<TContractState> {
    fn set_vault_address(ref self: TContractState, new_vault: ContractAddress);
    fn transfer_ownership(ref self: TContractState, new_owner: ContractAddress);
    fn accept_ownership(ref self: TContractState);
    fn get_vault_address(self: @TContractState) -> ContractAddress;
    fn get_owner(self: @TContractState) -> ContractAddress;
    fn get_pending_owner(self: @TContractState) -> ContractAddress;
}

#[starknet::contract]
mod YBTCToken {
    use super::{ContractAddress, get_caller_address, Map};
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess, StorageMapReadAccess, StorageMapWriteAccess};
    use core::num::traits::Zero;

    // =====================================
    // Storage
    // =====================================

    #[storage]
    struct Storage {
        // ERC20 standard
        total_supply: u256,
        balances: Map<ContractAddress, u256>,
        allowances: Map<(ContractAddress, ContractAddress), u256>,
        
        // Token metadata
        name: ByteArray,
        symbol: ByteArray,
        decimals: u8,
        
        // Access control
        vault_address: ContractAddress,
        owner: ContractAddress,
        pending_owner: ContractAddress,   // two-step ownership transfer
    }

    // =====================================
    // Events
    // =====================================

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Transfer: Transfer,
        Approval: Approval,
        Mint: Mint,
        Burn: Burn,
        OwnershipTransferStarted: OwnershipTransferStarted,
        OwnershipTransferred: OwnershipTransferred,
    }

    #[derive(Drop, starknet::Event)]
    struct Transfer {
        #[key]
        from: ContractAddress,
        #[key]
        to: ContractAddress,
        value: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct Approval {
        #[key]
        owner: ContractAddress,
        #[key]
        spender: ContractAddress,
        value: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct Mint {
        #[key]
        to: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct Burn {
        #[key]
        from: ContractAddress,
        amount: u256,
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

    // =====================================
    // Constructor
    // =====================================

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        vault_address: ContractAddress
    ) {
        assert(!owner.is_zero(), 'Owner is zero address');
        assert(!vault_address.is_zero(), 'Vault is zero address');
        self.name.write("Yield Bitcoin");
        self.symbol.write("yBTC");
        self.decimals.write(8); // Same as BTC
        self.owner.write(owner);
        self.vault_address.write(vault_address);
        self.total_supply.write(0);
    }

    // =====================================
    // External Functions
    // =====================================

    #[abi(embed_v0)]
    impl YBTCTokenImpl of super::super::interfaces::IYBTCToken<ContractState> {
        
        // ===== ERC20 View Functions =====
        
        fn name(self: @ContractState) -> ByteArray {
            self.name.read()
        }

        fn symbol(self: @ContractState) -> ByteArray {
            self.symbol.read()
        }

        fn decimals(self: @ContractState) -> u8 {
            self.decimals.read()
        }

        fn total_supply(self: @ContractState) -> u256 {
            self.total_supply.read()
        }

        fn balance_of(self: @ContractState, account: ContractAddress) -> u256 {
            self.balances.read(account)
        }

        fn allowance(
            self: @ContractState,
            owner: ContractAddress,
            spender: ContractAddress
        ) -> u256 {
            self.allowances.read((owner, spender))
        }

        // ===== ERC20 State-Changing Functions =====

        fn transfer(ref self: ContractState, recipient: ContractAddress, amount: u256) -> bool {
            let sender = get_caller_address();
            self._transfer(sender, recipient, amount);
            true
        }

        fn transfer_from(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256
        ) -> bool {
            let caller = get_caller_address();
            
            // Check and update allowance
            let current_allowance = self.allowances.read((sender, caller));
            assert(current_allowance >= amount, 'Insufficient allowance');
            
            self.allowances.write((sender, caller), current_allowance - amount);
            
            self._transfer(sender, recipient, amount);
            true
        }

        fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) -> bool {
            let owner = get_caller_address();
            self.allowances.write((owner, spender), amount);
            
            self.emit(Approval {
                owner,
                spender,
                value: amount,
            });
            
            true
        }

        // ===== Vault-Controlled Functions =====

        fn mint(ref self: ContractState, to: ContractAddress, amount: u256) {
            // Only vault can mint
            self._only_vault();
            assert(amount > 0, 'Zero mint amount');
            assert(!to.is_zero(), 'Mint to zero address');
            
            // Update total supply
            let new_supply = self.total_supply.read() + amount;
            self.total_supply.write(new_supply);
            
            // Update balance
            let new_balance = self.balances.read(to) + amount;
            self.balances.write(to, new_balance);
            
            self.emit(Mint {
                to,
                amount,
            });
            
            self.emit(Transfer {
                from: core::num::traits::Zero::zero(),
                to,
                value: amount,
            });
        }

        fn burn(ref self: ContractState, from: ContractAddress, amount: u256) {
            // Only vault can burn
            self._only_vault();
            assert(amount > 0, 'Zero burn amount');
            
            // Check balance
            let balance = self.balances.read(from);
            assert(balance >= amount, 'Insufficient balance');
            
            // Update balance
            self.balances.write(from, balance - amount);
            
            // Update total supply
            let new_supply = self.total_supply.read() - amount;
            self.total_supply.write(new_supply);
            
            self.emit(Burn {
                from,
                amount,
            });
            
            self.emit(Transfer {
                from,
                to: core::num::traits::Zero::zero(),
                value: amount,
            });
        }
    }

    // =====================================
    // Internal Functions
    // =====================================

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn _only_vault(self: @ContractState) {
            let caller = get_caller_address();
            assert(caller == self.vault_address.read(), 'Only vault can call');
        }

        fn _transfer(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256
        ) {
            assert(!recipient.is_zero(), 'Transfer to zero address');
            assert(amount > 0, 'Zero transfer amount');
            // Check sender balance
            let sender_balance = self.balances.read(sender);
            assert(sender_balance >= amount, 'Insufficient balance');
            
            // Update balances
            self.balances.write(sender, sender_balance - amount);
            
            let recipient_balance = self.balances.read(recipient);
            self.balances.write(recipient, recipient_balance + amount);
            
            // Emit event
            self.emit(Transfer {
                from: sender,
                to: recipient,
                value: amount,
            });
        }
    }

    // =====================================
    // Admin Functions (ABI-exposed)
    // =====================================

    #[abi(embed_v0)]
    impl AdminImpl of super::IYBTCAdmin<ContractState> {
        fn set_vault_address(ref self: ContractState, new_vault: ContractAddress) {
            let caller = get_caller_address();
            assert(caller == self.owner.read(), 'Only owner');
            assert(!new_vault.is_zero(), 'Vault is zero address');
            self.vault_address.write(new_vault);
        }

        fn transfer_ownership(ref self: ContractState, new_owner: ContractAddress) {
            let caller = get_caller_address();
            assert(caller == self.owner.read(), 'Only owner');
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

        fn get_vault_address(self: @ContractState) -> ContractAddress {
            self.vault_address.read()
        }

        fn get_owner(self: @ContractState) -> ContractAddress {
            self.owner.read()
        }

        fn get_pending_owner(self: @ContractState) -> ContractAddress {
            self.pending_owner.read()
        }
    }
}
