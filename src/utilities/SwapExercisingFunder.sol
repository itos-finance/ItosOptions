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

// -------------------------------------------------------------------------
// Minimal Uniswap V3 interface surface. Same rationale as V4: defined inline
// so this utility has no V3 dependency.
// -------------------------------------------------------------------------
interface IUniswapV3Factory {
    function getPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external view returns (address pool);
}

interface IUniswapV3Pool {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
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
    error NotV3Pool();
    error UnexpectedDelta();
    error InsufficientOutput();
    error PoolNotFound();

    /// @notice Selector returned by signature verification, telling the
    ///         dispatcher which AMM to route the swap through.
    enum SwapKind {
        V4,
        V3
    }

    /// @notice Sentinel placed in `swapData.hooks` to signal that the swap
    ///         should be executed against Uniswap V3 instead of V4. V3 has
    ///         no hooks concept, so this field is otherwise unused on the V3
    ///         path — including the V3 sentinel route's `tickSpacing` value
    ///         (V3 derives spacing from the fee tier).
    address public constant V3_HOOK_SENTINEL =
        address(0x0000000000000000000000000000000000003333);

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
    IUniswapV3Factory public immutable V3_FACTORY;

    constructor(
        address _factory,
        address _poolManager,
        address _v3Factory
    ) ExercisingFunder(_factory) {
        POOL_MANAGER = IPoolManager(_poolManager);
        V3_FACTORY = IUniswapV3Factory(_v3Factory);
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

        SwapKind kind = _verifyAndConsumeSwapSignature(
            msg.sender,
            signer,
            swapData,
            signature
        );

        if (swapData.amountIn != 0) {
            if (kind == SwapKind.V3) {
                _executeSwapV3(tokenGiven, tokenExpected, swapData);
            } else {
                _executeSwapV4(tokenGiven, tokenExpected, swapData);
            }
        }

        IERC20(tokenExpected).safeTransfer(msg.sender, amountExpected);
    }

    /// @dev Verifies `signer` holds SIGNER_ROLE and that `signature` is a
    ///      valid EIP-712 `ExerciseSwap` signature by `signer` over the
    ///      vault's current nonce. Advances the nonce on success and returns
    ///      the swap routing kind, decided by the value of `swapData.hooks`:
    ///      `V3_HOOK_SENTINEL` selects Uniswap V3, anything else is treated
    ///      as a V4 hook address.
    function _verifyAndConsumeSwapSignature(
        address vault,
        address signer,
        SwapData memory swapData,
        bytes memory signature
    ) internal returns (SwapKind kind) {
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

        kind = swapData.hooks == V3_HOOK_SENTINEL
            ? SwapKind.V3
            : SwapKind.V4;
    }

    /// @dev Enters the V4 PoolManager unlock lock and swaps `swapData.amountIn`
    ///      of `tokenGiven` for `tokenExpected`. After return, that amount of
    ///      `tokenGiven` has left the pool and the swap output has arrived.
    function _executeSwapV4(
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

    /// @dev Looks up the V3 pool by `(tokenGiven, tokenExpected, fee)` and
    ///      executes an exact-input swap of `swapData.amountIn`. The pool
    ///      pulls `tokenGiven` via `uniswapV3SwapCallback` and transfers the
    ///      output to this contract. `swapData.tickSpacing` is unused on the
    ///      V3 path (V3 derives spacing from the fee tier).
    function _executeSwapV3(
        address tokenGiven,
        address tokenExpected,
        SwapData memory swapData
    ) internal {
        address pool = V3_FACTORY.getPool(
            tokenGiven,
            tokenExpected,
            swapData.fee
        );
        if (pool == address(0)) revert PoolNotFound();

        bool zeroForOne = tokenGiven < tokenExpected;
        bytes memory callbackData = abi.encode(
            tokenGiven,
            tokenExpected,
            swapData.fee
        );

        // V3 exact-input uses a *positive* amountSpecified (opposite of V4).
        (int256 amount0, int256 amount1) = IUniswapV3Pool(pool).swap(
            address(this),
            zeroForOne,
            int256(swapData.amountIn),
            zeroForOne ? MIN_SQRT_PRICE + 1 : MAX_SQRT_PRICE - 1,
            callbackData
        );

        // Output is the negative side of the delta — it's what the pool sent
        // us. amountIn is paid via the callback, not checked here.
        int256 outDelta = zeroForOne ? amount1 : amount0;
        if (outDelta >= 0) revert UnexpectedDelta();
        uint256 amountOut = uint256(-outDelta);
        if (amountOut < swapData.amountOutMin) revert InsufficientOutput();
    }

    /// @notice Uniswap V3 swap callback. Pays the pool whichever side of the
    ///         delta is positive. The callback is authenticated by recomputing
    ///         the expected pool address from the factory — only the legit
    ///         `(tokenIn, tokenOut, fee)` pool can be the caller, because V3
    ///         only invokes this callback on the contract that called
    ///         `pool.swap()` (i.e. this contract during `_executeSwapV3`).
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        (address tokenIn, address tokenOut, uint24 fee) = abi.decode(
            data,
            (address, address, uint24)
        );
        address expectedPool = V3_FACTORY.getPool(tokenIn, tokenOut, fee);
        if (msg.sender != expectedPool) revert NotV3Pool();

        bool zeroForOne = tokenIn < tokenOut;
        int256 owedDelta = zeroForOne ? amount0Delta : amount1Delta;
        if (owedDelta <= 0) revert UnexpectedDelta();
        IERC20(tokenIn).safeTransfer(msg.sender, uint256(owedDelta));
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
        // Bind the pool's input draw to the signed amount. Without this, a
        // hook with BEFORE_SWAP_RETURNS_DELTA / AFTER_SWAP_RETURNS_DELTA could
        // inflate the input delta and pull more `tokenGiven` from the funder
        // than the signer authorised.
        if (amountIn != swapData.amountIn) revert UnexpectedDelta();
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
