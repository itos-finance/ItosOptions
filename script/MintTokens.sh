#!/usr/bin/env bash
# MintTokens.sh — mints mock WETH and USDC to a recipient address
#
# Usage:
#   cd contracts && bash script/MintTokens.sh <recipient_address>
#
# Prerequisites:
#   - .env with DEPLOYER_PRIVATE_KEY and RPC_URL
#   - cast installed (part of foundry)

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: bash script/MintTokens.sh <recipient_address>"
  exit 1
fi

RECIPIENT="$1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

# Load env
if [ -f .env ]; then
  set -a
  source .env
  set +a
fi

: "${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY not set}"
: "${RPC_URL:?RPC_URL not set}"

# Read token addresses from deployment JSON
DEPLOY_JSON="$ROOT_DIR/deployments/monad-testnet.json"
if [ ! -f "$DEPLOY_JSON" ]; then
  echo "ERROR: Deployment file not found at $DEPLOY_JSON"
  exit 1
fi

WETH=$(jq -r '.contracts.weth' "$DEPLOY_JSON")
USDC=$(jq -r '.contracts.usdc' "$DEPLOY_JSON")
BTC=$(jq -r '.contracts.btc // ""' "$DEPLOY_JSON")
MON=$(jq -r '.contracts.mon // ""' "$DEPLOY_JSON")

WETH_AMOUNT="1000000000000000000000"    # 1000 WETH (18 decimals)
USDC_AMOUNT="2000000000000"             # 2,000,000 USDC (6 decimals)
BTC_AMOUNT="1000000000"                 # 10 BTC (8 decimals)
MON_AMOUNT="100000000000000000000000"   # 100,000 MON (18 decimals)

echo "Minting tokens to $RECIPIENT"
echo "  WETH ($WETH): 1000 WETH"
echo "  USDC ($USDC): 2,000,000 USDC"
[ -n "$BTC" ] && echo "  BTC  ($BTC): 10 BTC"
[ -n "$MON" ] && echo "  MON  ($MON): 100,000 MON"
echo ""

cast send "$WETH" "mint(address,uint256)" "$RECIPIENT" "$WETH_AMOUNT" \
  --rpc-url "$RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY"
echo "  WETH mint confirmed."

cast send "$USDC" "mint(address,uint256)" "$RECIPIENT" "$USDC_AMOUNT" \
  --rpc-url "$RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY"
echo "  USDC mint confirmed."

if [ -n "$BTC" ]; then
  cast send "$BTC" "mint(address,uint256)" "$RECIPIENT" "$BTC_AMOUNT" \
    --rpc-url "$RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY"
  echo "  BTC mint confirmed."
fi

if [ -n "$MON" ]; then
  cast send "$MON" "mint(address,uint256)" "$RECIPIENT" "$MON_AMOUNT" \
    --rpc-url "$RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY"
  echo "  MON mint confirmed."
fi

echo ""
echo "Done. Minted tokens to $RECIPIENT"
