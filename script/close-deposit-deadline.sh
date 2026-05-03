#!/usr/bin/env bash
# close-deposit-deadline.sh — calls setDepositDeadline(1) on a list of OPairs.
#
# Used to remove a batch of pair vaults from the live universe without
# waiting for natural expiry. Closing the deposit deadline reverts any new
# fills with DepositWindowClosed; existing positions exercise/claim normally.
#
# Default target: every `pair_btc_usdc_*` entry in deployments/monad-testnet.json
# (the 18-decimal testnet BTC pairs we're retiring after the BTC mock was
# redeployed at 18 decimals — see crates/itos-core/src/strike.rs).
#
# Usage:
#   cd contracts
#   bash script/close-deposit-deadline.sh                # dry-run, prints the list
#   bash script/close-deposit-deadline.sh --execute      # actually broadcasts
#
# Prerequisites:
#   contracts/.env with:
#     RPC_URL                — testnet RPC (chain id 10143)
#     DEPLOYER_PRIVATE_KEY   — factory owner (only key OPair.setDepositDeadline accepts)

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
: "${RPC_URL:?RPC_URL not set}"

EXECUTE=0
PREFIX="pair_btc_usdc_"
DEPLOY_FILE="$ROOT_DIR/deployments/monad-testnet.json"

while [ $# -gt 0 ]; do
  case "$1" in
    --execute) EXECUTE=1; shift;;
    --prefix)  PREFIX="$2"; shift 2;;
    --deploy)  DEPLOY_FILE="$2"; shift 2;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

# Refuse to run unless we're pointed at testnet — 18-dec BTC issue is testnet-only.
CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")
if [ "$CHAIN_ID" != "10143" ]; then
  echo "ERROR: RPC_URL reports chain id $CHAIN_ID, expected 10143 (Monad testnet)." >&2
  echo "       Refusing to run — this script only retires testnet BTC pairs." >&2
  exit 1
fi

if [ ! -f "$DEPLOY_FILE" ]; then
  echo "ERROR: $DEPLOY_FILE missing" >&2
  exit 1
fi

# Pull every contracts.<key> whose key starts with $PREFIX.
ENTRIES=()
while IFS= read -r line; do
  ENTRIES+=("$line")
done < <(jq -r --arg p "$PREFIX" '
  .contracts
  | to_entries
  | map(select(.key | startswith($p)))
  | sort_by(.key)
  | .[] | "\(.key) \(.value)"
' "$DEPLOY_FILE")

if [ "${#ENTRIES[@]}" -eq 0 ]; then
  echo "No entries matching prefix '$PREFIX' in $DEPLOY_FILE"
  exit 0
fi

echo "Chain ID: $CHAIN_ID  (Monad testnet)"
echo "Deploy file: $DEPLOY_FILE"
echo "Prefix: $PREFIX"
echo "Mode: $([ $EXECUTE -eq 1 ] && echo BROADCAST || echo "dry-run (use --execute to broadcast)")"
echo ""
echo "Targets (${#ENTRIES[@]}):"
for e in "${ENTRIES[@]}"; do
  echo "  $e"
done
echo ""

if [ $EXECUTE -ne 1 ]; then
  echo "Dry-run only. Re-run with --execute to call setDepositDeadline(1) on each."
  exit 0
fi

FAIL=0
for e in "${ENTRIES[@]}"; do
  KEY=$(echo "$e" | awk '{print $1}')
  ADDR=$(echo "$e" | awk '{print $2}')

  # Skip already-closed pairs (depositDeadline already in the past).
  CURRENT=$(cast call "$ADDR" "depositDeadline()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "")
  NOW=$(date -u +%s)
  # cast may print "1234 [scientific]" form; strip whitespace and any non-digit suffix.
  CURRENT_TS=$(echo "$CURRENT" | awk '{print $1}' | tr -dc '0-9')
  if [ -n "$CURRENT_TS" ] && [ "$CURRENT_TS" -le "$NOW" ]; then
    echo "  SKIP $KEY ($ADDR) — depositDeadline=$CURRENT_TS already in past"
    continue
  fi

  echo "  CALL $KEY ($ADDR) setDepositDeadline(1)..."
  if cast send "$ADDR" "setDepositDeadline(uint256)" 1 \
        --rpc-url "$RPC_URL" \
        --private-key "$DEPLOYER_PRIVATE_KEY" \
        >/dev/null 2>&1; then
    echo "    ok"
  else
    echo "    FAILED"
    FAIL=$((FAIL+1))
  fi
done

echo ""
if [ $FAIL -gt 0 ]; then
  echo "Done with $FAIL failure(s)."
  exit 1
fi
echo "Done. All pairs closed."
