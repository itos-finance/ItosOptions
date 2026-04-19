# Monastery V1 — Smart Contract Specification

## Goals

- Allocate option positions on a first-come-first-served basis via on-chain RFQ.
- Net opposing long and short positions automatically, reducing capital requirements.
- Exercised balances are served on a FIFO basis; sellers choose whether to prefer exercised or unexercised balances at claim time.
- Buyers may exercise at any point before expiry (American options) via a callback pattern.
- Multiple funder implementations support both single-owner and multi-party capital deployment.
- An on-chain Bulletin stores valid signed orders so any party can fill them without off-chain coordination.

---

## Contracts

### OPairFactory

Ownable2Step factory. Only the owner may create pairs or call `extendExpiry`/`claimFees` on deployed pairs.

```solidity
function createPair(
    address riskToken,
    address cashToken,
    uint128 strike,          // priceOfRiskToken in cashToken, 18-decimal fixed point
    uint256 expiry,          // unix timestamp, must be in the future
    bool    isCall,
    uint128 minDepositSize,  // minimum short size in risk-token units
    string  identifier,      // human-readable name
    string  symbol           // token symbol prefix
) external onlyOwner returns (address pair)
```

- Pairs are keyed by `keccak256(riskToken, cashToken, strike, expiry, isCall)` — duplicates revert.
- `isPair(addr)` — used by FunderBase and Bulletin to gate `requestFunds` callers.

---

### OPair

Core vault contract. One deployment per market (risk/cash/strike/expiry/isCall). Immutable parameters; expiry may be extended by the factory owner.

#### Position Tracking

All positions are stored as a single signed integer per address:

```solidity
mapping(address => int256) public netPosition;
// > 0  long  (exercise rights)
// < 0  short (collateral obligation)
// = 0  flat
```

Two non-transferable ERC20 display tokens are deployed at construction:
- `OLongToken` — `balanceOf(u) = max(0, netPosition[u])`
- `OShortToken` — `balanceOf(u) = max(0, -netPosition[u])`

#### Pool Accounting

```solidity
uint256 public totalSold;       // active short positions (risk-token units)
uint256 public totalExercised;  // exercised so far (risk-token units)
uint256 public totalFees;       // accumulated cashToken fees
```

#### Constants

```solidity
uint256 public constant FEE_BPS = 750;   // 7.5%
uint256 public constant BPS     = 10_000;
```

#### sell()

`msg.sender` writes a short position; the buyer's funder pays the premium.

```solidity
function sell(
    address funderAddr,        // buyer's Funder or MultiFunder
    address buyerSigner,       // address whose quote is verified on the funder
    uint128 size,              // risk-token units
    uint128 premium,           // cash-token units the buyer agreed to pay
    uint256 validTillTimestamp,
    bytes   calldata signature // EIP-712 Quote signed by buyerSigner
) external beforeExpiry
```

Flow:
1. `_addShort(seller, size)` — nets against any existing long; returns `physicalSize` (units needing new collateral).
2. If `physicalSize > 0`: pulls `_depositAmount(physicalSize)` deposit tokens from `msg.sender`; increments `totalSold`.
3. `_addLong(buyerSigner, size)` — nets against any existing short; settled collateral stored in `settledDepositToken`/`settledSwapToken`.
4. Calls `funder.requestFunds(buyerSigner, cashToken, premium, size, premium, validTill, sig)` — always, even if premium = 0 (nonce always consumed).
5. Verifies `cashToken` balance increased by at least `premium`.
6. Transfers `premium - fee` to `msg.sender`; accumulates `fee` in `totalFees`.

#### buy()

`msg.sender` acquires a long position; the seller's funder provides collateral.

```solidity
function buy(
    address sellerFunderAddr,  // seller's Funder or MultiFunder
    address sellerSigner,      // address whose quote is verified on the funder
    uint128 size,              // risk-token units
    uint128 premium,           // cash-token units msg.sender pays
    uint256 validTillTimestamp,
    bytes   calldata signature // EIP-712 Quote signed by sellerSigner
) external beforeExpiry
```

Flow:
1. `_addLong(buyer, size)` — nets against any existing short.
2. `_addShort(sellerSigner, size)` — nets against any existing long; returns `physicalSize`.
3. `acquireAmt = _depositAmount(physicalSize)` (0 when fully netted).
4. Calls `funder.requestFunds(sellerSigner, depositToken, premium, size, acquireAmt, validTill, sig)` — signature is always verified; `acquireAmt` may be 0.
5. Verifies `depositToken` balance increased by at least `acquireAmt`.
6. If `physicalSize > 0`: increments `totalSold`.
7. Pulls `premium` cash tokens from `msg.sender`; computes fee; deposits `premium - fee` into `sellerFunderAddr` for `sellerSigner`.

#### exercise()

American-style exercise via callback, callable by any long holder before expiry.

```solidity
function exercise(
    uint128 size,
    address callbackContract,
    bytes   calldata data
) external beforeExpiry
```

Flow (CEI order):
1. Validates `netPosition[msg.sender] >= size`.
2. Deducts `size` from `netPosition[msg.sender]`; increments `totalExercised`.
3. Sends `_depositAmount(size)` deposit tokens to `callbackContract`.
4. Calls `callbackContract.onExercise(depositToken, swapToken, depositAmt, swapAmt, data)`.
5. Verifies `swapToken` balance increased by at least `swapAmt`.

For calls: `swapAmt = size * strike / 1e18` (USDC). For puts: `depositAmt = size * strike / 1e18` (USDC).

#### claim()

After expiry. Seller burns `size` of their short position and receives pool tokens.

```solidity
function claim(uint128 size, bool preferExercised) external afterExpiry
```

- `preferExercised = true`: fills from exercised pool (swap tokens) first, then unexercised (deposit tokens).
- `preferExercised = false`: fills from unexercised pool first, then exercised.
- Decrements `totalSold` and `totalExercised` proportionally.

#### claimSettled()

Available any time. Withdraws collateral pre-credited from mid-trade netting.

```solidity
function claimSettled() external
```

Empties `settledDepositToken[msg.sender]` and `settledSwapToken[msg.sender]`.

#### extendExpiry() / claimFees()

Factory-owner only. `extendExpiry` requires `newExpiry > expiry`. `claimFees` drains `totalFees` and is available after expiry.

---

### FundingVerifier (abstract)

Shared base for Funder, MultiFunder, and Bulletin. Owns EIP-712 domain construction and signature verification.

#### EIP-712 Domain

```
EIP712Domain(string name, string version, uint256 chainId, address verifyingContract)
  name    = "MonasteryFunder"
  version = "1"
  verifyingContract = address of the Funder/MultiFunder (NOT Bulletin)
```

The domain separator is computed per-funder address, so each Funder deployment is an isolated signing domain.

#### Quote Typehash

```
Quote(address funder, uint256 size, address vault, uint256 pricePerOption, uint256 validTillTimestamp, uint256 nonce)
```

`pricePerOption = premium * 1e18 / size`. The signer commits to a per-unit price; the vault passes the total premium and derives `pricePerOption` for verification.

#### Key Internal Functions

```solidity
// Builds the EIP-712 digest for any funder/vault combination.
function _buildDigest(address funder, address vault, uint256 size, uint256 pricePerOption, uint256 validTillTimestamp, uint256 nonce) internal view returns (bytes32)

// Recovers the signer address from a digest. Used by Bulletin.
function _recoverSigner(address funder, address vault, uint256 size, uint256 pricePerOption, uint256 validTillTimestamp, uint256 nonce, bytes calldata signature) internal view returns (address)

// Verifies a Quote for this funder (funder = address(this), vault = msg.sender). Reverts on mismatch.
function _verifyQuote(address expectedSigner, uint256 currentNonce, uint256 size, uint256 pricePerOption, uint256 validTillTimestamp, bytes calldata signature) internal view

// Modifier: reverts if msg.sender is not a pair registered in the factory.
modifier onlyValidPair()
```

---

### Funder

Single-owner shared pool. All deposits go into one pool regardless of the `signer` argument.

```solidity
address public immutable owner;
mapping(address => bool) public authorizedSigners;
mapping(address => mapping(address => uint256)) public nonces; // signer → vault → nonce
```

- `deposit(signer, token, amount)` — permissionless; `signer` arg is emitted but ignored for accounting.
- `withdraw(token, amount)` — owner only; transfers to `owner`.
- `addSigner(addr)` / `removeSigner(addr)` — owner only.
- `requestFunds(signer, token, premium, size, acquireAmount, validTill, sig)` — `onlyValidPair`; reverts if `signer` is not `owner` or an authorized signer; verifies EIP-712 quote; increments `nonces[signer][msg.sender]`; transfers `acquireAmount` tokens to `msg.sender` (may be 0).

---

### MultiFunder

Per-signer isolated balances. Each signer manages their own funds independently.

```solidity
mapping(address => mapping(address => uint256)) public balances; // signer → token → amount
mapping(address => mapping(address => uint256)) public nonces;   // signer → vault → nonce
```

- `deposit(signer, token, amount)` — permissionless; credits `balances[signer][token]`.
- `withdraw(token, amount)` — credits `msg.sender`'s own balance only; reverts if insufficient.
- `requestFunds(signer, token, premium, size, acquireAmount, validTill, sig)` — `onlyValidPair`; checks `balances[signer][token] >= acquireAmount`; verifies quote; decrements balance; transfers `acquireAmount` (may be 0).

---

### Bulletin

Permissionless on-chain order book. No owner.

```solidity
// vault → signer → Order
mapping(address => mapping(address => Order)) private _bids;
mapping(address => mapping(address => Order)) private _offers;
```

```solidity
struct Order {
    address funder;
    address signer;
    uint128 pricePerOption;  // per risk-token unit in cash/deposit token
    uint128 size;
    uint256 validTillTimestamp;
    uint256 nonce;           // funder nonce the signature was made for
    bytes   signature;
}
```

- `postBid(vault, signer, funder, pricePerOption, size, validTill, nonce, sig)` — verifies signature recovers to `signer`; stores order; replaces any existing bid for `(vault, signer)`.
- `postOffer(...)` — same, for offers.
- `cancelBid(vault)` / `cancelOffer(vault)` — `msg.sender` deletes their own order.
- `getBid(vault, poster)` / `getOffer(vault, poster)` — view accessors.
- The stored `Order.signature` bytes can be passed **directly** to `OPair.sell()` (for a bid) or `OPair.buy()` (for an offer) without modification.

#### Nonce Queuing

`postBid`/`postOffer` accept an explicit `nonce` field. A signer can pre-sign and post an order for nonce `n+1` before nonce `n` is consumed. Once nonce `n` is used (in a prior trade), the queued order automatically becomes fillable.

---

## Collateral Reference

| Party | At Trade Open | At Exercise | At Expiry (Claim) |
|---|---|---|---|
| **Seller (call)** | Posts risk token (e.g. ETH) | Keeps USDC received | Receives ETH back (unexercised) or USDC (exercised) |
| **Seller (put)** | Posts cash token (e.g. USDC × strike) | Keeps ETH received | Receives USDC back (unexercised) or ETH (exercised) |
| **Buyer (call)** | Pays premium in USDC | Provides USDC, receives ETH via callback | Nothing to claim |
| **Buyer (put)** | Pays premium in USDC | Provides ETH, receives USDC via callback | Nothing to claim |

---

## Deployment Order

1. `OPairFactory` — no dependencies.
2. `Funder(factory)` / `MultiFunder(factory)` / `Bulletin(factory)` — each takes the factory address.
3. `factory.createPair(...)` — called by factory owner to deploy OPair instances.
