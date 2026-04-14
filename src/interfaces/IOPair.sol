// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IOPair
/// @notice External interface for OPair option vaults.
interface IOPair {
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
    error InsufficientExercisedPosition();
    error NothingToSettle();
    error PremiumUnderpaid();
    error CollateralUnderpaid();
    error CallbackUnderpaid();
    error NewExpiryNotLater();
    error ExpiryExtensionTooFar();
    error DepositWindowClosed();
    error ExerciseTooEarly();
    error ExerciseWindowTooNarrow();
    error DepositDeadlinePastExpiry();
    error ExpiryTooSoon();
    error FillExceedsQuotedSize();
    error PartialFillNotAllowed();

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------
    event NewOPair(
        address indexed factory,
        address indexed riskToken,
        address indexed cashToken,
        uint128 strike,
        uint256 expiry,
        bool isCall,
        address longToken,
        address shortToken,
        address exercisedToken
    );
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
    event Unexercised(address indexed buyer, uint128 size);
    event Claimed(
        address indexed seller,
        address indexed recipient,
        uint256 depositOut,
        uint256 swapOut
    );
    event SettledClaimed(
        address indexed account,
        address indexed recipient,
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
    event NonceBumped(address indexed signer, uint256 channel, uint256 newNonce);
    event FeesClaimed(address indexed recipient, uint256 amount);

    // -------------------------------------------------------------------------
    // Immutables / constants
    // -------------------------------------------------------------------------
    function factory() external view returns (address);
    function riskToken() external view returns (IERC20);
    function cashToken() external view returns (IERC20);
    function strike() external view returns (uint256);
    function isCall() external view returns (bool);
    function minDepositSize() external view returns (uint128);
    function depositToken() external view returns (IERC20);
    function swapToken() external view returns (IERC20);
    function maxExpiry() external view returns (uint256);
    function FEE_BPS() external view returns (uint256);
    function BPS() external view returns (uint256);
    function MAX_EXPIRY_EXTENSION() external view returns (uint256);

    // -------------------------------------------------------------------------
    // Mutable state
    // -------------------------------------------------------------------------
    function expiry() external view returns (uint256);
    function depositDeadline() external view returns (uint256);
    function exerciseEarliest() external view returns (uint256);
    function netPosition(address account) external view returns (int256);
    function settledDepositToken(
        address account
    ) external view returns (uint256);
    function settledSwapToken(address account) external view returns (uint256);
    function exercised(address account) external view returns (uint256);
    function totalSold() external view returns (uint256);
    function totalExercised() external view returns (uint256);
    function totalFees() external view returns (uint256);
    function nonces(address signer, uint256 channel) external view returns (uint256);

    // -------------------------------------------------------------------------
    // Actions
    // -------------------------------------------------------------------------
    function bumpNonce(uint256 channel, uint256 amount) external;

    function sell(
        address funderAddr,
        address buyerSigner,
        uint128 size,
        uint128 fill,
        uint128 premiumPerUnit,
        uint256 validTillTimestamp,
        bool allowPartialFill,
        uint256 channel,
        bytes calldata signature
    ) external;

    function buy(
        address sellerFunderAddr,
        address sellerSigner,
        uint128 size,
        uint128 fill,
        uint128 premiumPerUnit,
        uint256 validTillTimestamp,
        bool allowPartialFill,
        uint256 channel,
        bytes calldata signature
    ) external;

    function take(
        address funderAddr,
        address signer,
        int128 size,
        uint128 fill,
        uint128 premiumPerUnit,
        uint256 validTillTimestamp,
        bool allowPartialFill,
        uint256 channel,
        bytes calldata signature
    ) external;

    function exercise(
        uint128 size,
        address callbackContract,
        bytes calldata data
    ) external;

    function unexercise(
        uint128 size,
        address callbackContract,
        bytes calldata data
    ) external;

    function claim(
        address recipient,
        uint128 size,
        bool preferExercised
    ) external;

    function claimSettled(address recipient) external;

    // -------------------------------------------------------------------------
    // Admin (factory owner)
    // -------------------------------------------------------------------------
    function extendExpiry(uint256 newExpiry) external;
    function setDepositDeadline(uint256 newDeadline) external;
    function setExerciseEarliest(uint256 newEarliest) external;
    function claimFees(address recipient) external;
}
