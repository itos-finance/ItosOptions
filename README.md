# rfqJr — Options RFQ Smart Contracts

An on-chain options protocol where market makers quote prices off-chain via EIP-712 signatures, and trades are settled on-chain through a request-for-quote (RFQ) flow.

## Overview

Each `OPair` is a European-style option vault for a specific (riskToken, cashToken, strike, expiry, isCall) configuration. Sellers deposit collateral to write options; buyers pay a premium and acquire exercise rights. Positions are tracked as signed net balances — positive = long, negative = short — so opposing positions net against each other without requiring physical collateral movement.

Premiums are quoted as `premiumPerUnit`: the cashToken amount per `1e18` units of riskToken filled. For a partial fill, `totalPremium = premiumPerUnit * fill / 1e18`.

## Architecture

```
OPairFactory
  └─ creates OPair instances

OPair (per market)
  ├─ sell()         — seller shorts, MM longs via Funder
  ├─ buy()          — buyer longs, MM shorts via Funder
  ├─ exercise()     — buyer exercises via callback before expiry
  ├─ claim()        — seller redeems collateral/proceeds after expiry
  ├─ claimSettled() — redeem collateral pre-settled from netting
  └─ claimFees()    — factory owner collects protocol fees

SigVerifier (abstract)
  └─ inherited by OPair and Bulletin; provides EIP-712 Quote verification

Funder
  └─ Single shared pool. Admin holds funds; SIGNER_ROLE keys authorise transfers.

MultiFunder
  └─ Per-user balances. Any user deposits for themselves; vault debits on trade.

Bulletin
  └─ On-chain order book. MMs post signed quotes; counterparties fill them directly.
```

### Key design choices

- **Nonces live in OPair**, not in Funders. Each signer has one nonce per vault; consuming a quote (even a partial fill) increments the nonce, cancelling any remaining unfilled portion.
- **Partial fills** are opt-in per quote (`allowPartialFill` is part of the signed struct). Bulletin orders always set `allowPartialFill = false`.
- **OLongToken / OShortToken** are non-transferable display tokens whose balances derive directly from `netPosition`. They implement IERC20 for wallet visibility but revert on transfers.
- **Fees** are 7.5% of premium, collected in cashToken, claimable by the factory owner after expiry.

## EIP-712 Quote struct

```
Quote(
  address funder,
  address vault,
  int256  size,               // positive = buy intent, negative = sell intent
  uint256 premiumPerUnit,     // cashToken per 1e18 riskToken units
  uint256 validTillTimestamp,
  bool    allowPartialFill,
  uint256 nonce
)
```

The `verifyingContract` in the EIP-712 domain is the `OPair` (vault) address. The same signature is accepted by both `OPair.sell/buy` and `Bulletin.post`.

## Trade flows

**Sell path** — seller shorts, MM (buyer) longs:
1. MM signs a positive-size Quote and shares it (or posts it to `Bulletin`).
2. Seller calls `OPair.sell(funderAddr, mmSigner, size, fill, premiumPerUnit, validTill, allowPartialFill, sig)`.
3. OPair verifies the signature, pulls collateral from the seller, pulls `premiumPerUnit * fill / 1e18` cashToken from the MM's Funder, nets positions, and pays the seller premium minus fee.

**Buy path** — buyer longs, MM (seller) shorts:
1. MM signs a negative-size Quote and shares it.
2. Buyer calls `OPair.buy(funderAddr, mmSigner, size, fill, premiumPerUnit, validTill, allowPartialFill, sig)`.
3. OPair verifies the signature, pulls collateral from the MM's Funder, pulls premium from the buyer, nets positions, and deposits premium minus fee back into the MM's Funder.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)

## Setup

```shell
git submodule update --init --recursive
```

## Build

```shell
forge build
```

## Test

```shell
forge test
```

Run with verbosity for failing test traces:

```shell
forge test -vvv
```

Run a specific test file or test name:

```shell
forge test --match-path test/OptionVault.t.sol
forge test --match-test test_sell_sellerReceivesPremiumMinusFee
```

## Gas snapshot

```shell
forge snapshot
```

## Lint / format

```shell
forge fmt --check   # check only
forge fmt           # apply
```

## License

Core contracts (`src/`) are licensed under BUSL-1.1, converting to GPL-2.0-or-later on 2030-03-17. Interface files (`src/interfaces/`) are MIT.
