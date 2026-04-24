# contracts/script

Deployment scripts for the RFQ contracts. This doc focuses on the pair/strike
deployment flow — `deploy-strikes.sh` and `deploy-pairs.sh`. Core-contract
bootstrap scripts (`DeployAll.sh`, `DeployMainnetCore.sh`, `SetupMakers.sh`,
`MintTokens.sh`) are for one-time setup and have their own inline headers.

## Prerequisites

- `forge` (Foundry) installed, contracts compiled.
- `jq` and `python3` available on PATH.
- `contracts/.env` populated with:
  - `RPC_URL` — testnet or mainnet Monad RPC
  - `DEPLOYER_PRIVATE_KEY` — the account that is the factory issuer for the
    target deployment (see `contracts/deployments/<chain>.json`).

Both scripts auto-`source` `contracts/.env` if present, so you usually don't
need to `export` them in your shell.

## Pair config files

Configs live in `contracts/config/` and are named
`<underlying>-<cash>-<YYYYMMDD>-pairs.json`. Each file is one market at one
expiry, and lists every strike to deploy:

```json
{
  "description": "WETH/USDC options vaults — …",
  "underlying_symbol": "WETH",
  "cash_symbol": "USDC",
  "risk_token": "0x…",
  "cash_token": "0x…",
  "risk_decimals": 18,
  "cash_decimals": 6,
  "min_deposit_size": "10000000000000000",
  "expiry": 1774915200,
  "pairs": [
    { "strike_usd": 2000, "is_call": false },
    { "strike_usd": 2500, "is_call": true  }
  ]
}
```

`expiry` is a unix timestamp. **It must be 08:00:00 UTC on a Friday** —
both scripts reject anything else. Override with `ITOS_SKIP_EXPIRY_CHECK=1`
only for legacy re-runs.

For sub-dollar assets (e.g. MON at ~$0.021), add `"strike_divisor": 1000` so
the strike-encoding math stays in integer range.

## deploy-strikes.sh — batch driver (preferred)

Wraps `deploy-pairs.sh` for deploying the full weekly expiry in one go across
all underlyings (WETH + BTC + MON + …). It:

1. Asserts every config in the batch shares the same `.expiry` — prevents
   accidentally mixing Friday-N WETH with Friday-N+1 BTC.
2. Re-asserts the Friday 08:00 UTC rule up front, so a bad config fails
   before any `forge` call goes out.
3. Picks the deployment JSON automatically from `cast chain-id --rpc-url
   "$RPC_URL"` (143 → `deployments/monad-mainnet.json`, 10143 →
   `deployments/monad-testnet.json`).
4. Calls `deploy-pairs.sh` once per config.

### Usage

```bash
cd contracts
bash script/deploy-strikes.sh \
  config/weth-usdc-20260508-pairs.json \
  config/btc-usdc-20260508-pairs.json  \
  config/mon-usdc-20260508-pairs.json
```

Env overrides:

| Var                         | Purpose                                                            |
| --------------------------- | ------------------------------------------------------------------ |
| `DEPLOY_JSON=<path>`        | Skip chain-id detection; use this deployment file explicitly.      |
| `ITOS_SKIP_EXPIRY_CHECK=1`  | Bypass the Friday-08:00 guard. **Do not use for new deployments.** |

## deploy-pairs.sh — single-config driver

Deploys every strike in one config file. Idempotent: reads the deployment
JSON and skips any `pair_…` key that's already populated, so you can safely
re-run after a partial failure or to add new strikes to an existing config.

### Usage

```bash
cd contracts
bash script/deploy-pairs.sh config/weth-usdc-20260508-pairs.json
# or target a specific deployment file:
bash script/deploy-pairs.sh config/weth-usdc-20260508-pairs.json \
                           deployments/monad-mainnet.json
```

### What it does per strike

- Key format written to the deployment JSON:
  `pair_<underlying>_<cash>_<call|put>_<strikeUsd>_<YYYYMMDD>`
  (e.g. `pair_weth_usdc_call_2500_20260508`).
- Strike encoding:
  `strikeUsd * 10^(18 + cash_decimals - risk_decimals) / strike_divisor`.
  For WETH/USDC: `strike_usd * 1_000_000`.
- Runs `forge script script/05_CreatePair.s.sol --broadcast`, parses the
  deployed `OPair` address out of the forge output, and writes it back to the
  deployment JSON.

## After deploying

Always run the address sync from the repo root so the frontend and middleware
pick up the new pairs:

```bash
./scripts/sync-addresses.sh
```

Otherwise the frontend will fetch a pair address that doesn't exist on chain
and users get undecodable reverts.
