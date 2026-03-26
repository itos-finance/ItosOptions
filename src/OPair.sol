// SPDX-License-Identifier: BUSL-1.1
// Change Date: 2030-03-17  (license converts to GPL-2.0-or-later on this date)
pragma solidity ^0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IFunderBase} from "./interfaces/IFunderBase.sol";
import {IExerciseCallback} from "./interfaces/IExerciseCallback.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Display ERC20 position tokens – non-transferable, mint/burn by OPair only.
// Balances mirror the authoritative netPosition mapping in OPair.
// ─────────────────────────────────────────────────────────────────────────────

abstract contract OToken is IERC20 {
    OPair public immutable pair;

    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    error OnlyPair();
    error NonTransferable();

    constructor(string memory id, string memory sym) {
        pair = OPair(msg.sender);
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

contract OPair is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------
    error NotFactoryOwner();
    error Expired();
    error NotExpired();
    error QuoteExpired();
    error ZeroSize();
    error BelowMinDeposit();
    error InsufficientLongPosition();
    error InsufficientShortPosition();
    error NothingToSettle();
    error PremiumUnderpaid();
    error CollateralUnderpaid();
    error CallbackUnderpaid();
    error NewExpiryNotLater();
    error DepositWindowClosed();
    error ExerciseTooEarly();

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------
    event Sold(
        address indexed seller,
        address indexed buyer,
        uint128 size,
        uint128 premium,
        uint256 sellerNetted,
        uint256 buyerNetted
    );
    event Bought(
        address indexed buyer,
        address indexed seller,
        uint128 size,
        uint128 premium,
        uint256 buyerNetted,
        uint256 sellerNetted
    );
    event Exercised(address indexed buyer, uint128 size);
    event Claimed(address indexed seller, uint256 depositOut, uint256 swapOut);
    event SettledClaimed(
        address indexed account,
        uint256 depositOut,
        uint256 swapOut
    );
    event Netted(
        address indexed account,
        uint256 depositSettled,
        uint256 swapSettled
    );
    event ExpiryExtended(uint256 newExpiry);
    event DepositDeadlineUpdated(uint256 newDeadline);
    event ExerciseEarliestUpdated(uint256 newEarliest);

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
    // Constants
    // -------------------------------------------------------------------------
    uint256 public constant FEE_BPS = 750; // 7.5%
    uint256 public constant BPS = 10_000;

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------
    modifier onlyFactoryOwner() {
        if (msg.sender != Ownable(factory).owner()) revert NotFactoryOwner();
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
        depositDeadline = _expiry - 24 hours;
        exerciseEarliest = block.timestamp + 4 hours;

        new OLongToken(identifier, symbol);
        new OShortToken(identifier, symbol);
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
        uint128 premium,
        uint256 validTillTimestamp,
        bytes calldata signature
    ) external beforeDepositDeadline nonReentrant {
        if (validTillTimestamp < block.timestamp) revert QuoteExpired();
        if (size == 0) revert ZeroSize();
        if (size < minDepositSize) revert BelowMinDeposit();

        address seller = msg.sender;

        // Seller acquires a short position; returns units that required new collateral.
        uint256 physicalSize = _addShort(seller, size);
        if (physicalSize > 0) {
            depositToken.safeTransferFrom(
                seller,
                address(this),
                _depositAmount(physicalSize)
            );
            totalSold += physicalSize;
        }

        // Buyer acquires a long position; returns units netted from an existing short.
        uint256 buyerNetted = _addLong(buyerSigner, size);

        // Pull premium from buyer's Funder.
        uint256 cashBefore = cashToken.balanceOf(address(this));
        IFunderBase(funderAddr).requestFunds(
            buyerSigner,
            address(cashToken),
            premium,
            int256(uint256(size)), // positive = buy intent
            premium, // acquireAmount == amount: premium is always paid in full
            validTillTimestamp,
            signature
        );
        if (cashToken.balanceOf(address(this)) - cashBefore != premium)
            revert PremiumUnderpaid();

        uint256 fee = (uint256(premium) * FEE_BPS) / BPS;
        totalFees += fee;
        cashToken.safeTransfer(seller, premium - fee);

        emit Sold(
            seller,
            buyerSigner,
            size,
            premium,
            size - physicalSize,
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
        uint128 premium,
        uint256 validTillTimestamp,
        bytes calldata signature
    ) external beforeDepositDeadline nonReentrant {
        if (validTillTimestamp < block.timestamp) revert QuoteExpired();
        if (size == 0) revert ZeroSize();
        if (size < minDepositSize) revert BelowMinDeposit();

        address buyer = msg.sender;

        // Buyer acquires a long position.
        uint256 buyerNetted = _addLong(buyer, size);

        // Seller acquires a short position; returns units requiring new collateral.
        uint256 physicalSize = _addShort(sellerSigner, size);
        uint256 acquireAmt = _depositAmount(physicalSize); // 0 when fully netted
        uint256 depositBefore = depositToken.balanceOf(address(this));
        IFunderBase(sellerFunderAddr).requestFunds(
            sellerSigner,
            address(depositToken),
            premium,
            -int256(uint256(size)), // negative = sell intent
            acquireAmt, // actual collateral transfer (0 when fully netted)
            validTillTimestamp,
            signature
        );
        if (depositToken.balanceOf(address(this)) - depositBefore != acquireAmt)
            revert CollateralUnderpaid();
        if (physicalSize > 0) totalSold += physicalSize;

        // Buyer pays premium directly.
        cashToken.safeTransferFrom(buyer, address(this), premium);
        uint256 fee = (uint256(premium) * FEE_BPS) / BPS;
        totalFees += fee;
        uint256 earnings = premium - fee;
        cashToken.forceApprove(sellerFunderAddr, earnings);
        IFunderBase(sellerFunderAddr).deposit(
            sellerSigner,
            address(cashToken),
            earnings
        );

        emit Bought(
            buyer,
            sellerSigner,
            size,
            premium,
            buyerNetted,
            size - physicalSize
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
        depositDeadline = newDeadline;
        emit DepositDeadlineUpdated(newDeadline);
    }

    function setExerciseEarliest(uint256 newEarliest) external onlyFactoryOwner {
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
