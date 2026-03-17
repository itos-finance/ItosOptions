#!/usr/bin/env bash
# DeployAll.sh — sequentially deploys all contracts to Monad testnet
# and writes deployed addresses to deployments/monad-testnet.json
#
# Usage:
#   cd contracts && bash script/DeployAll.sh
#
# Prerequisites:
#   - .env with DEPLOYER_PRIVATE_KEY and RPC_URL
#   - forge installed and contracts built (forge build)

set -uo pipefail

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

DEPLOY_DIR="$ROOT_DIR/deployments"
mkdir -p "$DEPLOY_DIR"
OUTPUT="$DEPLOY_DIR/monad-testnet.json"

FORGE_OPTS="--rpc-url $RPC_URL --private-key $DEPLOYER_PRIVATE_KEY --broadcast"

# Helper: extract deployed address from forge script output
extract_address() {
  local label="$1"
  local output="$2"
  echo "$output" | grep "$label" | grep -oE '0x[0-9a-fA-F]{40}' | head -1 || true
}

# Helper: run forge script, abort with context on failure
deploy_step() {
  local step_label="$1"
  shift
  local output rc
  set +e
  output=$("$@" 2>&1)
  rc=$?
  set -e
  if [ $rc -ne 0 ]; then
    echo ""
    echo "ERROR: ${step_label} — forge script failed (exit code $rc):"
    echo "$output" | tail -30
    exit 1
  fi
  LAST_OUTPUT="$output"
}

echo "========================================="
echo " Itos Finance — Monad Testnet Deployment"
echo "========================================="
echo ""

# Detect chain ID
CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null || echo "10143")
echo "Chain ID: $CHAIN_ID"
echo ""

# Step 0: Deploy Test Tokens
echo "[0/5] Deploying test tokens (WETH, USDC)..."
deploy_step "[0/5] Test Tokens" forge script script/00_DeployTestTokens.s.sol $FORGE_OPTS
WETH=$(extract_address "WETH deployed at" "$LAST_OUTPUT")
USDC=$(extract_address "USDC deployed at" "$LAST_OUTPUT")
if [ -z "$WETH" ] || [ -z "$USDC" ]; then
  echo "ERROR: Failed to parse token addresses. Forge output:"
  echo "$LAST_OUTPUT" | tail -30
  exit 1
fi
echo "  WETH: $WETH"
echo "  USDC: $USDC"
echo ""

# Step 1: Deploy Factory
echo "[1/5] Deploying OPairFactory..."
deploy_step "[1/5] Factory" forge script script/01_DeployFactory.s.sol $FORGE_OPTS
FACTORY=$(extract_address "OPairFactory deployed at" "$LAST_OUTPUT")
if [ -z "$FACTORY" ]; then
  echo "ERROR: Failed to parse factory address. Forge output:"
  echo "$LAST_OUTPUT" | tail -30
  exit 1
fi
echo "  Factory: $FACTORY"
echo ""

# Step 2: Deploy Funder
echo "[2/5] Deploying Funder..."
export FACTORY
deploy_step "[2/5] Funder" forge script script/02_DeployFunder.s.sol $FORGE_OPTS
FUNDER=$(extract_address "Funder deployed at" "$LAST_OUTPUT")
if [ -z "$FUNDER" ]; then
  echo "ERROR: Failed to parse funder address. Forge output:"
  echo "$LAST_OUTPUT" | tail -30
  exit 1
fi
echo "  Funder: $FUNDER"
echo ""

# Step 3: Deploy MultiFunder
echo "[3/5] Deploying MultiFunder..."
deploy_step "[3/5] MultiFunder" forge script script/03_DeployMultiFunder.s.sol $FORGE_OPTS
MULTI_FUNDER=$(extract_address "MultiFunder deployed at" "$LAST_OUTPUT")
if [ -z "$MULTI_FUNDER" ]; then
  echo "ERROR: Failed to parse multifunder address. Forge output:"
  echo "$LAST_OUTPUT" | tail -30
  exit 1
fi
echo "  MultiFunder: $MULTI_FUNDER"
echo ""

# Step 4: Deploy Bulletin
echo "[4/5] Deploying Bulletin..."
deploy_step "[4/5] Bulletin" forge script script/04_DeployBulletin.s.sol $FORGE_OPTS
BULLETIN=$(extract_address "Bulletin deployed at" "$LAST_OUTPUT")
if [ -z "$BULLETIN" ]; then
  echo "ERROR: Failed to parse bulletin address. Forge output:"
  echo "$LAST_OUTPUT" | tail -30
  exit 1
fi
echo "  Bulletin: $BULLETIN"
echo ""

# Step 5: Create WETH/USDC call pair
echo "[5/5] Creating WETH/USDC call pair..."
EXPIRY=$(date -v+30d +%s 2>/dev/null || date -d "+30 days" +%s)
export RISK_TOKEN=$WETH
export CASH_TOKEN=$USDC
export STRIKE=2000000000
export EXPIRY
export IS_CALL=true
export MIN_DEPOSIT_SIZE=10000000000000000
export IDENTIFIER="WETH-USDC-2000-CALL"
export SYMBOL="WETH2K"
deploy_step "[5/5] Pair" forge script script/05_CreatePair.s.sol $FORGE_OPTS
PAIR=$(extract_address "OPair deployed at" "$LAST_OUTPUT")
if [ -z "$PAIR" ]; then
  echo "ERROR: Failed to parse pair address. Forge output:"
  echo "$LAST_OUTPUT" | tail -30
  exit 1
fi
echo "  Pair: $PAIR"
echo "  Strike: 2000e6 (2000 USDC)"
echo "  Expiry: $EXPIRY"
echo ""

# Write deployment JSON
cat > "$OUTPUT" <<ENDJSON
{
  "chain_id": $CHAIN_ID,
  "deployed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "contracts": {
    "weth": "$WETH",
    "usdc": "$USDC",
    "factory": "$FACTORY",
    "funder": "$FUNDER",
    "multiFunder": "$MULTI_FUNDER",
    "bulletin": "$BULLETIN",
    "pair_weth_usdc_call": "$PAIR"
  }
}
ENDJSON

echo "========================================="
echo " Deployment complete!"
echo " Addresses written to: $OUTPUT"
echo "========================================="
cat "$OUTPUT"
