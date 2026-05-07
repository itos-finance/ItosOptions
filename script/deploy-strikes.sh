#!/usr/bin/env bash
# deploy-strikes.sh — deploy a batch of OPair strikes across multiple (risk, cash)
# markets that share a single expiry.
#
# Thin wrapper around deploy-pairs.sh. Takes one or more per-market configs
# (the existing contracts/config/*-pairs.json files) and:
#
#   - asserts every config carries the same .expiry (no accidental
#     WETH-Friday-N + BTC-Friday-N+1 batches);
#   - asserts that expiry is 08:00:00 UTC on a Friday (same hard rule that
#     lives inside deploy-pairs.sh — re-checked here up front so a bad
#     config fails before any forge call goes out);
#   - picks the matching deployments JSON from the live RPC's chain id
#     (143 → monad-mainnet.json, 10143 → monad-testnet.json), so the
#     caller doesn't have to remember the path;
#   - runs deploy-pairs.sh once per config.
#
# Usage:
#   cd contracts
#   export RPC_URL=https://rpc.monad.xyz         # or testnet RPC
#   export ISSUER_PUBLIC_KEY=0x...                # factory ISSUER_ROLE holder
#   # Then EITHER:
#   export ISSUER_KEYSTORE=<foundry-keystore-name>  # OR
#   export TREZOR_PATH="m/44'/60'/0'/0/0"         # Trezor derivation path
#   bash script/deploy-strikes.sh \
#     config/weth-usdc-20260508-pairs.json \
#     config/btc-usdc-20260508-pairs.json \
#     config/mon-usdc-20260508-pairs.json
#
# Override the auto-picked deployment file via DEPLOY_JSON=<path>. Override
# the Friday-08:00 check via ITOS_SKIP_EXPIRY_CHECK=1 (do NOT do this unless
# you're re-running a legacy config on purpose).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS_DIR="$(dirname "$SCRIPT_DIR")"
cd "$CONTRACTS_DIR"

if [ $# -lt 1 ]; then
  echo "Usage: deploy-strikes.sh <config1.json> [config2.json ...]" >&2
  exit 1
fi

# Load env so RPC_URL / DEPLOYER_PRIVATE_KEY populate from contracts/.env.
if [ -f .env ]; then
  set -a; source .env; set +a
fi
: "${RPC_URL:?RPC_URL not set}"
: "${ISSUER_PUBLIC_KEY:?ISSUER_PUBLIC_KEY not set (factory ISSUER_ROLE holder)}"
if [ -z "${TREZOR_PATH:-}" ] && [ -z "${ISSUER_KEYSTORE:-}" ]; then
  echo "Error: set TREZOR_PATH (e.g. \"m/44'/60'/0'/0/0\") or ISSUER_KEYSTORE" >&2
  exit 1
fi

# ── Resolve absolute config paths + sanity-check existence ────────────────
CONFIGS=()
for arg in "$@"; do
  if [ -f "$arg" ]; then
    CONFIGS+=("$(cd "$(dirname "$arg")" && pwd)/$(basename "$arg")")
  elif [ -f "$CONTRACTS_DIR/$arg" ]; then
    CONFIGS+=("$CONTRACTS_DIR/$arg")
  elif [ -f "$CONTRACTS_DIR/../$arg" ]; then
    CONFIGS+=("$(cd "$(dirname "$CONTRACTS_DIR/../$arg")" && pwd)/$(basename "$arg")")
  else
    echo "Error: config not found: $arg" >&2
    exit 1
  fi
done

# ── Check every config shares the same expiry ────────────────────────────
FIRST_EXPIRY=""
for f in "${CONFIGS[@]}"; do
  exp=$(jq -r '.expiry' "$f")
  if [ -z "$exp" ] || [ "$exp" = "null" ]; then
    echo "Error: $f has no .expiry field" >&2
    exit 1
  fi
  if [ -z "$FIRST_EXPIRY" ]; then
    FIRST_EXPIRY=$exp
  elif [ "$exp" != "$FIRST_EXPIRY" ]; then
    echo "Error: expiry mismatch — $f has $exp, expected $FIRST_EXPIRY" >&2
    echo "       All configs in a single batch must share the same expiry." >&2
    exit 1
  fi
done

# ── Friday 08:00 UTC sanity check (mirrors deploy-pairs.sh) ──────────────
if [ "${ITOS_SKIP_EXPIRY_CHECK:-0}" != "1" ]; then
  python3 - "$FIRST_EXPIRY" <<'PY' || exit 1
import sys, datetime as dt
ts = int(sys.argv[1])
d = dt.datetime.fromtimestamp(ts, tz=dt.timezone.utc)
ok = d.weekday() == 4 and d.hour == 8 and d.minute == 0 and d.second == 0
if not ok:
    sys.stderr.write(
        f"ERROR: expiry {ts} = {d.strftime('%a %Y-%m-%d %H:%M:%S UTC')}, "
        f"expected Friday 08:00:00 UTC.\n"
        f"       Set ITOS_SKIP_EXPIRY_CHECK=1 to override.\n"
    )
    sys.exit(1)
print(f"expiry OK: {d.strftime('%a %Y-%m-%d %H:%M:%S UTC')} (unix {ts})")
PY
fi

# ── Pick deployment JSON from chain id (or honour explicit DEPLOY_JSON) ──
CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null || echo "")
if [ -z "${DEPLOY_JSON:-}" ]; then
  case "$CHAIN_ID" in
    143)    DEPLOY_JSON="deployments/monad-mainnet.json" ;;
    10143)  DEPLOY_JSON="deployments/monad-testnet.json" ;;
    *)
      echo "Error: unknown chain id '$CHAIN_ID' from $RPC_URL." >&2
      echo "       Set DEPLOY_JSON=<path> explicitly." >&2
      exit 1
      ;;
  esac
fi
if [ ! -f "$DEPLOY_JSON" ]; then
  echo "Error: deployment JSON not found: $DEPLOY_JSON" >&2
  exit 1
fi
FACTORY=$(jq -r '.contracts.factory // ""' "$DEPLOY_JSON")
if [ -z "$FACTORY" ] || [ "$FACTORY" = "null" ]; then
  echo "Error: $DEPLOY_JSON has no factory address — deploy core contracts first." >&2
  exit 1
fi

echo "=================================================="
echo " deploy-strikes"
echo " chain id:      $CHAIN_ID"
echo " deployment:    $DEPLOY_JSON"
echo " factory:       $FACTORY"
echo " configs:       ${#CONFIGS[@]}"
echo " shared expiry: $FIRST_EXPIRY"
echo "=================================================="

for f in "${CONFIGS[@]}"; do
  echo ""
  echo ">> $(basename "$f")"
  # ITOS_SKIP_EXPIRY_CHECK=1 inside the child so it doesn't re-check per
  # file — we already validated once, and every file shares $FIRST_EXPIRY.
  ITOS_SKIP_EXPIRY_CHECK=1 bash "$SCRIPT_DIR/deploy-pairs.sh" "$f" "$DEPLOY_JSON"
done

echo ""
echo "=================================================="
echo " All configs deployed. Next:"
echo "   ./scripts/sync-addresses.sh  # from repo root"
echo "=================================================="
