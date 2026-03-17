#!/usr/bin/env bash
# SetupMakers.sh — mints tokens and deploys per-maker funders
#
# Usage:
#   cd contracts && bash script/SetupMakers.sh
#
# Prerequisites:
#   - .env with DEPLOYER_PRIVATE_KEY and RPC_URL
#   - deployments/monad-testnet.json (from DeployAll.sh)
#   - jq installed

set -euo pipefail

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

DEPLOY_JSON="$ROOT_DIR/deployments/monad-testnet.json"
if [ ! -f "$DEPLOY_JSON" ]; then
  echo "ERROR: $DEPLOY_JSON not found. Run DeployAll.sh first."
  exit 1
fi

# Read addresses from deployment JSON
FACTORY=$(jq -r '.contracts.factory' "$DEPLOY_JSON")
WETH=$(jq -r '.contracts.weth' "$DEPLOY_JSON")
USDC=$(jq -r '.contracts.usdc' "$DEPLOY_JSON")

echo "========================================="
echo " Itos Finance — Maker Setup"
echo "========================================="
echo ""
echo "  Factory: $FACTORY"
echo "  WETH:    $WETH"
echo "  USDC:    $USDC"
echo ""

FORGE_OPTS="--rpc-url $RPC_URL --private-key $DEPLOYER_PRIVATE_KEY --broadcast"

# Run the setup script
echo "[*] Running 06_SetupMakers.s.sol..."
OUTPUT=$(FACTORY=$FACTORY WETH=$WETH USDC=$USDC \
  forge script script/06_SetupMakers.s.sol $FORGE_OPTS 2>&1)

echo "$OUTPUT" | tail -30

# Parse funder addresses from output
# The script logs "Funder deployed at: 0x..." for each maker
FUNDER_ADDRS=()
while IFS= read -r line; do
  FUNDER_ADDRS+=("$line")
done < <(echo "$OUTPUT" | grep "Funder deployed at:" | grep -oE '0x[0-9a-fA-F]{40}')

if [ ${#FUNDER_ADDRS[@]} -ne 3 ]; then
  echo "WARNING: Expected 3 funder addresses, got ${#FUNDER_ADDRS[@]}"
  echo "Attempting to parse from broadcast artifacts..."

  # Fallback: parse from forge broadcast artifacts
  BROADCAST_DIR="$ROOT_DIR/broadcast/06_SetupMakers.s.sol"
  if [ -d "$BROADCAST_DIR" ]; then
    LATEST=$(ls -t "$BROADCAST_DIR"/*/*.json 2>/dev/null | head -1)
    if [ -n "$LATEST" ]; then
      FUNDER_ADDRS=($(jq -r '.transactions[] | select(.transactionType == "CREATE" and .contractName == "Funder") | .contractAddress' "$LATEST"))
    fi
  fi
fi

MAKER_ADDRESSES=("0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC" "0x90F79bf6EB2c4f870365E785982E1f101E93b906" "0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65")

# Update deployment JSON with maker funders
if [ ${#FUNDER_ADDRS[@]} -eq 3 ]; then
  echo ""
  echo "[*] Updating $DEPLOY_JSON with maker funders..."

  jq --arg f0 "${FUNDER_ADDRS[0]}" \
     --arg f1 "${FUNDER_ADDRS[1]}" \
     --arg f2 "${FUNDER_ADDRS[2]}" \
     --arg m0 "${MAKER_ADDRESSES[0]}" \
     --arg m1 "${MAKER_ADDRESSES[1]}" \
     --arg m2 "${MAKER_ADDRESSES[2]}" \
     '.maker_funders = {
        "maker_0": { "address": $m0, "funder": $f0 },
        "maker_1": { "address": $m1, "funder": $f1 },
        "maker_2": { "address": $m2, "funder": $f2 }
      }' "$DEPLOY_JSON" > "${DEPLOY_JSON}.tmp" && mv "${DEPLOY_JSON}.tmp" "$DEPLOY_JSON"

  echo ""
  echo "========================================="
  echo " Maker Setup Complete!"
  echo "========================================="
  echo ""
  echo "  Maker 0: ${MAKER_ADDRESSES[0]}"
  echo "    Funder: ${FUNDER_ADDRS[0]}"
  echo ""
  echo "  Maker 1: ${MAKER_ADDRESSES[1]}"
  echo "    Funder: ${FUNDER_ADDRS[1]}"
  echo ""
  echo "  Maker 2: ${MAKER_ADDRESSES[2]}"
  echo "    Funder: ${FUNDER_ADDRS[2]}"
  echo ""
else
  echo ""
  echo "WARNING: Could not parse all 3 funder addresses."
  echo "Please update $DEPLOY_JSON manually."
  echo "Parsed addresses: ${FUNDER_ADDRS[*]:-none}"
fi
