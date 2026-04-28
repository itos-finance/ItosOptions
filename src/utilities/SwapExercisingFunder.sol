// SPDX-License-Identifier: BUSL-1.1
// Change Date: 2030-03-17  (license converts to GPL-2.0-or-later on this date)
pragma solidity ^0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ExercisingFunder} from "./ExercisingFunder.sol";

// -------------------------------------------------------------------------
// Minimal Uniswap V4 interface surface. Defined inline so this utility has
// no V4 dependency. Upstream definitions live in @uniswap/v4-core.
// -------------------------------------------------------------------------
type Currency is address;

struct PoolKey {
    Currency currency0;
    Currency currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

/// @dev Packed: amount0 = upper 128 bits, amount1 = lower 128 bits.
type BalanceDelta is int256;

/// @dev V4 TickMath sqrt-price bounds. Using these as the swap's
///      `sqrtPriceLimitX96` means the price limit never binds, so the swap
///      consumes the full `amountIn` (or reverts). Slippage is enforced
///      separately via `amountOutMin`.
uint160 constant MIN_SQRT_PRICE = 4295128739;
uint160 constant MAX_SQRT_PRICE =
    1461446703485210103287273052203988822378723970342;

interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external returns (BalanceDelta);
    function sync(Currency currency) external;
    function settle() external payable returns (uint256 paid);
    function take(Currency currency, address to, uint256 amount) external;
}

/// @title SwapExercisingFunder
/// @notice ExercisingFunder variant that optionally swaps `tokenGiven` into
///         `tokenExpected` through a Uniswap V4 pool before paying the vault.
///         Useful when the market-maker does not hold enough `tokenExpected`
///         in the shared pool to cover an exercise.
///
///         Callback data layout:
///             abi.encode(
///                 address signer,
///                 SwapData swapData,    // V4 pool selector + input amount
///                 bytes signature       // EIP-712 ExerciseSwap sig
///             )
///
///         `swapData.amountIn == 0` skips the swap (pure pool payout, like
///         the parent `ExercisingFunder`). Any non-zero value triggers an
///         exact-input V4 swap of that many `tokenGiven` units, requiring
///         at least `swapData.amountOutMin` of `tokenExpected` back.
///
///         The signature binds the signer to (vault, nonce, swapData) —
///         otherwise an attacker could substitute their own pool selector
///         and drain the funder.
contract SwapExercisingFunder is ExercisingFunder {
    using SafeERC20 for IERC20;

    error NotPoolManager();
    error UnexpectedDelta();
    error InsufficientOutput();

    /// @notice Everything a signer must specify to route a V4 swap. The
    ///         input/output currencies are inferred from `tokenGiven` /
    ///         `tokenExpected` passed to the callback.
    /// @dev `amountIn == 0` signals "no swap" — the swap step is skipped
    ///      entirely and the funder pays from existing pool holdings.
    ///      `amountOutMin` is the slippage floor: the swap reverts if the
    ///      pool returns less.
    struct SwapData {
        uint256 amountIn;
        uint256 amountOutMin;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    /// @dev ExerciseSwap(address vault,uint256 nonce,uint256 amountIn,
    ///      uint256 amountOutMin,uint24 fee,int24 tickSpacing,address hooks)
    bytes32 public constant EXERCISE_SWAP_TYPEHASH =
        keccak256(
            "ExerciseSwap(address vault,uint256 nonce,uint256 amountIn,uint256 amountOutMin,uint24 fee,int24 tickSpacing,address hooks)"
        );

    IPoolManager public immutable POOL_MANAGER;

    constructor(
        address _factory,
        address _poolManager
    ) ExercisingFunder(_factory) {
        POOL_MANAGER = IPoolManager(_poolManager);
    }

    /// @inheritdoc ExercisingFunder
    function onExercise(
        address tokenGiven,
        address tokenExpected,
        uint256 /* amountGiven */,
        uint256 amountExpected,
        bytes calldata data
    ) external override onlyValidPair {
        (
            address signer,
            SwapData memory swapData,
            bytes memory signature
        ) = abi.decode(data, (address, SwapData, bytes));

        _verifyAndConsumeSwapSignature(msg.sender, signer, swapData, signature);

        if (swapData.amountIn != 0) {
            _executeSwap(tokenGiven, tokenExpected, swapData);
        }

        IERC20(tokenExpected).safeTransfer(msg.sender, amountExpected);
    }

    /// @dev Verifies `signer` holds SIGNER_ROLE and that `signature` is a
    ///      valid EIP-712 `ExerciseSwap` signature by `signer` over the
    ///      vault's current nonce. Advances the nonce on success.
    function _verifyAndConsumeSwapSignature(
        address vault,
        address signer,
        SwapData memory swapData,
        bytes memory signature
    ) internal {
        if (!hasRole(SIGNER_ROLE, signer))
            revert AccessControlUnauthorizedAccount(signer, SIGNER_ROLE);

        uint256 nonce = nonces[vault]++;
        bytes32 structHash = keccak256(
            abi.encode(
                EXERCISE_SWAP_TYPEHASH,
                vault,
                nonce,
                swapData.amountIn,
                swapData.amountOutMin,
                swapData.fee,
                swapData.tickSpacing,
                swapData.hooks
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", _domainSeparator(), structHash)
        );
        if (ECDSA.recover(digest, signature) != signer)
            revert InvalidSignature();
    }

    /// @dev Enters the V4 PoolManager unlock lock and swaps `swapData.amountIn`
    ///      of `tokenGiven` for `tokenExpected`. After return, that amount of
    ///      `tokenGiven` has left the pool and the swap output has arrived.
    function _executeSwap(
        address tokenGiven,
        address tokenExpected,
        SwapData memory swapData
    ) internal {
        bytes memory callbackData = abi.encode(
            tokenGiven,
            tokenExpected,
            swapData
        );
        POOL_MANAGER.unlock(callbackData);
    }

    /// @notice PoolManager unlock callback. Executes an exact-input swap of
    ///         `swapData.amountIn` tokenGiven → tokenExpected through the V4
    ///         pool described by `swapData`, settles the input, and takes the
    ///         output.
    function unlockCallback(
        bytes calldata data
    ) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();

        (
            address tokenGiven,
            address tokenExpected,
            SwapData memory swapData
        ) = abi.decode(data, (address, address, SwapData));

        bool zeroForOne = tokenGiven < tokenExpected;
        (Currency c0, Currency c1) = zeroForOne
            ? (Currency.wrap(tokenGiven), Currency.wrap(tokenExpected))
            : (Currency.wrap(tokenExpected), Currency.wrap(tokenGiven));

        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: swapData.fee,
            tickSpacing: swapData.tickSpacing,
            hooks: swapData.hooks
        });

        // Exact-input: V4's amountSpecified is negative for exact-input. The
        // sqrtPriceLimit is set to the relevant tick-math extreme so the limit
        // never binds — slippage is enforced via `amountOutMin` below.
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(swapData.amountIn),
            sqrtPriceLimitX96: zeroForOne
                ? MIN_SQRT_PRICE + 1
                : MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta = POOL_MANAGER.swap(key, params, "");
        int128 delta0 = int128(BalanceDelta.unwrap(delta) >> 128);
        int128 delta1 = int128(BalanceDelta.unwrap(delta));

        // From the swapper's perspective: negative delta on the input side
        // (we owe the pool), positive delta on the output side (pool owes us).
        int128 inDelta = zeroForOne ? delta0 : delta1;
        int128 outDelta = zeroForOne ? delta1 : delta0;
        if (inDelta >= 0 || outDelta <= 0) revert UnexpectedDelta();

        uint256 amountIn = uint256(uint128(-inDelta));
        uint256 amountOut = uint256(uint128(outDelta));
        if (amountOut < swapData.amountOutMin) revert InsufficientOutput();

        // Settle what we owe: sync → transfer → settle credits us the delta.
        POOL_MANAGER.sync(Currency.wrap(tokenGiven));
        IERC20(tokenGiven).safeTransfer(address(POOL_MANAGER), amountIn);
        POOL_MANAGER.settle();

        // Take what we're owed directly into this contract.
        POOL_MANAGER.take(
            Currency.wrap(tokenExpected),
            address(this),
            amountOut
        );

        return "";
    }
}
