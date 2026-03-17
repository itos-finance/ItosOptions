# Monastery V1 — Options Platform Specification

## Overview

Monastery V1 is an on-chain options protocol where users can sell covered calls and cash-secured puts to earn yield, or buy options for hedging and speculation. Trades are matched via on-chain RFQ. The Monastery team initially market-makes using foundation token allocations.

This is a base-layer for other volatility products like non-liquidating money markets, ultra-short expiry options, PPNs, and more.

## Key Differences from Rysk

1. **On-chain users can buy options**, not just sell. This is crucial for future product extensions.
2. **Buyers do not post exercise collateral upfront.** If a buyer does not exercise before expiry, the option expires unexercised and the seller keeps their collateral plus the premium.
3. **More Markets** — The Monastery team market-makes both sides initially to bootstrap new markets, quoting buys and sells.
4. **On ETH Mainnet** — Cheap enough to be on Ethereum.
5. **American Options** — Simplifies settlement. Allows for flash loans via exercise callback.
6. **Position Netting** — Opposing long and short positions are netted on-chain, reducing collateral requirements and settling freed collateral immediately.
7. **Shorter Expiries** — Each OPair is a standalone instrument; any expiry can be created.

## Definitions

**Seller** — Posts collateral and receives premium. For a covered call, posts the risk token (e.g. ETH). For a cash-secured put, posts the cash token (e.g. USDC).

**Buyer** — Pays premium for the right to exercise before expiry. Does not post collateral at open.

**Risk Token** — The token the option is written on (e.g. ETH).

**Cash Token** — The token on the other side of the pair (e.g. USDC).

**Strike** — Fixed-point price of the risk token in cash token units (18-decimal). For a $2000 ETH/USDC call: `strike = 2000e6 * 1e18 / 1e18 = 2000e6`.

**Expiry** — Unix timestamp after which exercise is no longer possible and sellers may claim.

**Premium** — Cash token amount paid by the buyer to the seller, minus the protocol fee.

**Exercise** — Before expiry, the buyer triggers a callback that delivers the deposit token in exchange for the swap token at the strike price.

**Netting** — When a party holds an opposing position (e.g. a short seller who also holds a long), the opposing side is burned first and the freed collateral is credited for later claim via `claimSettled()`, reducing the capital required for the new position.

**Deposit Token** — The token sellers must post as collateral. `isCall ? riskToken : cashToken`.

**Swap Token** — The token buyers must provide when exercising. `isCall ? cashToken : riskToken`.

## Supported Instruments

### Covered Call
- Seller posts risk token (e.g. 1 ETH per contract).
- Buyer pays premium in cash token (e.g. USDC).
- Before expiry, buyer may exercise: vault delivers ETH to buyer's callback, callback returns USDC at strike price.
- If unexercised at expiry, seller claims their ETH back.

### Cash-Secured Put
- Seller posts cash token (e.g. USDC × strike per contract).
- Buyer pays premium in cash token.
- Before expiry, buyer may exercise: vault delivers USDC to buyer's callback, callback returns ETH at strike price.
- If unexercised at expiry, seller claims their USDC back.

## Lifecycle

### 1. Sell (Short-Side Entry)

`msg.sender` calls `OPair.sell()`, providing:
- Their own collateral (transferred directly from `msg.sender` to the vault).
- A signed buyer quote from a funder (premium pulled from the buyer's Funder contract).

The seller receives the premium minus the protocol fee immediately. Their short position is recorded. If the seller already holds a long position (from a prior buy), it is netted first — reducing or eliminating the new collateral requirement.

### 2. Buy (Long-Side Entry)

`msg.sender` calls `OPair.buy()`, providing:
- Their own premium payment (transferred directly from `msg.sender` to the vault).
- A signed seller quote from a funder (collateral pulled from the seller's Funder contract).

The buyer receives a long position. The seller's premium (minus fee) is deposited back into their Funder. If the buyer already holds a short position (from a prior sell), it is netted first — settled collateral is credited to `settledDepositToken`/`settledSwapToken` and claimable via `claimSettled()` at any time.

### 3. Exercise (Before Expiry)

The buyer calls `OPair.exercise()` at any point before expiry. This is an **American-style** option. The vault:
1. Deducts `size` from the buyer's long position.
2. Sends the deposit token to a callback contract designated by the buyer.
3. Calls `onExercise()` on the callback, expecting the swap token in return.
4. Reverts if the callback does not return the required swap token amount.

The callback pattern enables flash-loan-style exercise: the buyer can acquire the swap token from any on-chain source within the same transaction.

### 4. Claim (After Expiry)

After expiry, sellers call `OPair.claim(size, preferExercised)` to burn their short position and receive their share of the pool:

- `preferExercised = true`: takes from the exercised pool (swap tokens, e.g. USDC from exercised calls) first, then unexercised pool (deposit tokens).
- `preferExercised = false`: takes from the unexercised pool first, then exercised.

If requested from both pools, amounts are split proportionally to pool totals at the time of claim.

### 5. Claim Settled (Any Time)

Parties that had positions netted mid-trade may call `OPair.claimSettled()` at any time to retrieve the collateral credited during netting.

## Position Netting

All positions are tracked as a single signed integer per address (`netPosition`):
- `> 0` → long (holds exercise rights)
- `< 0` → short (has collateral obligation)
- `= 0` → flat

When a new trade would move a position across zero, the opposing portion is netted before any new collateral is committed:
- **Sell by a long holder**: existing long is burned; only the excess requires new collateral deposit.
- **Buy by a short holder**: existing short is settled (preferring unexercised first); freed collateral is stored in `settledDepositToken`/`settledSwapToken`.

Non-transferable `OLongToken` and `OShortToken` ERC20 tokens mirror the net position for display purposes.

## RFQ and Signing

All trades are matched via on-chain RFQ using EIP-712 off-chain signatures. The counterparty's funder verifies the signature before releasing funds.

### Quote Struct (EIP-712)

```
Quote(
  address funder,
  uint256 size,
  address vault,
  uint256 pricePerOption,
  uint256 validTillTimestamp,
  uint256 nonce
)
```

- `pricePerOption = premium * 1e18 / size` — encodes the per-unit price the signer agreed to.
- `nonce` is per-signer per-vault, incremented on every successful `requestFunds` call.
- `validTillTimestamp` is enforced by OPair before calling `requestFunds`.
- The domain separator uses `verifyingContract = funder` — each Funder deployment is its own signing domain.

### Nonce Queuing

Because the nonce is an explicit field in the signature, signers can pre-sign orders for future nonces. A quote for nonce `n+1` becomes valid as soon as the nonce `n` quote is consumed, enabling queued follow-up orders posted to the Bulletin.

### Signature Always Verified

Even when a trade is fully netted (no collateral physically moves), `requestFunds` is still called with `acquireAmount = 0`. The signature is always verified and the nonce always incremented, preventing an attacker from using a garbage signature to forcibly net another party's position.

## Funder Contracts

Funders hold the token balances that back signed quotes. Two implementations are available:

### Funder (Single-Owner)

A shared pool owned by one market-maker. The owner deposits tokens and may authorise additional signing keys (e.g. trading bots). Only the owner can withdraw.

### MultiFunder (Per-Signer Balances)

A permissionless pool where each signer maintains their own isolated balance. Anyone can deposit for any signer; only the signer themselves can withdraw their own balance. Suitable for multiple independent participants sharing one contract.

## Bulletin (On-Chain Order Book)

The Bulletin is a permissionless registry of signed orders. Market-makers post bids (willingness to buy) and offers (willingness to sell/write) for specific OPairs. The stored EIP-712 signature can be passed directly to `OPair.sell()` or `OPair.buy()` without modification.

- One bid and one offer per `(vault, signer)` pair — posting replaces any existing order.
- Posting verifies the signature on-chain; only valid signatures are stored.
- Orders can be cancelled by the signer at any time via `cancelBid`/`cancelOffer`.
- Fund availability is verified off-chain before acting on a Bulletin order.

## Protocol Fees

- A protocol fee of **7.5% (750 bps)** is charged on each premium payment.
- The fee is deducted from the premium before it reaches the counterparty.
- Accumulated fees are stored in `totalFees` on each OPair.
- The factory owner claims fees via `OPair.claimFees()` after expiry.

## Smart Contract Architecture

```
OPairFactory (Ownable2Step)
  └─ creates → OPair (per market: risk/cash/strike/expiry/isCall)
                  ├─ OLongToken  (non-transferable ERC20, mirrors long positions)
                  └─ OShortToken (non-transferable ERC20, mirrors short positions)

FundingVerifier (abstract)
  ├─ Funder       (single-owner shared pool)
  ├─ MultiFunder  (per-signer isolated balances)
  └─ Bulletin     (on-chain order book)
```

## Security Considerations

- Seller collateral is locked until expiry or netting. No early unilateral withdrawal.
- Buyer's worst case is premium loss — no collateral at risk beyond the premium paid.
- Signatures are always verified on `requestFunds` even when `acquireAmount = 0`, preventing forced netting attacks.
- Nonces are per-signer per-vault, preventing cross-vault and cross-funder replay attacks.
- Exercise uses a callback (CEI): state is updated before tokens are sent, preventing reentrancy from affecting position accounting.
- OPair creation is restricted to the factory owner, preventing rogue pair registration.
- Factory ownership uses Ownable2Step — transfers require explicit acceptance.
- `claimFees` and `extendExpiry` are restricted to the factory owner.

## Future Extensions (Not in V1 Scope)

- **Non-liquidating money market**: Separate protocol that buys options from V1 to hedge LP collateral positions.
- **Secondary market / position transfer**: Allow buyers to transfer long positions before expiry.
- **Portfolio margining**: Allow MMs with offsetting cross-pair positions to reduce capital requirements.
- **Multi-leg strategies**: Spreads, strangles, and other combinations built on top of V1 primitives.
- **Post-expiry exercise auction**: If a buyer lets an ITM option expire, auction the exercise right to recover closer-to-strike value for the seller.
