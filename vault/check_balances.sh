#!/usr/bin/env bash
set -e

STRK="0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d"
ETH="0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7"

declare -A WALLETS
WALLETS["agent-sentinel"]="0x035f52fe2308298598073b8ef7dacd633daf4f7a20904adfed52f0c2f8446573"
WALLETS["agent-rebalancer"]="0x01f4f73afcfffbbce6b76d508d0e1b7da4584f18e38c56b514153a284d8cc141"
WALLETS["agent-guardian"]="0x0663852d4a345f4b51c0a4b263be7d908c309c7d7433a8e01a59eb503f0ad438"

to_decimal() {
  python3 -c "v=int('$1',16); print(f'{v/1e18:.6f}')" 2>/dev/null || echo "err"
}

for name in agent-sentinel agent-rebalancer agent-guardian; do
  addr="${WALLETS[$name]}"
  echo "=== $name ==="
  echo "  Address : $addr"

  strk_raw=$(sncast call --network sepolia --contract-address "$STRK" --function balanceOf --calldata "$addr" 2>/dev/null | grep -oP '0x[0-9a-fA-F]+' | head -1)
  eth_raw=$(sncast call  --network sepolia --contract-address "$ETH"  --function balanceOf --calldata "$addr" 2>/dev/null | grep -oP '0x[0-9a-fA-F]+' | head -1)

  echo "  STRK    : $(to_decimal "$strk_raw") STRK  (raw: $strk_raw)"
  echo "  ETH     : $(to_decimal "$eth_raw") ETH   (raw: $eth_raw)"
  echo ""
done
