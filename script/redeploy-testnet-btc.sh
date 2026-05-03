#!/usr/bin/env bash
# redeploy-testnet-btc.sh — one-shot rollback of testnet BTC to 8 decimals.
#
# What this does (in order):
#
#   1. Refuses to run unless RPC_URL reports chain id 10143.
#   2. forge-broadcasts script/08_RedeployBtc.s.sol — deploys a fresh
#      MockERC20("Bitcoin", "BTC", 8). Captures the new address.
#   3. Updates contracts/deployments/monad-testnet.json:
#        - contracts.btc           → new address
#        - token_decimals.btc      → 8 (added if absent)
#        - removes every pair_btc_usdc_* key (the old 18-dec pairs were
#          retired via close-deposit-deadline.sh and are no longer
#          deployable; leaving them in the JSON only confuses
#          deploy-pairs.sh idempotency checks).
#   4. Patches crates/itos-core/src/strike.rs to add the new BTC address
#      to decimals_for_token's 8-dec list, the BTC group in
#      min_plausible_micro_usd, and the channel-aware list in
#      is_known_risk_token. Idempotent — re-runs are safe.
#   5. Prints next-step commands (./scripts/sync-addresses.sh, regenerate
#      and deploy fresh BTC pair configs).
#
# Prereqs (.env in contracts/):
#   RPC_URL                — testnet RPC (chain id 10143)
#   DEPLOYER_PRIVATE_KEY   — has MON for gas; will own the new BTC mint()
#                            (it's permissionless on MockERC20 anyway)
#
# Usage:
#   cd contracts
#   bash script/redeploy-testnet-btc.sh                 # broadcast
#   bash script/redeploy-testnet-btc.sh --dry-run       # forge + JSON/Rust
#                                                       # mutations skipped

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(dirname "$CONTRACTS_DIR")"
cd "$CONTRACTS_DIR"

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then DRY_RUN=1; fi

# Source .env, but command-line / inherited env vars win — `.env`'s default
# RPC_URL is mainnet for most operators, and we don't want a stale default
# overriding a deliberate `RPC_URL=…testnet… bash redeploy-testnet-btc.sh`.
if [ -f .env ]; then
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue
    var="${line%%=*}"
    if [ -z "${!var:-}" ]; then
      export "$line"
    fi
  done < .env
fi
: "${RPC_URL:?RPC_URL not set}"
: "${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY not set}"

CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null || echo "")
if [ "$CHAIN_ID" != "10143" ]; then
  echo "ERROR: RPC_URL reports chain id '$CHAIN_ID', expected 10143 (Monad testnet)." >&2
  echo "       Refusing to run — this script only redeploys testnet BTC." >&2
  exit 1
fi

DEPLOY_JSON="$CONTRACTS_DIR/deployments/monad-testnet.json"
STRIKE_RS="$ROOT_DIR/crates/itos-core/src/strike.rs"
[ -f "$DEPLOY_JSON" ] || { echo "ERROR: $DEPLOY_JSON missing" >&2; exit 1; }
[ -f "$STRIKE_RS"   ] || { echo "ERROR: $STRIKE_RS missing"   >&2; exit 1; }

OLD_BTC=$(jq -r '.contracts.btc // ""' "$DEPLOY_JSON")
echo "=================================================="
echo " redeploy-testnet-btc"
echo "=================================================="
echo " chain id:       $CHAIN_ID"
echo " deployment:     $DEPLOY_JSON"
echo " strike.rs:      $STRIKE_RS"
echo " current BTC:    ${OLD_BTC:-<unset>}"
echo " mode:           $([ $DRY_RUN -eq 1 ] && echo dry-run || echo broadcast)"
echo "=================================================="

# ── 1. Deploy ──────────────────────────────────────────────────────────────
if [ $DRY_RUN -eq 1 ]; then
  echo ""
  echo "[dry-run] would broadcast: forge script script/08_RedeployBtc.s.sol"
  NEW_BTC="0xDEAD000000000000000000000000000000000DEC"
else
  echo ""
  echo ">> forge script script/08_RedeployBtc.s.sol --broadcast"
  set +e
  OUT=$(forge script script/08_RedeployBtc.s.sol \
    --rpc-url "$RPC_URL" \
    --private-key "$DEPLOYER_PRIVATE_KEY" \
    --broadcast 2>&1)
  RC=$?
  set -e
  echo "$OUT"
  if [ $RC -ne 0 ]; then
    echo "ERROR: forge script failed (exit $RC)" >&2
    exit 1
  fi
  NEW_BTC=$(echo "$OUT" | grep "BTC deployed at:" | grep -oE '0x[0-9a-fA-F]{40}' | head -1 || true)
  if [ -z "$NEW_BTC" ]; then
    echo "ERROR: could not parse new BTC address from forge output" >&2
    exit 1
  fi
fi

echo ""
echo "new BTC address: $NEW_BTC"

# ── 2. Update monad-testnet.json ──────────────────────────────────────────
echo ""
echo ">> updating $DEPLOY_JSON"
python3 - "$DEPLOY_JSON" "$NEW_BTC" <<'PY'
import json, sys
path, new_btc = sys.argv[1], sys.argv[2]
with open(path) as f:
    d = json.load(f)
d.setdefault("contracts", {})["btc"] = new_btc
d.setdefault("token_decimals", {})["btc"] = 8
# Strip retired pair_btc_usdc_* keys — the old 18-dec pairs were closed via
# setDepositDeadline(1); their addresses still exist on-chain but no fills
# can happen. Removing the keys keeps deploy-pairs.sh's idempotency map
# clean for the next round of pair deploys.
removed = [k for k in list(d.get("contracts", {}).keys()) if k.startswith("pair_btc_usdc_")]
for k in removed:
    del d["contracts"][k]
with open(path, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
print(f"  contracts.btc      → {new_btc}")
print(f"  token_decimals.btc → 8")
print(f"  removed {len(removed)} retired pair_btc_usdc_* key(s)")
PY

# ── 3. Patch strike.rs ────────────────────────────────────────────────────
echo ""
echo ">> patching $STRIKE_RS"
python3 - "$STRIKE_RS" "$NEW_BTC" <<'PY'
import re, sys
path, new_btc = sys.argv[1], sys.argv[2].lower()
with open(path) as f:
    src = f.read()

# Helper: insert `addr` immediately above the line that matches both
# `target_rhs` and `anchor_line`. Idempotent — skips if `addr` already
# appears in the 12 lines immediately above the anchor (i.e. inside the
# same match arm).
def insert_into_arm(src: str, target_rhs: str, anchor_line: str, addr: str) -> tuple[str, bool]:
    lines = src.splitlines(keepends=True)
    out = []
    inserted = False
    for i, ln in enumerate(lines):
        if not inserted and anchor_line in ln and target_rhs in ln:
            window = "".join(lines[max(0, i - 12):i])
            if addr in window:
                pass  # already present in this arm
            else:
                indent = re.match(r"\s*", ln).group(0)
                out.append(f'{indent}| "{addr}"\n')
            inserted = True
        out.append(ln)
    return "".join(out), inserted and addr in "".join(out)

# decimals_for_token: anchor on `=> 8,` line that closes the BTC group
src, a = insert_into_arm(src, "=> 8,", '"0x0555e30da8f98308edb960aa94c0db47230d2b9c" => 8,', new_btc)
print("  decimals_for_token: " + ("added" if a else "already present"))

# min_plausible_micro_usd: anchor on `=> 1_000_000_000,` (BTC group)
src, b = insert_into_arm(src, "=> 1_000_000_000,",
                         '"0x0555e30da8f98308edb960aa94c0db47230d2b9c" => 1_000_000_000,',
                         new_btc)
print("  min_plausible_micro_usd: " + ("added" if b else "already present"))

# is_known_risk_token: anchor on the closing `)` of the matches! macro is
# trickier; instead, anchor on the existing testnet BTC line that lives
# in the channel-aware section.
match = re.search(r"pub fn is_known_risk_token.*?\n\}", src, re.DOTALL)
if match and new_btc in match.group(0):
    print("  is_known_risk_token: already present")
elif match:
    needle = '| "0xafe18570017e9dc4d955280d1c0486ca3b21bafe"'
    if needle in match.group(0):
        # Splice into is_known_risk_token's body only.
        body = match.group(0)
        new_body = body.replace(needle, needle + '\n            | "' + new_btc + '"', 1)
        src = src[:match.start()] + new_body + src[match.end():]
        print("  is_known_risk_token: added")
    else:
        print("  is_known_risk_token: WARNING — anchor not found, please add by hand")
else:
    print("  is_known_risk_token: WARNING — function body not found, please add by hand")

with open(path, "w") as f:
    f.write(src)
PY

# ── 4. Next steps ────────────────────────────────────────────────────────
cat <<NEXT

==================================================
 Done.

 Next steps:
   1. cd $ROOT_DIR
   2. ./scripts/sync-addresses.sh
        # propagates the new BTC to frontend/, indexer/, sdks/
   3. cd $ROOT_DIR/../OptMM
      .venv/bin/python scripts/strikes_to_pair_configs.py \\
        --strikes workspace/strikes/strikes_<DATE>.csv --chain testnet
        # regenerates BTC configs with risk_decimals=8 (from the
        # token_decimals block we just added)
   4. cd $ROOT_DIR/contracts
      bash script/deploy-strikes.sh \\
        config/btc-usdc-<DATE>-<UNIX>.json \\
        config/weth-usdc-<DATE>-<UNIX>.json \\
        config/mon-usdc-<DATE>-<UNIX>.json
   5. cd $ROOT_DIR && ./scripts/sync-addresses.sh
        # picks up the new pair_btc_* keys

 Commit the JSON + strike.rs changes.
==================================================
NEXT
