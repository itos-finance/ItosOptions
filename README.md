# rfqJr — Options RFQ Smart Contracts

An on-chain options protocol where market makers quote prices off-chain via EIP-712 signatures, and trades are settled on-chain through a request-for-quote (RFQ) flow.

## Overview

Each `OPair` is an option vault for a specific (riskToken, cashToken, strike, expiry, isCall) configuration. Sellers deposit collateral to write options; buyers pay a premium and acquire exercise rights. Positions are tracked as signed net balances — positive = long, negative = short — so opposing positions net against each other without requiring physical collateral movement.

Premiums are quoted as `premiumPerUnit`: the cashToken amount per `1e18` units of riskToken filled. For a partial fill, `totalPremium = premiumPerUnit * fill / 1e18`.

## What's distinctive

- **American-style exercise window.** Exercises are allowed at any point between `exerciseEarliest` (a buffer after deployment, default 4 hours) and `expiry`. There is no must-wait-until-expiry restriction.
- **Reversible exercise (`unexercise`).** Within that same window a long that has exercised can call `unexercise` to undo the swap at the strike price. This means an exercised position remains tradeable — holders can flip in and out of the underlying as the spot moves, effectively trading gamma against the strike without additional funding. It also nudges market makers toward European-style payoff behaviour because mid-window exercises are not sticky.
- **Exercise-as-flash-swap via `IExerciseCallback`.** `exercise` and `unexercise` both pay tokens *out* of the vault first and then invoke `onExercise` on a caller-supplied contract, which must return the counter-token within the same transaction or the call reverts. The callback receives `(tokenGiven, tokenExpected, amountGiven, amountExpected, data)` and the same interface is used in both directions — `unexercise` simply swaps which side is "given" vs. "expected". This makes it a flash-swap primitive: no upfront capital is needed if the callback can source the expected token (e.g. from a DEX) using the tokens just received.
- **Bring-your-own callback, with a default.** Anyone can write their own `IExerciseCallback` implementation tailored to their funding source (DEX router, vault, signer-gated pool, etc.). For market makers who want to fund exercises directly out of an existing shared pool, [`ExercisingFunder`](src/utilities/ExercisingFunder.sol) is provided in `src/utilities/`: it inherits `Funder` and implements `onExercise` to pay the required token from the pool, gated by an EIP-712 signature from a `SIGNER_ROLE` key (with a per-vault nonce to prevent replay).

## Architecture

```
OPairFactory
  └─ creates OPair instances

OPair (per market)
  ├─ sell()         — seller shorts, MM longs via Funder
  ├─ buy()          — buyer longs, MM shorts via Funder
  ├─ take()         — sign-dispatching wrapper around buy/sell
  ├─ exercise()     — long swaps at strike via IExerciseCallback (flash-swap)
  ├─ unexercise()   — undo a prior exercise via IExerciseCallback
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

ExercisingFunder (utilities/)
  └─ Funder + IExerciseCallback. Pays exercise/unexercise out of the shared
     pool, gated by an EIP-712 signature from a SIGNER_ROLE key.
```

### Key design choices

- **Nonces live in OPair**, not in Funders, and are namespaced by `channel`. Each `(signer, channel)` has its own nonce; consuming a quote (even a partial fill) increments that channel's nonce, cancelling any remaining unfilled portion on the same channel. See [Channels and nonces](#channels-and-nonces) for how this enables both concurrent and serial quoting.
- **Partial fills** are opt-in per quote (`allowPartialFill` is part of the signed struct). Bulletin orders always set `allowPartialFill = false`.
- **OLongToken / OShortToken / OExercisedToken** are non-transferable display tokens whose balances derive from authoritative state — `netPosition` for long/short, `exercised` for the exercised token. They implement IERC20 for wallet visibility but revert on transfers. The exercised token matters here because exercises are reversible: a holder can see their long, short, and exercised balances side-by-side in their wallet and decide whether to `unexercise` back into a long.
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
  uint256 channel,            // independent nonce namespace per (signer, channel)
  uint256 nonce
)
```

The `verifyingContract` in the EIP-712 domain is the `OPair` (vault) address. The same signature is accepted by both `OPair.sell/buy` and `Bulletin.post`.

### Channels and nonces

Each `(signer, channel)` pair has its own independent nonce stream in `OPair.nonces`. A fill consumes the *current* nonce for that channel and increments it; a signature against a stale nonce is rejected.

This gives signers two complementary tools:

- **Concurrent quoting (different channels).** A signer can keep multiple unrelated quotes live at the same time by placing each on its own channel. Filling one channel's quote does not invalidate quotes on any other channel, so a single signer can quote several markets / sizes / counterparties in parallel without one fill cancelling the others.
- **Serial quoting (same channel, consecutive nonces).** Multiple quotes pre-signed on the *same* channel are strictly ordered: a quote signed at nonce `N+1` cannot be filled until the quote at nonce `N` has been consumed (or skipped via `bumpNonce`). This lets a signer pre-sign a sequence of legs that must be filled in order — e.g. "leg B is only valid if leg A has already been taken" — without any on-chain coordination between the takers.

`bumpNonce(channel, amount)` lets a signer self-cancel one or more outstanding quotes on a channel by advancing its nonce past them.

## Trade flows

**Sell path** — seller shorts, MM (buyer) longs:
1. MM signs a positive-size Quote and submits it to the off-chain RFQ server, which forwards it to the seller.
2. Seller calls `OPair.sell(funderAddr, mmSigner, size, fill, premiumPerUnit, validTill, allowPartialFill, sig)`.
3. OPair verifies the signature, pulls collateral from the seller, pulls `premiumPerUnit * fill / 1e18` cashToken from the MM's Funder, nets positions, and pays the seller premium minus fee.

**Buy path** — buyer longs, MM (seller) shorts:
1. MM signs a negative-size Quote and submits it to the off-chain RFQ server, which forwards it to the buyer.
2. Buyer calls `OPair.buy(funderAddr, mmSigner, size, fill, premiumPerUnit, validTill, allowPartialFill, sig)`.
3. OPair verifies the signature, pulls collateral from the MM's Funder, pulls premium from the buyer, nets positions, and deposits premium minus fee back into the MM's Funder.

## Exercise & unexercise

Available to any long holder between `exerciseEarliest` and `expiry`. Both directions reuse `IExerciseCallback.onExercise` — `unexercise` is just the reverse swap.

**Exercise** (long → swap token):
1. Long calls `OPair.exercise(size, callbackContract, data)`.
2. Vault decrements `netPosition`, increments `exercised`, and sends `depositToken` to `callbackContract`.
   - Calls: vault sends riskToken; callback owes `size * strike / 1e18` cashToken.
   - Puts:  vault sends `size * strike / 1e18` cashToken; callback owes riskToken.
3. Vault invokes `onExercise(tokenGiven, tokenExpected, amountGiven, amountExpected, data)`. The callback must transfer exactly `amountExpected` of `tokenExpected` back before returning, or the call reverts.

**Unexercise** (swap token → long): same flow with the token sides reversed. The vault credits `netPosition` and decrements `exercised`. Self-netting is supported: if the caller is also short on the same vault, the new long can settle against their existing exercised balance with no callback hop.

**Writing your own callback.** Any contract implementing `IExerciseCallback` can be used. Common patterns: route the received token through a DEX to source the expected token, draw from a pre-approved treasury, or gate the call behind your own signature scheme. The callback is responsible for *all* sourcing — OPair only verifies that `amountExpected` arrives.

**Default implementation: [`ExercisingFunder`](src/utilities/ExercisingFunder.sol)**. A `Funder` that doubles as the callback. `data` is decoded as `(address signer, bytes signature)` over `Exercise(address vault, uint256 nonce)` — the signer must hold `SIGNER_ROLE` and the per-vault nonce is consumed on each call. On a valid signature, the contract pays `amountExpected` straight from its pooled balance.

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
