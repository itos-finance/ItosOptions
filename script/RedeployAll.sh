#!/usr/bin/env bash
# RedeployAll.sh — redeploys all contracts EXCEPT test tokens.
#
# Keeps existing WETH, USDC, BTC, MON addresses and redeploys:
#   Factory, Funder, MultiFunder, Bulletin, all OPair vaults, per-maker Funders.
#
# This is needed when the contract interfaces change (e.g. IFunderBase signature)
# and all deployed contracts must use the same ABI.
#
# Usage:
#   cd contracts && bash script/RedeployAll.sh
#
# Prerequisites:
#   - .env with DEPLOYER_PRIVATE_KEY and RPC_URL
#   - forge installed and contracts built (forge build)
#   - jq installed
#   - deployments/monad-testnet.json exists (for token addresses)

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
OUTPUT="$DEPLOY_DIR/monad-testnet.json"

if [ ! -f "$OUTPUT" ]; then
  echo "ERROR: $OUTPUT not found. Need existing deployment for token addresses."
  exit 1
fi

# Preserve token addresses from existing deployment
WETH=$(jq -r '.contracts.weth' "$OUTPUT")
USDC=$(jq -r '.contracts.usdc' "$OUTPUT")
BTC=$(jq -r '.contracts.btc // ""' "$OUTPUT")
MON=$(jq -r '.contracts.mon // ""' "$OUTPUT")

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

echo "=============================================="
echo " Itos Finance — Monad Testnet REDEPLOY"
echo " (keeping existing test tokens)"
echo "=============================================="
echo ""
echo "  WETH: $WETH"
echo "  USDC: $USDC"
[ -n "$BTC" ] && echo "  BTC:  $BTC"
[ -n "$MON" ] && echo "  MON:  $MON"
echo ""

# Detect chain ID
CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null || echo "10143")
echo "Chain ID: $CHAIN_ID"
echo ""

# Build first
echo "[build] Compiling contracts..."
forge build
echo ""

# ── Step 1: Deploy Factory ────────────────────────────────────────────────────
echo "[1/4] Deploying OPairFactory..."
deploy_step "[1/4] Factory" forge script script/01_DeployFactory.s.sol $FORGE_OPTS
FACTORY=$(extract_address "OPairFactory deployed at" "$LAST_OUTPUT")
if [ -z "$FACTORY" ]; then
  echo "ERROR: Failed to parse factory address."
  echo "$LAST_OUTPUT" | tail -20
  exit 1
fi
echo "  Factory: $FACTORY"
echo ""

# ── Step 2: Deploy Funder + MultiFunder + Bulletin ────────────────────────────
echo "[2/4] Deploying Funder..."
export FACTORY
deploy_step "[2/4] Funder" forge script script/02_DeployFunder.s.sol $FORGE_OPTS
FUNDER=$(extract_address "Funder deployed at" "$LAST_OUTPUT")
echo "  Funder: $FUNDER"

echo "[2/4] Deploying MultiFunder..."
deploy_step "[2/4] MultiFunder" forge script script/03_DeployMultiFunder.s.sol $FORGE_OPTS
MULTI_FUNDER=$(extract_address "MultiFunder deployed at" "$LAST_OUTPUT")
echo "  MultiFunder: $MULTI_FUNDER"

echo "[2/4] Deploying Bulletin..."
deploy_step "[2/4] Bulletin" forge script script/04_DeployBulletin.s.sol $FORGE_OPTS
BULLETIN=$(extract_address "Bulletin deployed at" "$LAST_OUTPUT")
echo "  Bulletin: $BULLETIN"
echo ""

# ── Write fresh deployment JSON (tokens + infra, no pairs yet) ────────────────
TOKEN_ENTRIES="\"weth\": \"$WETH\", \"usdc\": \"$USDC\""
[ -n "$BTC" ] && TOKEN_ENTRIES="$TOKEN_ENTRIES, \"btc\": \"$BTC\""
[ -n "$MON" ] && TOKEN_ENTRIES="$TOKEN_ENTRIES, \"mon\": \"$MON\""

cat > "$OUTPUT" <<ENDJSON
{
  "chain_id": $CHAIN_ID,
  "deployed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "contracts": {
    $TOKEN_ENTRIES,
    "factory": "$FACTORY",
    "funder": "$FUNDER",
    "multiFunder": "$MULTI_FUNDER",
    "bulletin": "$BULLETIN"
  }
}
ENDJSON

echo "  Wrote base deployment to $OUTPUT"
echo ""

# ── Step 3: Deploy all non-expired pairs ──────────────────────────────────────
echo "[3/4] Deploying OPair vaults from config..."
echo ""

NOW_TS=$(date +%s)
CONFIG_DIR="$ROOT_DIR/config"
TOTAL_PAIRS=0
SKIPPED_CONFIGS=0

for config in "$CONFIG_DIR"/*-pairs.json; do
  EXPIRY_TS=$(jq -r '.expiry' "$config")
  CONFIG_NAME=$(basename "$config")

  # Skip expired or about-to-expire configs (< 24h remaining)
  REMAINING=$(( EXPIRY_TS - NOW_TS ))
  if [ "$REMAINING" -lt 86400 ]; then
    echo "  [skip] $CONFIG_NAME — expired or < 24h remaining"
    SKIPPED_CONFIGS=$(( SKIPPED_CONFIGS + 1 ))
    continue
  fi

  echo "  [deploy] $CONFIG_NAME"
  bash script/deploy-pairs.sh "$config" "$OUTPUT"
  echo ""
done

echo ""

# ── Step 4: Setup per-maker Funders ───────────────────────────────────────────
echo "[4/4] Setting up per-maker funders..."
echo ""

# Also mint BTC and MON to deployer and makers if those tokens exist
if [ -n "$BTC" ]; then
  echo "  Minting BTC to deployer..."
  cast send "$BTC" "mint(address,uint256)" "$DEPLOYER_PUBLIC_KEY" "10000000000" \
    --rpc-url "$RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY" > /dev/null 2>&1 || true
fi
if [ -n "$MON" ]; then
  echo "  Minting MON to deployer..."
  cast send "$MON" "mint(address,uint256)" "$DEPLOYER_PUBLIC_KEY" "1000000000000000000000000" \
    --rpc-url "$RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY" > /dev/null 2>&1 || true
fi

bash script/SetupMakers.sh

echo ""

# ── Step 5: Sync addresses across the product ─────────────────────────────────
echo "[5/5] Syncing addresses to config, frontend, indexer, mock maker..."
cd "$ROOT_DIR/.."
bash scripts/sync-addresses.sh "$OUTPUT"
cd "$ROOT_DIR"

echo ""
echo "=============================================="
echo " Redeploy complete!"
echo " Deployment: $OUTPUT"
echo "=============================================="
echo ""
echo "Next steps:"
echo "  1. Restart the RFQ server (it loads deployment JSON on startup)"
echo "  2. Restart mock makers"
echo "  3. Mint tokens to user wallets: bash script/MintTokens.sh <address>"
echo ""
cat "$OUTPUT"
