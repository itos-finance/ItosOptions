# SwapExercising scripts

This folder ships a single Python orchestrator (`bootstrap_testnet.py`) plus eight
env-var-driven Forge scripts. The orchestrator pulls live addresses from
[itos-finance.tome.center/reference/addresses](https://itos-finance.tome.center/reference/addresses),
deploys (or reuses) shared infra — Uniswap V4 PoolManager, Uniswap V3 factory,
SwapExercisingFunder — and seeds USDC-quoted pools at current Bybit spot. The
market maker (`--mm`) ends up holding `DEFAULT_ADMIN_ROLE` + `SIGNER_ROLE` on
the funder so they can sign Quote messages off-chain.

## One-shot bootstrap

```bash
cd contracts
export RPC_URL=https://testnet-rpc.monad.xyz
export DEPLOYER_PRIVATE_KEY=0x...                         # any funded testnet key
python3 script/swapexercising/bootstrap_testnet.py \
    --mm 0x29c0e2fff128fFaE7c22B87938C061D0d8127fC7
```

Optional flags:

```
--addresses-url URL                # override the Itos page URL
--price-override 'ETH=2300,BTC=80000,MON=0.03'
--fresh                            # ignore cache state, redeploy everything
--state PATH                       # alternate state file
```

State (deployed addresses + per-pair init/seed flags) is persisted to
`cache/swapexercising-state.json`, which is gitignored. Funding state is **not**
persisted — bootstrap queries on-chain `balanceOf` and tops up only when an
account is below threshold (half of what `MintTokens.sh` mints). Re-runs are
safe and cheap.

What bootstrap does in order:

1. Fetch the addresses page — pull the OPair factory, token addresses, and
   the list of currently-live OPair vaults.
2. Look up each token's `decimals()` on-chain via `cast`.
3. Fetch Bybit spot for ETHUSDT / BTCUSDT / MONUSDT (or use `--price-override`),
   compute `sqrtPriceX96` and tick range per pair.
4. Mint test tokens to the deployer if any token is below threshold.
5. Deploy the V4 PoolManager once (or reuse from state) and initialize each
   pair's V4 pool.
6. Deploy the V3 factory once (or reuse) and create+initialize each pair's V3
   pool.
7. Deploy the SwapExercisingFunder, transferring both roles to `--mm`.
8. Seed V4 + V3 liquidity per pair (~$10k/side at current spot).
9. Mint test tokens to the MM and to the funder.
10. Print a summary including every available OPair vault address.

## Forking-anvil dry-run

`anvil --fork-url $MONAD_RPC --chain-id 10143 &` then run bootstrap pointing
at `http://127.0.0.1:8545`. The fork inherits the real factory + token + vault
state, so the page fetch and the on-chain steps behave like live testnet
without burning real testnet gas. Re-run on the same fork to confirm
idempotency (no duplicate deploys, mints skipped on the second pass).

## Quote and exercise (after bootstrap)

The MM signs `Quote` messages off-chain in their bot, naming the funder + a
specific OPair vault from the bootstrap summary. After buyers fill some
quotes, you (or the long holder) can exercise via:

```bash
SIGNER_PRIVATE_KEY=<MM-private-key>                          \
PAIR=0x...                                                   \
FUNDER=0x...   # funder address from bootstrap summary       \
SIZE=1000000000000000000                                     \
AMOUNT_IN=1000000000000000000                                \
AMOUNT_OUT_MIN=2000000000                                    \
POOL_FEE=500                                                 \
HOOKS=0x0000000000000000000000000000000000000000             \
forge script script/swapexercising/ExerciseWithSwapFunder.s.sol \
    --rpc-url $RPC_URL --broadcast --private-key <buyer-key>
```

`HOOKS=0x0000000000000000000000000000000000003333` swaps via Uniswap V3
instead of V4; pick a fee tier (`POOL_FEE=500/3000/10000`) accordingly.

## Files

User-facing entry points (top level):

| File | Purpose |
| --- | --- |
| `bootstrap_testnet.py` | Python orchestrator (see above) |
| `ExerciseWithSwapFunder.s.sol` | Exercise an OPair via the funder (V3 or V4 routing) |
| `README.md` | This file |

Helpers invoked by `bootstrap_testnet.py` (under `helpers/`):

| File | Purpose |
| --- | --- |
| `helpers/DeployV4Pool.s.sol` | Deploy V4 PoolManager (or reuse) and initialize a pool |
| `helpers/DeployV3Pool.s.sol` | Deploy V3 factory (or reuse) and create+initialize a pool |
| `helpers/DeploySwapExercisingFunder.s.sol` | Deploy the funder; optional role transfer |
| `helpers/SeedV4Liquidity.s.sol` | Add liquidity to a V4 pool |
| `helpers/SeedV3Liquidity.s.sol` | Add liquidity to a V3 pool |
| `helpers/SwapV4ToPrice.s.sol` | Push a V4 pool toward a target sqrtPrice |
| `helpers/SwapV3ToPrice.s.sol` | Push a V3 pool toward a target sqrtPrice |

Each `.s.sol` documents its required/optional env vars in its header
comment. They emit `OUT:KEY=VALUE` lines on stdout that `bootstrap_testnet.py` greps
to thread addresses between steps.
