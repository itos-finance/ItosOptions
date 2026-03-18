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

WETH_AMOUNT="1000000000000000000000"  # 1000 WETH (18 decimals)
USDC_AMOUNT="2000000000000"           # 2,000,000 USDC (6 decimals)

echo "Minting tokens to $RECIPIENT"
echo "  WETH ($WETH): 1000 WETH"
echo "  USDC ($USDC): 2,000,000 USDC"
echo ""

cast send "$WETH" "mint(address,uint256)" "$RECIPIENT" "$WETH_AMOUNT" \
  --rpc-url "$RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY"

echo "  WETH mint confirmed."

cast send "$USDC" "mint(address,uint256)" "$RECIPIENT" "$USDC_AMOUNT" \
  --rpc-url "$RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY"

echo "  USDC mint confirmed."
echo ""
echo "Done. Minted 1000 WETH + 2M USDC to $RECIPIENT"
