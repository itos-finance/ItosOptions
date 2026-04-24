#!/usr/bin/env bash
# DeployMainnetCore.sh — deploys the Itos core singletons to Monad mainnet.
#
#   Factory → Funder → MultiFunder → Bulletin
#
# SKIPS (intentionally):
#   - 00_DeployTestTokens — mainnet has native WETH/WBTC/WMON/USDC, addresses
#     are already recorded in contracts/deployments/monad-mainnet.json.
#   - 05_CreatePair — pair vaults (strikes) are deployed separately via
#     contracts/script/deploy-pairs.sh once the core is verified.
#   - MintExerciseCallback — depends on @terence's pending changes (the
#     testnet version relies on MockERC20's permissionless mint, which does
#     not exist on mainnet). Wire it up in a follow-up once the rewritten
#     callback lands.
#   - Maker funders — deployed per maker during onboarding, not here.
#
# Usage:
#   cd contracts && bash script/DeployMainnetCore.sh
#
# Prerequisites:
#   - .env with DEPLOYER_PRIVATE_KEY and RPC_URL (pointed at Monad mainnet)
#   - forge installed and contracts built (forge build)
#
# Writes resulting addresses to deployments/monad-mainnet.json, preserving
# the token addresses already in that file. After running, execute
# ./scripts/sync-addresses.sh from the repo root to regenerate the frontend,
# indexer, and SDK constants.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

if [ -f .env ]; then
  set -a
  source .env
  set +a
fi

: "${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY not set}"
: "${RPC_URL:?RPC_URL not set (must be a Monad mainnet endpoint)}"

DEPLOY_FILE="$ROOT_DIR/deployments/monad-mainnet.json"
if [ ! -f "$DEPLOY_FILE" ]; then
  echo "ERROR: $DEPLOY_FILE missing. Seed it with token addresses first." >&2
  exit 1
fi

# Confirm we're on mainnet — refuse if the chain id doesn't match.
CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")
if [ "$CHAIN_ID" != "143" ]; then
  echo "ERROR: RPC_URL reports chain id $CHAIN_ID, expected 143 (Monad mainnet)." >&2
  echo "       Refusing to deploy — check your .env." >&2
  exit 1
fi

FORGE_OPTS="--rpc-url $RPC_URL --private-key $DEPLOYER_PRIVATE_KEY --broadcast"

extract_address() {
  local label="$1" output="$2"
  echo "$output" | grep "$label" | grep -oE '0x[0-9a-fA-F]{40}' | head -1 || true
}

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
    echo "$output" | tail -40
    exit 1
  fi
  LAST_OUTPUT="$output"
}

echo "==========================================="
echo " Itos Finance — Monad Mainnet (core only)"
echo "==========================================="
echo " Chain ID: $CHAIN_ID"
echo " RPC:      $RPC_URL"
echo ""
echo " Skipping: test tokens, MintExerciseCallback, pairs, makers."
echo ""

# Step 1: Factory
echo "[1/4] Deploying OPairFactory..."
deploy_step "[1/4] Factory" forge script script/01_DeployFactory.s.sol $FORGE_OPTS
FACTORY=$(extract_address "OPairFactory deployed at" "$LAST_OUTPUT")
[ -n "$FACTORY" ] || { echo "ERROR: could not parse factory address"; echo "$LAST_OUTPUT" | tail -20; exit 1; }
echo "  Factory: $FACTORY"
echo ""

# Step 2: Funder
echo "[2/4] Deploying Funder..."
export FACTORY
deploy_step "[2/4] Funder" forge script script/02_DeployFunder.s.sol $FORGE_OPTS
FUNDER=$(extract_address "Funder deployed at" "$LAST_OUTPUT")
[ -n "$FUNDER" ] || { echo "ERROR: could not parse funder address"; echo "$LAST_OUTPUT" | tail -20; exit 1; }
echo "  Funder: $FUNDER"
echo ""

# Step 3: MultiFunder
echo "[3/4] Deploying MultiFunder..."
deploy_step "[3/4] MultiFunder" forge script script/03_DeployMultiFunder.s.sol $FORGE_OPTS
MULTI_FUNDER=$(extract_address "MultiFunder deployed at" "$LAST_OUTPUT")
[ -n "$MULTI_FUNDER" ] || { echo "ERROR: could not parse multifunder address"; echo "$LAST_OUTPUT" | tail -20; exit 1; }
echo "  MultiFunder: $MULTI_FUNDER"
echo ""

# Step 4: Bulletin
echo "[4/4] Deploying Bulletin..."
deploy_step "[4/4] Bulletin" forge script script/04_DeployBulletin.s.sol $FORGE_OPTS
BULLETIN=$(extract_address "Bulletin deployed at" "$LAST_OUTPUT")
[ -n "$BULLETIN" ] || { echo "ERROR: could not parse bulletin address"; echo "$LAST_OUTPUT" | tail -20; exit 1; }
echo "  Bulletin: $BULLETIN"
echo ""

# Write back into monad-mainnet.json, preserving token addresses that were
# hand-seeded and any other fields already there. Uses jq for safety.
echo "Updating $DEPLOY_FILE..."
TMP=$(mktemp)
jq \
  --arg factory "$FACTORY" \
  --arg funder "$FUNDER" \
  --arg multiFunder "$MULTI_FUNDER" \
  --arg bulletin "$BULLETIN" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '
    .status = "deployed"
    | .deployed_at = $ts
    | .contracts.factory = $factory
    | .contracts.funder = $funder
    | .contracts.multiFunder = $multiFunder
    | .contracts.bulletin = $bulletin
    # MintExerciseCallback intentionally left null — needs terence's patch.
    | .contracts.mintExerciseCallback = null
  ' \
  "$DEPLOY_FILE" > "$TMP"
mv "$TMP" "$DEPLOY_FILE"

echo ""
echo "==========================================="
echo " Mainnet core deployment complete."
echo "==========================================="
cat "$DEPLOY_FILE"
echo ""
echo "Next steps:"
echo "  1. From repo root: ./scripts/sync-addresses.sh"
echo "  2. Commit the regenerated contracts/SDK files."
echo "  3. Register maker funders (per docs/internal/mainnet-deploy.md §4)."
echo "  4. Deploy pair strikes via contracts/script/deploy-pairs.sh."
echo "  5. Redeploy MintExerciseCallback once terence's changes land."
