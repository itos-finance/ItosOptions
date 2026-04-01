// SPDX-License-Identifier: BUSL-1.1
// Change Date: 2030-03-17  (license converts to GPL-2.0-or-later on this date)
pragma solidity ^0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    IAccessControl
} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {SigVerifier} from "./SigVerifier.sol";
import {IOPair} from "./interfaces/IOPair.sol";
import {IFunderBase} from "./interfaces/IFunderBase.sol";
import {IExerciseCallback} from "./interfaces/IExerciseCallback.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Display ERC20 position tokens – non-transferable, mint/burn by OPair only.
// Balances mirror the authoritative netPosition mapping in OPair.
// ─────────────────────────────────────────────────────────────────────────────

abstract contract OToken is IERC20 {
    IOPair public immutable pair;

    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    error OnlyPair();
    error NonTransferable();

    constructor(string memory id, string memory sym) {
        pair = IOPair(msg.sender);
        name = id;
        symbol = sym;
    }

    /// @inheritdoc IERC20
    function totalSupply() public view returns (uint256) {
        return pair.totalSold();
    }

    function transfer(address, uint256) public pure returns (bool) {
        revert NonTransferable();
    }

    /// @inheritdoc IERC20
    function allowance(address, address) public pure returns (uint256) {
        revert NonTransferable();
    }

    function approve(address, uint256) public pure returns (bool) {
        revert NonTransferable();
    }

    function transferFrom(
        address,
        address,
        uint256
    ) public pure returns (bool) {
        revert NonTransferable();
    }
}

contract OLongToken is OToken {
    constructor(
        string memory id,
        string memory sym
    ) OToken(string.concat(id, "-long"), string.concat(sym, "LONG")) {}

    function balanceOf(address owner) public view override returns (uint256) {
        int256 pos = pair.netPosition(owner);
        return pos > 0 ? uint256(pos) : 0;
    }
}

contract OShortToken is OToken {
    constructor(
        string memory id,
        string memory sym
    ) OToken(string.concat(id, "-short"), string.concat(sym, "SHORT")) {}

    function balanceOf(address owner) public view override returns (uint256) {
        int256 pos = pair.netPosition(owner);
        return pos < 0 ? uint256(-pos) : 0;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// OPair – options pair contract
//
// Sellers deposit collateral and write options; buyers pay a premium and
// acquire the right to exercise before expiry.
//
// Net position per address (netPosition):
//   > 0  long  – holds exercise rights (mirrored by buyToken balance)
//   < 0  short – has collateral obligation (mirrored by sellToken balance)
//   = 0  flat
//
// When a trade would cross zero (e.g. a long seller or a short buyer), the
// opposing position is netted first before any new collateral is required.
// ─────────────────────────────────────────────────────────────────────────────

contract OPair is IOPair, ReentrancyGuardTransient, SigVerifier {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------
    address public immutable factory;
    IERC20 public immutable riskToken;
    IERC20 public immutable cashToken;
    uint256 public immutable strike; // price of riskToken in cashToken, 18-decimal fixed point
    bool public immutable isCall;
    uint128 public immutable minDepositSize;
    IERC20 public immutable depositToken; // isCall ? riskToken : cashToken
    IERC20 public immutable swapToken; // isCall ? cashToken : riskToken

    // -------------------------------------------------------------------------
    // Mutable state
    // -------------------------------------------------------------------------
    uint256 public expiry; // In extreme circumstances, the admin may extend expiry.
    uint256 public depositDeadline; // No new positions after this timestamp.
    uint256 public exerciseEarliest; // No exercise before this timestamp.

    // All balances are tracked as risk token balances. Before withdrawing cash tokens they must
    // be converted via strike.

    // Authoritative position tracking: positive = long, negative = short (risk-token units).
    // buyToken.balanceOf(u) == max(0, netPosition[u])
    // sellToken.balanceOf(u) == max(0, -netPosition[u])
    mapping(address => int256) public netPosition;

    // Pre-settled amounts from netting – claimable any time via claimSettled().
    mapping(address => uint256) public settledDepositToken;
    mapping(address => uint256) public settledSwapToken;

    // Pool totals (risk-token units unless noted)
    uint256 public totalSold; // total active short positions
    uint256 public totalExercised; // exercised so far
    // totalFees is the only exception to being tracked via risk token. Since it can't be converted via strike.
    uint256 public totalFees; // accumulated cashToken fees.

    // -------------------------------------------------------------------------
    // EIP-712 (QUOTE_TYPEHASH inherited from SigVerifier)
    // -------------------------------------------------------------------------
    /// @notice EIP-712 domain separator cached at construction for gas efficiency.
    ///         OPair is the verifyingContract. Used by signers and Bulletin to build digests.
    bytes32 public immutable DOMAIN_SEPARATOR;

    /// @notice Per-signer nonce. Incremented on each successful sell/buy that
    ///         consumes a quote signed by that signer.
    mapping(address => uint256) public nonces;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------
    uint256 public constant FEE_BPS = 750; // 7.5%
    uint256 public constant BPS = 10_000;

    // By default deposits stop 3 hours before expiry.
    uint256 public constant DEFAULT_DEPOSIT_DEADLINE = 3 hours;
    // By default, exercises can only start 4 hours after creation as a precaution to give time for correcting any improperly configured vaults.
    uint256 public constant DEFAULT_EXERCISE_BUFFER = 4 hours;

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------
    modifier onlyFactoryOwner() {
        if (!IAccessControl(factory).hasRole(0x00, msg.sender))
            revert NotFactoryOwner();
        _;
    }

    modifier beforeExpiry() {
        if (block.timestamp >= expiry) revert Expired();
        _;
    }

    modifier beforeDepositDeadline() {
        if (block.timestamp >= depositDeadline) revert DepositWindowClosed();
        _;
    }

    modifier afterExpiry() {
        if (block.timestamp < expiry) revert NotExpired();
        _;
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------
    constructor(
        address _riskToken,
        address _cashToken,
        uint128 _strike,
        uint256 _expiry,
        bool _isCall,
        uint128 _minDepositSize,
        string memory identifier,
        string memory symbol
    ) {
        factory = msg.sender;
        riskToken = IERC20(_riskToken);
        cashToken = IERC20(_cashToken);
        strike = _strike;
        expiry = _expiry;
        isCall = _isCall;
        minDepositSize = _minDepositSize;
        depositToken = _isCall ? IERC20(_riskToken) : IERC20(_cashToken);
        swapToken = _isCall ? IERC20(_cashToken) : IERC20(_riskToken);
        depositDeadline = _expiry - DEFAULT_DEPOSIT_DEADLINE;
        // It'd be strange to create a contract that had a small deposit window.
        require(block.timestamp + 1 hours < depositDeadline, ExpiryTooSoon());
        exerciseEarliest = block.timestamp + DEFAULT_EXERCISE_BUFFER;
        DOMAIN_SEPARATOR = _domainSeparatorFor(address(this));

        address long = address(new OLongToken(identifier, symbol));
        address short = address(new OShortToken(identifier, symbol));
        emit NewOPair(
            factory,
            _riskToken,
            _cashToken,
            _strike,
            _expiry,
            _isCall,
            long,
            short
        );
    }

    // -------------------------------------------------------------------------
    // Nonce management
    // -------------------------------------------------------------------------

    /// @notice Advance the caller's own nonce by `amount`, invalidating all prior
    ///         signatures for that nonce range. Self-service: only msg.sender's nonce
    ///         is affected.
    function bumpNonce(uint256 amount) external {
        uint256 newNonce = nonces[msg.sender] += amount;
        emit NonceBumped(msg.sender, newNonce);
    }

    // -------------------------------------------------------------------------
    // Sell
    // -------------------------------------------------------------------------
    // msg.sender sells and collateralizes; the RFQ buyer (buyerSigner) pays premium via their Funder.
    //
    // Netting (seller): if seller is currently long, existing buy positions are
    // burned first, reducing the collateral deposit required for this trade.
    //
    // Netting (buyer): if buyer is currently short, existing sell positions are
    // settled (unexercised-first) and their settled collateral is stored for
    // retrieval via claimSettled().
    function sell(
        address funderAddr,
        address buyerSigner,
        uint128 size,
        uint128 fill,
        uint128 premiumPerUnit,
        uint256 validTillTimestamp,
        bytes calldata signature
    ) external beforeDepositDeadline nonReentrant {
        if (validTillTimestamp < block.timestamp) revert QuoteExpired();
        if (fill == 0) revert ZeroSize();
        if (fill > size) revert FillExceedsQuotedSize();
        if (fill < minDepositSize) revert BelowMinDeposit();

        address seller = msg.sender;

        // Verify and consume the buyer's quote signature (committed to the max size).
        _verifyAndConsumeQuote(
            funderAddr,
            buyerSigner,
            int256(uint256(size)),
            premiumPerUnit,
            validTillTimestamp,
            signature
        );

        // Seller acquires a short position for `fill` units.
        uint256 physicalSize = _addShort(seller, fill);
        if (physicalSize > 0) {
            depositToken.safeTransferFrom(
                seller,
                address(this),
                _depositAmount(physicalSize)
            );
            totalSold += physicalSize;
        }

        // Buyer acquires a long position for `fill` units.
        uint256 buyerNetted = _addLong(buyerSigner, fill);

        // Pull premium from buyer's Funder. Total = premiumPerUnit * fill / 1e18.
        uint256 totalPremium = (uint256(premiumPerUnit) * uint256(fill)) / 1e18;
        uint256 cashBefore = cashToken.balanceOf(address(this));
        IFunderBase(funderAddr).requestFunds(
            buyerSigner,
            address(cashToken),
            totalPremium
        );
        if (cashToken.balanceOf(address(this)) - cashBefore != totalPremium)
            revert PremiumUnderpaid();

        uint256 fee = (totalPremium * FEE_BPS) / BPS;
        totalFees += fee;
        cashToken.safeTransfer(seller, totalPremium - fee);

        emit Sold(
            seller,
            buyerSigner,
            fill,
            uint128(totalPremium),
            fill - physicalSize,
            buyerNetted
        );
    }

    // -------------------------------------------------------------------------
    // Buy
    // -------------------------------------------------------------------------
    // msg.sender buys; the RFQ seller (sellerSigner) provides collateral via their Funder.
    //
    // Netting (buyer): if buyer is currently short, existing sell positions are settled first.
    // Netting (seller): if seller is currently long, existing buy positions offset collateral.
    function buy(
        address sellerFunderAddr,
        address sellerSigner,
        uint128 size,
        uint128 fill,
        uint128 premiumPerUnit,
        uint256 validTillTimestamp,
        bytes calldata signature
    ) external beforeDepositDeadline nonReentrant {
        if (validTillTimestamp < block.timestamp) revert QuoteExpired();
        if (fill == 0) revert ZeroSize();
        if (fill > size) revert FillExceedsQuotedSize();
        if (fill < minDepositSize) revert BelowMinDeposit();

        address buyer = msg.sender;

        // Verify and consume the seller's quote signature (committed to the max size).
        _verifyAndConsumeQuote(
            sellerFunderAddr,
            sellerSigner,
            -int256(uint256(size)),
            premiumPerUnit,
            validTillTimestamp,
            signature
        );

        // Buyer acquires a long position for `fill` units.
        uint256 buyerNetted = _addLong(buyer, fill);

        // Seller acquires a short position for `fill` units.
        uint256 physicalSize = _addShort(sellerSigner, fill);
        uint256 acquireAmt = _depositAmount(physicalSize); // 0 when fully netted
        uint256 depositBefore = depositToken.balanceOf(address(this));
        IFunderBase(sellerFunderAddr).requestFunds(
            sellerSigner,
            address(depositToken),
            acquireAmt
        );
        if (depositToken.balanceOf(address(this)) - depositBefore != acquireAmt)
            revert CollateralUnderpaid();
        if (physicalSize > 0) totalSold += physicalSize;

        // Buyer pays premium. Total = premiumPerUnit * fill / 1e18.
        uint256 totalPremium = (uint256(premiumPerUnit) * uint256(fill)) / 1e18;
        cashToken.safeTransferFrom(buyer, address(this), totalPremium);
        uint256 fee = (totalPremium * FEE_BPS) / BPS;
        totalFees += fee;
        uint256 earnings = totalPremium - fee;
        cashToken.forceApprove(sellerFunderAddr, earnings);
        IFunderBase(sellerFunderAddr).deposit(
            sellerSigner,
            address(cashToken),
            earnings
        );
        // Custom funders for whatever reason might not use the full approval.
        cashToken.forceApprove(sellerFunderAddr, 0);

        emit Bought(
            buyer,
            sellerSigner,
            fill,
            uint128(totalPremium),
            buyerNetted,
            fill - physicalSize
        );
    }

    // -------------------------------------------------------------------------
    // Exercise
    // -------------------------------------------------------------------------
    // Buyer exercises before expiry via a callback contract.
    // For calls: vault sends riskToken, callback returns cashToken at strike price.
    // For puts:  vault sends cashToken, callback returns riskToken at strike price.
    function exercise(
        uint128 size,
        address callbackContract,
        bytes calldata data
    ) external beforeExpiry nonReentrant {
        if (block.timestamp < exerciseEarliest) revert ExerciseTooEarly();
        if (size == 0) revert ZeroSize();
        if (netPosition[msg.sender] < int256(uint256(size)))
            revert InsufficientLongPosition();

        netPosition[msg.sender] -= int256(uint256(size));
        totalExercised += size;

        uint256 depositAmt = size;
        uint256 swapAmt = size;
        if (isCall) {
            swapAmt = _cashAmount(size, true);
        } else {
            depositAmt = _cashAmount(size, false);
        }

        depositToken.safeTransfer(callbackContract, depositAmt);

        uint256 balBefore = swapToken.balanceOf(address(this));
        IExerciseCallback(callbackContract).onExercise(
            address(depositToken),
            address(swapToken),
            depositAmt,
            swapAmt,
            data
        );
        if (swapToken.balanceOf(address(this)) - balBefore != swapAmt)
            revert CallbackUnderpaid();

        emit Exercised(msg.sender, size);
    }

    // -------------------------------------------------------------------------
    // Claim
    // -------------------------------------------------------------------------
    // After expiry: sellers burn `size` sellToken and receive their proportional
    // share of the pool.
    //
    // preferExercised=true:  take from exercised pool first (swap tokens), then unexercised.
    // preferExercised=false: take from unexercised pool first (deposit tokens), then exercised.
    //
    // Pre-settled amounts from netting are NOT included here; use claimSettled().
    function claim(uint128 size, bool preferExercised) external afterExpiry {
        if (size == 0) revert ZeroSize();
        if (netPosition[msg.sender] > -int256(uint256(size)))
            revert InsufficientShortPosition();

        netPosition[msg.sender] += int256(uint256(size));

        uint256 totalUnexercised = totalSold - totalExercised;
        uint256 fromExercised;
        uint256 fromUnexercised;

        if (preferExercised) {
            fromExercised = size > totalExercised ? totalExercised : size;
            fromUnexercised = size - fromExercised;
        } else {
            fromUnexercised = size > totalUnexercised ? totalUnexercised : size;
            fromExercised = size - fromUnexercised;
        }

        totalExercised -= fromExercised;
        totalSold -= size;

        if (isCall) {
            fromExercised = _cashAmount(fromExercised, false);
        } else {
            fromUnexercised = _cashAmount(fromUnexercised, false);
        }

        if (fromUnexercised > 0)
            depositToken.safeTransfer(msg.sender, fromUnexercised);
        if (fromExercised > 0)
            swapToken.safeTransfer(msg.sender, fromExercised);

        emit Claimed(msg.sender, fromUnexercised, fromExercised);
    }

    // -------------------------------------------------------------------------
    // Claim settled
    // -------------------------------------------------------------------------
    // Claimable any time – returns collateral pre-settled from mid-trade netting.
    function claimSettled() external {
        uint256 depAmt = settledDepositToken[msg.sender];
        uint256 swapAmt = settledSwapToken[msg.sender];
        if (depAmt == 0 && swapAmt == 0) revert NothingToSettle();

        settledDepositToken[msg.sender] = 0;
        settledSwapToken[msg.sender] = 0;

        if (isCall) {
            swapAmt = _cashAmount(swapAmt, false);
        } else {
            depAmt = _cashAmount(depAmt, false);
        }
        if (depAmt > 0) depositToken.safeTransfer(msg.sender, depAmt);
        if (swapAmt > 0) swapToken.safeTransfer(msg.sender, swapAmt);

        emit SettledClaimed(msg.sender, depAmt, swapAmt);
    }

    // -------------------------------------------------------------------------
    // Extend expiry
    // -------------------------------------------------------------------------
    function extendExpiry(uint256 newExpiry) external onlyFactoryOwner {
        if (newExpiry <= expiry) revert NewExpiryNotLater();
        expiry = newExpiry;
        emit ExpiryExtended(newExpiry);
    }

    function setDepositDeadline(uint256 newDeadline) external onlyFactoryOwner {
        if (newDeadline >= expiry) revert DepositDeadlinePastExpiry();
        depositDeadline = newDeadline;
        emit DepositDeadlineUpdated(newDeadline);
    }

    function setExerciseEarliest(
        uint256 newEarliest
    ) external onlyFactoryOwner {
        if (newEarliest > expiry - 3 hours) revert ExerciseWindowTooNarrow();
        exerciseEarliest = newEarliest;
        emit ExerciseEarliestUpdated(newEarliest);
    }

    // -------------------------------------------------------------------------
    // Claim fees
    // -------------------------------------------------------------------------
    function claimFees() external onlyFactoryOwner afterExpiry {
        uint256 fees = totalFees;
        totalFees = 0;
        cashToken.safeTransfer(msg.sender, fees);
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// @dev Verifies an EIP-712 Quote signature against the signer's current nonce,
    ///      then increments the nonce. Reverts with InvalidSignature on mismatch.
    ///      The `funder` address is part of the signed struct, preventing fake-funder attacks.
    function _verifyAndConsumeQuote(
        address funder,
        address signer,
        int256 size,
        uint256 premiumPerUnit,
        uint256 validTillTimestamp,
        bytes calldata signature
    ) internal {
        uint256 currentNonce = nonces[signer];
        if (
            _recoverSigner(
                funder,
                address(this),
                size,
                premiumPerUnit,
                validTillTimestamp,
                currentNonce,
                signature
            ) != signer
        ) revert InvalidSignature();
        nonces[signer] = currentNonce + 1;
    }

    // Add `size` units of long position to `user`.
    // If user is currently short, their opposing short is netted first:
    //   - sellToken burned for the netted amount
    //   - settled collateral stored for claimSettled()
    //   - totalSold and totalExercised decremented
    // Returns the number of units that were netted from an existing short.
    function _addLong(
        address user,
        uint128 size
    ) internal returns (uint256 netted) {
        int256 pos = netPosition[user];
        if (pos < 0) {
            uint256 shortSize = uint256(-pos);
            netted = shortSize >= size ? size : shortSize;
            _settleNetted(user, netted);
        }
        netPosition[user] = pos + int256(uint256(size));
    }

    // Add `size` units of short position to `user`.
    // If user is currently long, their opposing long is netted first:
    //   - buyToken burned for the netted amount (no collateral required for that portion)
    // Returns the number of units requiring new physical collateral deposit.
    // The calling functions add to totals based on the additional short.
    function _addShort(
        address user,
        uint128 size
    ) internal returns (uint256 physicalSize) {
        int256 pos = netPosition[user];
        uint256 netted;
        if (pos > 0) {
            uint256 longSize = uint256(pos);
            netted = longSize >= size ? size : longSize;
        }
        // This is how much we'll add to the total sold.
        physicalSize = size - netted;
        netPosition[user] = pos - int256(uint256(size));
    }

    /// Settle `toNet` units of `account`'s existing short position.
    /// @dev Always takes from the unexercised pool first, then the exercised pool.
    /// @dev only before expiry code can reach this which is why the preference is unexercised.
    function _settleNetted(address account, uint256 toNet) internal {
        uint256 totalUnexercised = totalSold - totalExercised;
        uint256 fromUnexercised = toNet > totalUnexercised
            ? totalUnexercised
            : toNet;
        uint256 fromExercised = toNet - fromUnexercised;

        // Longs clear previously sold contracts.
        totalExercised -= fromExercised;
        totalSold -= toNet;

        settledDepositToken[account] += fromUnexercised;
        settledSwapToken[account] += fromExercised;

        emit Netted(account, fromUnexercised, fromExercised);
    }

    function _cashAmount(
        uint256 riskSize,
        bool roundUp
    ) internal view returns (uint256 amt) {
        uint256 s = strike;
        uint256 d = 1e18;
        assembly ("memory-safe") {
            let m := mul(riskSize, s)
            amt := add(div(m, d), and(roundUp, gt(mod(m, d), 0)))
        }
    }

    function _depositAmount(uint256 riskSize) internal view returns (uint256) {
        // Always round up on deposit.
        return isCall ? riskSize : _cashAmount(riskSize, true);
    }
}
