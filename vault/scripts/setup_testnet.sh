#!/usr/bin/env bash
# =============================================================================
#  BTC Vault — Testnet Initialisation Script
#  Starknet Sepolia (Sepolia testnet)
# =============================================================================
#
#  Prerequisites
#  ─────────────
#  1. starkli ≥ 0.3  (https://book.starkli.rs/installation)
#  2. Export your deployer private key:
#       export STARKNET_PRIVATE_KEY=0x<your_key>
#  3. (Optional) Export recipient address for wBTC mint:
#       export RECIPIENT=0x<wallet_address>
#
#  Usage
#  ─────
#  chmod +x vault/scripts/setup_testnet.sh
#  ./vault/scripts/setup_testnet.sh
#
# =============================================================================

set -euo pipefail

# ─── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
info() { echo -e "${CYAN}→${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*"; exit 1; }

# ─── Check starkli ────────────────────────────────────────────────────────────
command -v starkli >/dev/null 2>&1 || fail "starkli not found. Install: curl https://get.starkli.sh | sh"
command -v jq      >/dev/null 2>&1 || warn  "jq not found — tx receipt parsing disabled"

# ─── Config ───────────────────────────────────────────────────────────────────
CHAIN_ID="SN_SEPOLIA"
RPC_URL="${STARKNET_RPC:-https://starknet-sepolia.public.blastapi.io/rpc/v0_8}"

DEPLOYER="${STARKNET_ACCOUNT:-0x01390501de9c3e2c1f06d97fd317c1cd002d95250ab6f58bf1f272bdb9f8ed18}"
RECIPIENT="${RECIPIENT:-$DEPLOYER}"

ORACLE="0x06d1c9aa3cb65003c51a4b360c8ac3a23a9724530246031ba92ff0b2461f7e74"
ROUTER="0x014c306f04fd602c1a06f61367de622af2558972c7eead39600b5d99fd1e2639"
MOCK_WBTC="0x0129f01b63b9eb403e07c9da8e69e2bed648a5fbc81fddb0b27768ee323bf446"

# BTC/USD at 8 decimal places: $95,000 → 9_500_000_000_000
BTC_PRICE="9500000000000"
# 1 BTC in satoshi = 100_000_000  (8 decimal ERC-20)
MINT_AMOUNT="100000000"

STARKLI_FLAGS="--rpc $RPC_URL --account $DEPLOYER --keystore /dev/stdin"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║        BTC Vault — Testnet Setup (Sepolia)               ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
info "RPC:      $RPC_URL"
info "Deployer: $DEPLOYER"
info "Recipient: $RECIPIENT"
echo ""

# ─── Validate private key ─────────────────────────────────────────────────────
if [[ -z "${STARKNET_PRIVATE_KEY:-}" ]]; then
  fail "STARKNET_PRIVATE_KEY is not set.\nExport it: export STARKNET_PRIVATE_KEY=0x<key>"
fi

# ─── Helper: invoke with private key piped as keystore ───────────────────────
invoke() {
  local contract="$1"; shift
  local entrypoint="$1"; shift
  echo -e "\n${CYAN}Calling${NC} ${BOLD}${contract:0:10}…${entrypoint}${NC} with args: $*"
  echo "$STARKNET_PRIVATE_KEY" | starkli invoke \
    --rpc "$RPC_URL" \
    --account "$DEPLOYER" \
    "$contract" "$entrypoint" "$@" \
    --watch
  ok "Transaction confirmed"
}

# ═══════════════════════════════════════════════════════════════════════════════
#  STEP 1: Update MockPragmaOracle price
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "\n${BOLD}[ 1/3 ] Set MockPragmaOracle price = \$95,000${NC}"
invoke "$ORACLE" set_price "u128:$BTC_PRICE"

# ═══════════════════════════════════════════════════════════════════════════════
#  STEP 2: Refresh BTCSecurityRouter price cache
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "\n${BOLD}[ 2/3 ] Refresh BTCSecurityRouter price cache${NC}"
invoke "$ROUTER" refresh_btc_price

# ═══════════════════════════════════════════════════════════════════════════════
#  STEP 3: Mint Mock wBTC
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "\n${BOLD}[ 3/3 ] Mint 1 Mock wBTC → $RECIPIENT${NC}"
# u256 is passed as two u128 felts: low high
invoke "$MOCK_WBTC" mint "$RECIPIENT" "u256:$MINT_AMOUNT"

# ═══════════════════════════════════════════════════════════════════════════════
#  Done
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}${BOLD}All done!${NC} The testnet is now initialised:"
echo -e "  ${GREEN}✓${NC} Oracle price = \$95,000 (fresh timestamp)"
echo -e "  ${GREEN}✓${NC} Router price cache synced → is_price_fresh() = true"
echo -e "  ${GREEN}✓${NC} 1 Mock wBTC minted to $RECIPIENT"
echo ""
echo -e "Reload the dashboard at ${CYAN}http://localhost:3000${NC} — health should show ${GREEN}∞ (No Exposure)${NC}"
echo ""
echo -e "Explorer links:"
echo -e "  Router: https://sepolia.starkscan.co/contract/$ROUTER"
echo -e "  Vault:  https://sepolia.starkscan.co/contract/0x0047970cfbf8de94f268f2416c9e5cbaef520dae7b5eae0fd6476a41b7266f08"
echo ""
