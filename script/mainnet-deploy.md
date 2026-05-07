# Mainnet deploy + role migration runbook

End state targeted:

- `OPairFactory.DEFAULT_ADMIN_ROLE` → `0xAFD30d1a63A1E355ee6c113D3e709Ed06DAda03B` (Gnosis Safe)
- `OPairFactory.ISSUER_ROLE` → `0x81785e00055159FCae25703D06422aBF5603f8A8` (Trezor)
- Old deployer `0x2a42be604948c0cce8a1fcfc781089611e2a1ea0` → no roles
- Strike pairs deployed for the next 3 Fridays-08:00-UTC (Deribit-aligned)

Order matters: migrate first (close leaked-key window), then deploy strikes from Trezor.

## Identities

| Role                                         | Var(s) in `.env`                              |
| -------------------------------------------- | --------------------------------------------- |
| Old deployer (signs migration steps 2 + 3)   | `DEPLOYER_PUBLIC_KEY`, `DEPLOYER_KEYSTORE`    |
| New issuer / Trezor (signs strike deploys)   | `ISSUER_PUBLIC_KEY`, `TREZOR_PATH`            |

The deployer identity is kept around even after it has zero on-chain roles — useful for testnet runs and any post-migration ops that need to sign as `0x2a42…`.

## Prereqs

- Foundry keystore `deployer-mainnet` imported (`cast wallet import deployer-mainnet --interactive`).
- Trezor plugged in, unlocked, Ethereum app ready.
- Confirm the Trezor BIP32 path for `ISSUER_PUBLIC_KEY` in Trezor Suite (default `m/44'/60'/0'/0/0`).
- `contracts/.env` populated with `DEPLOYER_*`, `ISSUER_PUBLIC_KEY`, `TREZOR_PATH`, `RPC_URL_143`.

## 1. Setup

```
cd /Users/bbroeking/projects/itos-finance/rfq/contracts
```

```
set -a; source .env; set +a; export RPC_URL=$RPC_URL_143
```

Sanity check (should print mainnet RPC and `0x2a42…`):

```
echo "${RPC_URL:0:40}..."; echo "$DEPLOYER_PUBLIC_KEY"
```

## 2. Migrate ISSUER_ROLE → Trezor

```
forge script script/09_TransferIssuer.s.sol --rpc-url $RPC_URL --account deployer-mainnet --sender $DEPLOYER_PUBLIC_KEY --broadcast
```

## 3. Migrate DEFAULT_ADMIN_ROLE → Safe (IRREVERSIBLE)

After this, `0x2a42…` cannot grant or revoke any role.

```
CONFIRM_TRANSFER_ADMIN=true forge script script/10_TransferAdmin.s.sol --rpc-url $RPC_URL --account deployer-mainnet --sender $DEPLOYER_PUBLIC_KEY --broadcast
```

## 4. Re-source env

After the migration, the deploy scripts read `ISSUER_PUBLIC_KEY` + `TREZOR_PATH` (already in `.env`). Just re-source so your shell sees them:

```
set -a; source .env; set +a
```

Sanity:

```
echo "$ISSUER_PUBLIC_KEY"; echo "$TREZOR_PATH"
```

Expect `0x81785e00055159FCae25703D06422aBF5603f8A8` and `m/44'/60'/0'/0/0`.

## 5. Rebuild

```
forge build
```

## 6. Deploy strikes (each line = 1 batch ≈ 24 Trezor confirms)

```
bash script/deploy-strikes.sh config/btc-usdc-20260515-1778832000.json config/weth-usdc-20260515-1778832000.json config/mon-usdc-20260515-1778832000.json
```

```
bash script/deploy-strikes.sh config/btc-usdc-20260522-1779436800.json config/weth-usdc-20260522-1779436800.json config/mon-usdc-20260522-1779436800.json
```

```
bash script/deploy-strikes.sh config/btc-usdc-20260529-1780041600.json config/weth-usdc-20260529-1780041600.json config/mon-usdc-20260529-1780041600.json
```

If a batch errors mid-way, re-running is safe — `deploy-pairs.sh` skips any `pair_…` key already populated in `deployments/monad-mainnet.json`.

## 7. Sync addresses to frontend + middleware

```
cd /Users/bbroeking/projects/itos-finance/rfq && ./scripts/sync-addresses.sh
```

## 8. Verify final state

```
cast call 0xcaD3e639BE89f673d7dBa41b2614369126CbD38f "hasRole(bytes32,address)(bool)" 0x0000000000000000000000000000000000000000000000000000000000000000 0xAFD30d1a63A1E355ee6c113D3e709Ed06DAda03B --rpc-url $RPC_URL
```

```
cast call 0xcaD3e639BE89f673d7dBa41b2614369126CbD38f "hasRole(bytes32,address)(bool)" $(cast keccak "ISSUER_ROLE") 0x81785e00055159FCae25703D06422aBF5603f8A8 --rpc-url $RPC_URL
```

```
cast call 0xcaD3e639BE89f673d7dBa41b2614369126CbD38f "hasRole(bytes32,address)(bool)" 0x0000000000000000000000000000000000000000000000000000000000000000 0x2a42be604948c0cce8a1fcfc781089611e2a1ea0 --rpc-url $RPC_URL
```

Expected: `true`, `true`, `false`.
