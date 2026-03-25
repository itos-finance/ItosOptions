#!/usr/bin/env bash
# deploy-pairs.sh — deploy OPair vaults from a config file.
#
# Reads a JSON config, deploys any pairs not yet recorded in the deployment
# file, and writes each new address back to the deployment JSON.  Idempotent:
# pairs that already have an address are skipped.
#
# Strike encoding: strikeUSD * 10^(18 + cash_decimals - risk_decimals)
#   e.g. WETH/USDC → 18 + 6 - 18 = 6, so strikeUSD * 1_000_000
#
# Key format in deployment JSON:
#   pair_{underlying_lower}_{cash_lower}_{call|put}_{strikeUsd}_{YYYYMMDD}
#   e.g. pair_weth_usdc_call_2000_20260331
#
# Usage:
#   cd contracts && bash script/deploy-pairs.sh [config-file] [deployment-json]
#
# Defaults:
#   config-file     (required — e.g. config/weth-usdc-20260331-pairs.json)
#   deployment-json contracts/deployments/monad-testnet.json
#
# Prerequisites:
#   - .env with DEPLOYER_PRIVATE_KEY and RPC_URL
#   - jq installed
#   - forge installed and contracts compiled

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS_DIR="$(dirname "$SCRIPT_DIR")"
cd "$CONTRACTS_DIR"

# ── Args ───────────────────────────────────────────────────────────────────────

CONFIG_FILE="${1:?Usage: deploy-pairs.sh <config-file> [deployment-json]}"
# Also accept paths relative to the repo root (one level up)
if [ ! -f "$CONFIG_FILE" ]; then
  CONFIG_FILE="$CONTRACTS_DIR/../$1"
fi
if [ ! -f "$CONFIG_FILE" ]; then
  echo "Error: config file not found: $1" >&2
  exit 1
fi
CONFIG_FILE="$(cd "$(dirname "$CONFIG_FILE")" && pwd)/$(basename "$CONFIG_FILE")"

DEPLOY_JSON="${2:-deployments/monad-testnet.json}"
if [ ! -f "$DEPLOY_JSON" ]; then
  echo "Error: deployment JSON not found: $DEPLOY_JSON" >&2
  exit 1
fi
DEPLOY_JSON="$(cd "$(dirname "$DEPLOY_JSON")" && pwd)/$(basename "$DEPLOY_JSON")"

# ── Env ────────────────────────────────────────────────────────────────────────

if [ -f .env ]; then
  set -a; source .env; set +a
fi
: "${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY not set}"
: "${RPC_URL:?RPC_URL not set}"

# ── Read config ────────────────────────────────────────────────────────────────

UNDERLYING=$(jq -r '.underlying_symbol' "$CONFIG_FILE" | tr '[:upper:]' '[:lower:]')
CASH=$(jq -r '.cash_symbol'       "$CONFIG_FILE" | tr '[:upper:]' '[:lower:]')
RISK_TOKEN=$(jq -r '.risk_token'  "$CONFIG_FILE")
CASH_TOKEN=$(jq -r '.cash_token'  "$CONFIG_FILE")
RISK_DEC=$(jq -r '.risk_decimals' "$CONFIG_FILE")
CASH_DEC=$(jq -r '.cash_decimals' "$CONFIG_FILE")
MIN_DEPOSIT=$(jq -r '.min_deposit_size' "$CONFIG_FILE")
EXPIRY_TS=$(jq -r '.expiry' "$CONFIG_FILE")
PAIR_COUNT=$(jq '.pairs | length' "$CONFIG_FILE")

# Strike multiplier = 10^(18 + cash_decimals - risk_decimals)
EXP=$(( 18 + CASH_DEC - RISK_DEC ))
MULTIPLIER=$(python3 -c "print(10 ** $EXP)")

# Optional strike_divisor for sub-dollar assets (e.g. MON at $0.021 uses divisor=1000)
STRIKE_DIVISOR=$(jq -r '.strike_divisor // 1' "$CONFIG_FILE")

# Factory from deployment JSON
export FACTORY
FACTORY=$(jq -r '.contracts.factory' "$DEPLOY_JSON")

# Human-readable expiry date for identifiers (macOS + Linux)
EXPIRY_DATE=$(date -u -r "$EXPIRY_TS" +%Y%m%d 2>/dev/null \
  || date -u -d "@$EXPIRY_TS" +%Y%m%d 2>/dev/null \
  || echo "UNKNOWN")

FORGE_OPTS="--rpc-url $RPC_URL --private-key $DEPLOYER_PRIVATE_KEY --broadcast"

echo "=================================================="
echo " deploy-pairs: $CONFIG_FILE"
echo " deployment:   $DEPLOY_JSON"
echo " factory:      $FACTORY"
echo " expiry:       $EXPIRY_TS ($EXPIRY_DATE)"
echo "=================================================="
echo ""

DEPLOYED=0
SKIPPED=0

for i in $(seq 0 $(( PAIR_COUNT - 1 ))); do
  STRIKE_USD=$(jq -r ".pairs[$i].strike_usd" "$CONFIG_FILE")
  IS_CALL=$(jq -r ".pairs[$i].is_call" "$CONFIG_FILE")

  TYPE_STR="put"
  if [ "$IS_CALL" = "true" ]; then TYPE_STR="call"; fi

  PAIR_KEY="pair_${UNDERLYING}_${CASH}_${TYPE_STR}_${STRIKE_USD}_${EXPIRY_DATE}"

  # ── Idempotency check ──────────────────────────────────────────────────────
  EXISTING=$(jq -r --arg k "$PAIR_KEY" '.contracts[$k] // ""' "$DEPLOY_JSON")
  if [ -n "$EXISTING" ]; then
    echo "  [skip] $PAIR_KEY → $EXISTING"
    SKIPPED=$(( SKIPPED + 1 ))
    continue
  fi

  # ── Strike encoding ────────────────────────────────────────────────────────
  STRIKE_ENC=$(python3 -c "print(int($STRIKE_USD * $MULTIPLIER // $STRIKE_DIVISOR))")

  # ── Identifier / symbol ────────────────────────────────────────────────────
  UNDERLYING_UP=$(echo "$UNDERLYING" | tr '[:lower:]' '[:upper:]')
  CASH_UP=$(echo "$CASH" | tr '[:lower:]' '[:upper:]')
  TYPE_UP=$(echo "$TYPE_STR" | tr '[:lower:]' '[:upper:]')
  TYPE_CHAR="P"
  if [ "$IS_CALL" = "true" ]; then TYPE_CHAR="C"; fi

  export IDENTIFIER="${UNDERLYING_UP}-${CASH_UP}-${STRIKE_USD}-${TYPE_UP}-${EXPIRY_DATE}"
  export SYMBOL="${UNDERLYING_UP}${STRIKE_USD}${TYPE_CHAR}"
  export RISK_TOKEN
  export CASH_TOKEN
  export STRIKE="$STRIKE_ENC"
  export EXPIRY="$EXPIRY_TS"
  export IS_CALL
  export MIN_DEPOSIT_SIZE="$MIN_DEPOSIT"

  echo "  [deploy] $PAIR_KEY"
  echo "    strike_usd=$STRIKE_USD  strike_enc=$STRIKE_ENC  expiry=$EXPIRY_TS"
  echo "    IDENTIFIER=$IDENTIFIER  SYMBOL=$SYMBOL"

  # ── Run forge script ───────────────────────────────────────────────────────
  set +e
  OUTPUT=$(forge script script/05_CreatePair.s.sol $FORGE_OPTS 2>&1)
  RC=$?
  set -e

  if [ $RC -ne 0 ]; then
    echo ""
    echo "ERROR: forge script failed for $PAIR_KEY (exit $RC):"
    echo "$OUTPUT" | tail -20
    exit 1
  fi

  PAIR_ADDR=$(echo "$OUTPUT" | grep "OPair deployed at:" | grep -oE '0x[0-9a-fA-F]{40}' | head -1 || true)
  if [ -z "$PAIR_ADDR" ]; then
    echo "ERROR: could not parse pair address from forge output:"
    echo "$OUTPUT" | tail -10
    exit 1
  fi

  echo "    → $PAIR_ADDR"

  # ── Write address back to deployment JSON ──────────────────────────────────
  TMP=$(mktemp)
  jq --arg k "$PAIR_KEY" --arg v "$PAIR_ADDR" '.contracts[$k] = $v' "$DEPLOY_JSON" > "$TMP"
  mv "$TMP" "$DEPLOY_JSON"

  DEPLOYED=$(( DEPLOYED + 1 ))
  echo ""
done

echo "=================================================="
echo " Done: $DEPLOYED deployed, $SKIPPED skipped"
echo " Run: scripts/sync-addresses.sh to update contracts.ts"
echo "=================================================="
