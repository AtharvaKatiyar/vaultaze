#!/usr/bin/env bash
set -e

ROUTER="0x014c306f04fd602c1a06f61367de622af2558972c7eead39600b5d99fd1e2639"
VAULT="0x0047970cfbf8de94f268f2416c9e5cbaef520dae7b5eae0fd6476a41b7266f08"
SENTINEL="0x035f52fe2308298598073b8ef7dacd633daf4f7a20904adfed52f0c2f8446573"
REBALANCER="0x01f4f73afcfffbbce6b76d508d0e1b7da4584f18e38c56b514153a284d8cc141"
GUARDIAN="0x0663852d4a345f4b51c0a4b263be7d908c309c7d7433a8e01a59eb503f0ad438"

ROLE_GUARDIAN="0x524f4c455f475541524449414e"
ROLE_KEEPER="0x524f4c455f4b4545504552"
ROLE_LIQUIDATOR="0x524f4c455f4c495155494441544f52"

grant() {
  local label="$1" contract="$2" role="$3" account="$4"
  echo ""
  echo ">>> $label"
  sncast --account sepolia invoke --network sepolia \
    --contract-address "$contract" \
    --function grant_role \
    --calldata "$role" "$account"
  sleep 6
}

grant "ROLE_GUARDIAN on Router → agent-sentinel"   $ROUTER $ROLE_GUARDIAN  $SENTINEL
grant "ROLE_KEEPER   on Router → agent-sentinel"   $ROUTER $ROLE_KEEPER    $SENTINEL
grant "ROLE_KEEPER   on Router → agent-rebalancer" $ROUTER $ROLE_KEEPER    $REBALANCER
grant "ROLE_KEEPER   on Vault  → agent-rebalancer" $VAULT  $ROLE_KEEPER    $REBALANCER
grant "ROLE_LIQUIDATOR on Vault → agent-guardian"  $VAULT  $ROLE_LIQUIDATOR $GUARDIAN

echo ""
echo "All roles granted."
