// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {OPairFactory} from "../src/OPairFactory.sol";
import {OPair} from "../src/OPair.sol";
import {SwapExercisingFunder} from "../src/utilities/SwapExercisingFunder.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";

// =========================================================================
// Minimal V3 interface surface — kept inline so this test file stays in our
// ^0.8.34 compilation unit (v3-core is pinned to =0.7.6).
// =========================================================================
interface IV3Factory {
    function createPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external returns (address pool);
    function getPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external view returns (address pool);
}

interface IV3Pool {
    function initialize(uint160 sqrtPriceX96) external;
    function mint(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bytes calldata data
    ) external returns (uint256 amount0, uint256 amount1);
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

/// @dev Minimal V3 LP helper. Holds the position itself; pays mint debts from
///      a transient `payer` set during `addLiquidity`. Test-only — do not
///      copy into production: the callback only authenticates by storing the
///      caller, not by checking msg.sender against the legitimate pool.
contract V3LiquidityHelper {
    address private _payer;

    function addLiquidity(
        address pool,
        address token0,
        address token1,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external {
        _payer = msg.sender;
        IV3Pool(pool).mint(
            address(this),
            tickLower,
            tickUpper,
            liquidity,
            abi.encode(token0, token1)
        );
        _payer = address(0);
    }

    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external {
        (address token0, address token1) = abi.decode(
            data,
            (address, address)
        );
        address payer = _payer;
        if (amount0Owed > 0) {
            IERC20(token0).transferFrom(payer, msg.sender, amount0Owed);
        }
        if (amount1Owed > 0) {
            IERC20(token1).transferFrom(payer, msg.sender, amount1Owed);
        }
    }
}

/// @dev Minimal helper that adds liquidity to a v4 pool by routing through unlock.
///      The test contract approves the PoolManager directly; settlement transfers
///      tokens from the test contract.
contract LiquidityHelper is IUnlockCallback {
    IPoolManager public immutable manager;

    struct Data {
        PoolKey key;
        ModifyLiquidityParams params;
        address payer;
    }

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function addLiquidity(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity
    ) external {
        manager.unlock(
            abi.encode(
                Data({
                    key: key,
                    params: ModifyLiquidityParams({
                        tickLower: tickLower,
                        tickUpper: tickUpper,
                        liquidityDelta: int256(liquidity),
                        salt: bytes32(0)
                    }),
                    payer: msg.sender
                })
            )
        );
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        Data memory d = abi.decode(raw, (Data));
        (BalanceDelta delta, ) = manager.modifyLiquidity(d.key, d.params, "");
        int128 d0 = int128(BalanceDelta.unwrap(delta) >> 128);
        int128 d1 = int128(BalanceDelta.unwrap(delta));
        if (d0 < 0) _settle(d.key.currency0, d.payer, uint256(uint128(-d0)));
        if (d1 < 0) _settle(d.key.currency1, d.payer, uint256(uint128(-d1)));
        return "";
    }

    function _settle(Currency c, address payer, uint256 amount) internal {
        manager.sync(c);
        IERC20(Currency.unwrap(c)).transferFrom(
            payer,
            address(manager),
            amount
        );
        manager.settle();
    }
}

/// @notice End-to-end test: full RFQ option setup against test ERC20s wired
///         through a real Uniswap V4 pool, with SwapExercisingFunder acting as
///         the market maker's funding contract on exercise.
///
///         Both option tokens are 18-decimal mocks and the strike is 1e18, so a
///         call-option exercise of `size` consumes `size` riskToken from the
///         vault and demands `size` cashToken back. A 1:1 V4 pool (with a
///         small fee) makes the swap math easy to reason about.
contract SwapExercisingFunderTest is Test {
    // --- Actors ---
    address public admin = makeAddr("admin");
    address public seller = makeAddr("seller");
    address public buyer = makeAddr("buyer");
    uint256 public mmKey = 0xA11CE;
    address public mm = vm.addr(0xA11CE);

    // --- Tokens (both 18-dec, freshly minted per test) ---
    MockERC20 public riskToken;
    MockERC20 public cashToken;

    // --- Core contracts ---
    OPairFactory public factory;
    OPair public pair;
    SwapExercisingFunder public swapFunder;

    // --- Uniswap V4 ---
    IPoolManager public poolManager;
    LiquidityHelper public lpHelper;
    PoolKey public poolKey;

    // --- Uniswap V3 ---
    IV3Factory public v3Factory;
    IV3Pool public v3Pool;
    V3LiquidityHelper public v3Lp;

    // --- Pool config ---
    uint24 constant POOL_FEE = 100; // 0.01%
    int24 constant TICK_SPACING = 1;
    int24 constant TICK_LOWER = -10000;
    int24 constant TICK_UPPER = 10000;
    uint24 constant V3_FEE = 500; // 0.05%, default-enabled tickSpacing=10
    int24 constant V3_TICK_SPACING = 10;
    int24 constant V3_TICK_LOWER = -887220;
    int24 constant V3_TICK_UPPER = 887220;
    uint128 constant V3_LIQUIDITY = 1e22;
    address constant V3_HOOK_SENTINEL =
        address(0x0000000000000000000000000000000000003333);
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 1<<96
    uint256 constant POOL_LIQUIDITY = 1e24;

    // --- Option config ---
    uint128 constant STRIKE = 1e18; // 1 risk = 1 cash
    uint128 constant MIN_DEPOSIT = 0.01e18;
    uint128 constant TRADE_SIZE = 1e18;
    uint128 constant PREMIUM = 0.05e18; // unused token amounts; just keeping it small

    // --- EIP-712 domain helpers (Quote: domain = OPair) ---
    bytes32 constant _DOMAIN_TYPEHASH =
        keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
    bytes32 constant _QUOTE_TYPEHASH =
        keccak256(
            "Quote(address funder,address vault,int256 size,uint256 premiumPerUnit,uint256 validTillTimestamp,bool allowPartialFill,uint256 channel,uint256 nonce)"
        );
    bytes32 constant _EXERCISE_SWAP_TYPEHASH =
        keccak256(
            "ExerciseSwap(address vault,uint256 nonce,uint256 amountIn,uint256 amountOutMin,uint24 fee,int24 tickSpacing,address hooks)"
        );

    function setUp() public {
        // Two 18-decimal mock tokens, sorted so we can build the pool key.
        MockERC20 a = new MockERC20("RiskTok", "RT", 18);
        MockERC20 b = new MockERC20("CashTok", "CT", 18);
        riskToken = a;
        cashToken = b;

        // RFQ factory + pair
        vm.prank(admin);
        factory = new OPairFactory();

        vm.prank(admin);
        pair = OPair(
            factory.createPair(
                address(riskToken),
                address(cashToken),
                STRIKE,
                block.timestamp + 7 days,
                true, // isCall
                MIN_DEPOSIT,
                "RT-CT-1",
                "RT"
            )
        );

        // V4 pool manager + helper. Deployed via deployCode so v4-core's
        // 0.8.26-pinned source lives in its own compilation unit.
        address pm = _deployPoolManager(admin);
        poolManager = IPoolManager(pm);
        lpHelper = new LiquidityHelper(poolManager);

        // Build pool key with sorted currencies
        (Currency c0, Currency c1) = address(riskToken) < address(cashToken)
            ? (
                Currency.wrap(address(riskToken)),
                Currency.wrap(address(cashToken))
            )
            : (
                Currency.wrap(address(cashToken)),
                Currency.wrap(address(riskToken))
            );

        poolKey = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        poolManager.initialize(poolKey, SQRT_PRICE_1_1);

        // Seed liquidity. Mint enough to cover both sides plus headroom.
        riskToken.mint(address(this), 1e26);
        cashToken.mint(address(this), 1e26);
        // The helper calls transferFrom on the payer's behalf during the unlock
        // callback, so it (not the manager) is the ERC-20 spender.
        riskToken.approve(address(lpHelper), type(uint256).max);
        cashToken.approve(address(lpHelper), type(uint256).max);
        lpHelper.addLiquidity(poolKey, TICK_LOWER, TICK_UPPER, POOL_LIQUIDITY);

        // V3 factory + pool. Same compilation-shim trick as V4 — solc 0.7.6
        // is in its own unit, only the bytecode lands here.
        v3Factory = IV3Factory(_deployV3Factory());
        (address t0, address t1) = address(riskToken) < address(cashToken)
            ? (address(riskToken), address(cashToken))
            : (address(cashToken), address(riskToken));
        address v3PoolAddr = v3Factory.createPool(t0, t1, V3_FEE);
        v3Pool = IV3Pool(v3PoolAddr);
        v3Pool.initialize(SQRT_PRICE_1_1);

        v3Lp = new V3LiquidityHelper();
        riskToken.approve(address(v3Lp), type(uint256).max);
        cashToken.approve(address(v3Lp), type(uint256).max);
        v3Lp.addLiquidity(
            v3PoolAddr,
            t0,
            t1,
            V3_TICK_LOWER,
            V3_TICK_UPPER,
            V3_LIQUIDITY
        );

        // Deploy the funder as mm — mm gets DEFAULT_ADMIN_ROLE + SIGNER_ROLE.
        vm.prank(mm);
        swapFunder = new SwapExercisingFunder(
            address(factory),
            address(poolManager),
            address(v3Factory)
        );
    }

    function _deployV3Factory() internal returns (address f) {
        string memory raw = vm.readFile(
            "out/UniswapV3Factory.sol/UniswapV3Factory.json"
        );
        bytes memory creation = vm.parseJsonBytes(raw, ".bytecode.object");
        assembly {
            f := create(0, add(creation, 0x20), mload(creation))
        }
        require(f != address(0), "v3 factory deploy failed");
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _signQuote(
        int256 size,
        uint128 premiumPerUnit,
        uint256 validTill,
        uint256 nonce
    ) internal view returns (bytes memory) {
        bytes32 domainSep = keccak256(
            abi.encode(
                _DOMAIN_TYPEHASH,
                keccak256("OPair"),
                keccak256("1"),
                block.chainid,
                address(pair)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                _QUOTE_TYPEHASH,
                address(swapFunder),
                address(pair),
                size,
                uint256(premiumPerUnit),
                validTill,
                true,
                uint256(0),
                nonce
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSep, structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(mmKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signExerciseSwap(
        SwapExercisingFunder.SwapData memory sd,
        uint256 nonce
    ) internal view returns (bytes memory) {
        bytes32 domainSep = keccak256(
            abi.encode(
                _DOMAIN_TYPEHASH,
                keccak256("ExercisingFunder"),
                keccak256("1"),
                block.chainid,
                address(swapFunder)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                _EXERCISE_SWAP_TYPEHASH,
                address(pair),
                nonce,
                sd.amountIn,
                sd.amountOutMin,
                sd.fee,
                sd.tickSpacing,
                sd.hooks
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSep, structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(mmKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Buyer purchases a `TRADE_SIZE` call from mm, with mm's
    ///      SwapExercisingFunder providing the riskToken collateral.
    function _doBuyCall() internal {
        uint128 premiumPerUnit = PREMIUM; // size==1e18 → totalPremium == PREMIUM
        // Fund buyer with cash for premium
        cashToken.mint(buyer, PREMIUM);
        vm.prank(buyer);
        cashToken.approve(address(pair), PREMIUM);

        // Funder needs riskToken to deposit as collateral
        riskToken.mint(address(swapFunder), TRADE_SIZE);

        uint256 validTill = block.timestamp + 1 hours;
        uint256 nonce = pair.nonces(mm, 0);
        bytes memory sig = _signQuote(
            -int256(uint256(TRADE_SIZE)),
            premiumPerUnit,
            validTill,
            nonce
        );

        vm.prank(buyer);
        pair.buy(
            address(swapFunder),
            mm,
            TRADE_SIZE,
            TRADE_SIZE,
            premiumPerUnit,
            validTill,
            true,
            0,
            sig
        );
    }

    function _exerciseData(
        uint256 amountIn,
        uint256 amountOutMin
    ) internal view returns (bytes memory) {
        return
            _exerciseDataFull(
                amountIn,
                amountOutMin,
                POOL_FEE,
                TICK_SPACING,
                address(0)
            );
    }

    function _exerciseDataV3(
        uint256 amountIn,
        uint256 amountOutMin,
        uint24 fee
    ) internal view returns (bytes memory) {
        return
            _exerciseDataFull(
                amountIn,
                amountOutMin,
                fee,
                int24(0), // tickSpacing unused on V3 path
                V3_HOOK_SENTINEL
            );
    }

    function _exerciseDataFull(
        uint256 amountIn,
        uint256 amountOutMin,
        uint24 fee,
        int24 tickSpacing,
        address hooks
    ) internal view returns (bytes memory) {
        SwapExercisingFunder.SwapData memory sd = SwapExercisingFunder.SwapData({
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: hooks
        });
        uint256 nonce = swapFunder.nonces(address(pair));
        bytes memory sig = _signExerciseSwap(sd, nonce);
        return abi.encode(mm, sd, sig);
    }

    /// @dev Loads PoolManager creation bytecode from its compiled artifact and
    ///      deploys it. We read the artifact directly because v4-core's
    ///      PoolManager is pinned to solc 0.8.26 — keeping it out of our test
    ///      contract's compilation unit avoids pragma conflicts with our
    ///      ^0.8.34 sources.
    function _deployPoolManager(address owner) internal returns (address pm) {
        string memory raw = vm.readFile(
            "out/PoolManager.sol/PoolManager.json"
        );
        bytes memory creation = vm.parseJsonBytes(raw, ".bytecode.object");
        bytes memory initCode = abi.encodePacked(creation, abi.encode(owner));
        assembly {
            pm := create(0, add(initCode, 0x20), mload(initCode))
        }
        require(pm != address(0), "pool manager deploy failed");
    }

    function _warpPastEarliestExercise() internal {
        vm.warp(pair.exerciseEarliest() + 1);
    }

    // =========================================================================
    // Tests
    // =========================================================================

    /// @dev amountIn=0: swap is skipped, funder must already hold the full
    ///      cashToken. Mirrors the plain ExercisingFunder behaviour.
    function test_exercise_noSwap_fullyPrefunded() public {
        _doBuyCall();
        _warpPastEarliestExercise();

        // Pre-fund the funder with the full cash payout
        uint256 owed = TRADE_SIZE; // strike=1e18 → equal
        cashToken.mint(address(swapFunder), owed);

        bytes memory data = _exerciseData(0, 0);

        uint256 vaultBefore = cashToken.balanceOf(address(pair));
        vm.prank(buyer);
        pair.exercise(TRADE_SIZE, address(swapFunder), data);

        assertEq(
            cashToken.balanceOf(address(pair)) - vaultBefore,
            owed,
            "vault got owed cash"
        );
        // Funder's pre-funded `owed` was forwarded to the vault. What remains is
        // the premium proceeds it earned from the original buy.
        uint256 premiumNet = PREMIUM - (uint256(PREMIUM) * 750) / 10_000;
        assertEq(
            cashToken.balanceOf(address(swapFunder)),
            premiumNet,
            "funder kept only premium proceeds"
        );
        // The riskToken returned by the vault stays in the funder's pool.
        assertEq(
            riskToken.balanceOf(address(swapFunder)),
            TRADE_SIZE,
            "funder retains risk"
        );
    }

    /// @dev Swap input chosen so that the swap output exceeds the cash owed.
    ///      Funder keeps the surplus and ends with no need for any pre-funding.
    function test_exercise_swapOverpays_funderRetainsSurplus() public {
        _doBuyCall();
        _warpPastEarliestExercise();

        // owed = TRADE_SIZE cashToken. With ~0.01% fee, swapping all TRADE_SIZE
        // returns slightly less than TRADE_SIZE — but adding a 5% buffer in
        // amountIn means the funder receives more than it owes.
        uint256 amountIn = TRADE_SIZE; // entire deposit goes to swap
        // We don't pre-fund cash. The swap must produce > owed.
        // To guarantee that, pre-fund a sliver of risk so amountIn can exceed
        // what the vault sent: top up the funder with extra risk.
        uint256 extraRisk = TRADE_SIZE / 20; // 5%
        riskToken.mint(address(swapFunder), extraRisk);
        amountIn = TRADE_SIZE + extraRisk;

        // Min out: be permissive (exact swap value is price-dependent).
        bytes memory data = _exerciseData(amountIn, (amountIn * 99) / 100);

        uint256 funderCashBefore = cashToken.balanceOf(address(swapFunder));
        uint256 vaultBefore = cashToken.balanceOf(address(pair));

        vm.prank(buyer);
        pair.exercise(TRADE_SIZE, address(swapFunder), data);

        uint256 owed = TRADE_SIZE;
        assertEq(
            cashToken.balanceOf(address(pair)) - vaultBefore,
            owed,
            "vault got owed cash"
        );
        // Funder kept the surplus from the swap
        assertGt(
            cashToken.balanceOf(address(swapFunder)),
            funderCashBefore,
            "funder kept surplus cash"
        );
        // All risk consumed by the swap
        assertEq(riskToken.balanceOf(address(swapFunder)), 0, "all risk swapped");
    }

    /// @dev amountOutMin understates `owed` so the swap is allowed to return
    ///      less than the full payout. The funder pre-holds enough cash to
    ///      cover the gap.
    function test_exercise_swapPartial_topupFromFunder() public {
        _doBuyCall();
        _warpPastEarliestExercise();

        // Swap only half the deposit — output ~ size/2, so we need ~size/2 cash on hand.
        uint256 amountIn = TRADE_SIZE / 2;
        uint256 prefundedCash = TRADE_SIZE; // generous; surplus stays in funder
        cashToken.mint(address(swapFunder), prefundedCash);

        bytes memory data = _exerciseData(amountIn, (amountIn * 99) / 100);

        uint256 vaultBefore = cashToken.balanceOf(address(pair));
        vm.prank(buyer);
        pair.exercise(TRADE_SIZE, address(swapFunder), data);

        assertEq(
            cashToken.balanceOf(address(pair)) - vaultBefore,
            TRADE_SIZE,
            "vault paid"
        );
        // Funder paid `owed` from (prefund + swap output). It ends with leftover cash.
        assertGt(
            cashToken.balanceOf(address(swapFunder)),
            0,
            "funder still has surplus cash"
        );
        // Half of the deposit was swapped, half remains.
        assertEq(
            riskToken.balanceOf(address(swapFunder)),
            TRADE_SIZE - amountIn,
            "half of risk swapped"
        );
    }

    /// @dev Slippage failure — amountOutMin set above what the pool actually
    ///      returns. Funder must revert with InsufficientOutput.
    function test_exercise_swapFailsSlippage_reverts() public {
        _doBuyCall();
        _warpPastEarliestExercise();

        uint256 amountIn = TRADE_SIZE / 10;
        // Demand more output than amountIn — impossible in a 1:1 fee-bearing pool.
        uint256 amountOutMin = amountIn * 2;

        cashToken.mint(address(swapFunder), TRADE_SIZE); // wouldn't matter — we should revert before transfer

        bytes memory data = _exerciseData(amountIn, amountOutMin);

        vm.prank(buyer);
        vm.expectRevert(SwapExercisingFunder.InsufficientOutput.selector);
        pair.exercise(TRADE_SIZE, address(swapFunder), data);
    }

    /// @dev Tiny amountIn — almost all of the cash payout has to come from
    ///      the funder's existing pre-funded balance.
    function test_exercise_tinyAmountIn_mostlyFromFunder() public {
        _doBuyCall();
        _warpPastEarliestExercise();

        uint256 amountIn = 1e15; // 0.001 risk swapped
        cashToken.mint(address(swapFunder), TRADE_SIZE);

        bytes memory data = _exerciseData(amountIn, 0);

        uint256 vaultBefore = cashToken.balanceOf(address(pair));
        vm.prank(buyer);
        pair.exercise(TRADE_SIZE, address(swapFunder), data);

        assertEq(
            cashToken.balanceOf(address(pair)) - vaultBefore,
            TRADE_SIZE,
            "vault paid"
        );
        // Most of risk untouched.
        assertEq(
            riskToken.balanceOf(address(swapFunder)),
            TRADE_SIZE - amountIn,
            "only tiny risk swapped"
        );
        // Funder keeps swap output as residual cash (pre-funded - owed + ~amountIn).
        assertGt(cashToken.balanceOf(address(swapFunder)), 0, "residual cash");
    }

    /// @dev With no pre-funded cash and a too-small swap, the final
    ///      `safeTransfer` of `amountExpected` underflows and the call reverts.
    function test_exercise_underfunded_reverts() public {
        _doBuyCall();
        _warpPastEarliestExercise();

        // amountIn=0 and no cash pre-funded.
        bytes memory data = _exerciseData(0, 0);

        vm.prank(buyer);
        vm.expectRevert();
        pair.exercise(TRADE_SIZE, address(swapFunder), data);
    }

    // =========================================================================
    // V3-routed exercise scenarios
    // =========================================================================

    /// @dev Full-size V3 swap: deposit → V3 pool → cash, paid to vault.
    function test_exerciseV3_swapExact_paysVault() public {
        _doBuyCall();
        _warpPastEarliestExercise();

        uint256 amountIn = TRADE_SIZE;
        // V3 fee 500 = 5bp; allow generous slippage in case of rounding.
        bytes memory data = _exerciseDataV3(
            amountIn,
            (amountIn * 99) / 100,
            V3_FEE
        );

        uint256 vaultBefore = cashToken.balanceOf(address(pair));
        vm.prank(buyer);
        pair.exercise(TRADE_SIZE, address(swapFunder), data);

        assertEq(
            cashToken.balanceOf(address(pair)) - vaultBefore,
            TRADE_SIZE,
            "vault paid via V3"
        );
        // All risk swapped through V3.
        assertEq(riskToken.balanceOf(address(swapFunder)), 0, "risk drained");
    }

    /// @dev V3 path: amountIn larger than what was returned by vault → pulls
    ///      extra risk pre-funded by mm; surplus cash retained by funder.
    function test_exerciseV3_swapOverpays_funderRetainsSurplus() public {
        _doBuyCall();
        _warpPastEarliestExercise();

        uint256 extraRisk = TRADE_SIZE / 20; // 5%
        riskToken.mint(address(swapFunder), extraRisk);
        uint256 amountIn = TRADE_SIZE + extraRisk;

        bytes memory data = _exerciseDataV3(
            amountIn,
            (amountIn * 99) / 100,
            V3_FEE
        );

        uint256 funderCashBefore = cashToken.balanceOf(address(swapFunder));
        uint256 vaultBefore = cashToken.balanceOf(address(pair));
        vm.prank(buyer);
        pair.exercise(TRADE_SIZE, address(swapFunder), data);

        assertEq(
            cashToken.balanceOf(address(pair)) - vaultBefore,
            TRADE_SIZE,
            "vault paid"
        );
        assertGt(
            cashToken.balanceOf(address(swapFunder)),
            funderCashBefore,
            "V3 surplus retained"
        );
        assertEq(riskToken.balanceOf(address(swapFunder)), 0, "all risk used");
    }

    /// @dev V3 path: tiny amountIn, most cash from funder pre-balance.
    function test_exerciseV3_partialSwap_topupFromFunder() public {
        _doBuyCall();
        _warpPastEarliestExercise();

        uint256 amountIn = TRADE_SIZE / 2;
        cashToken.mint(address(swapFunder), TRADE_SIZE);

        bytes memory data = _exerciseDataV3(
            amountIn,
            (amountIn * 99) / 100,
            V3_FEE
        );

        uint256 vaultBefore = cashToken.balanceOf(address(pair));
        vm.prank(buyer);
        pair.exercise(TRADE_SIZE, address(swapFunder), data);

        assertEq(
            cashToken.balanceOf(address(pair)) - vaultBefore,
            TRADE_SIZE,
            "vault paid"
        );
        assertEq(
            riskToken.balanceOf(address(swapFunder)),
            TRADE_SIZE - amountIn,
            "half risk left"
        );
    }

    /// @dev V3 path: amountOutMin too tight → InsufficientOutput revert.
    function test_exerciseV3_slippage_reverts() public {
        _doBuyCall();
        _warpPastEarliestExercise();

        uint256 amountIn = TRADE_SIZE / 10;
        bytes memory data = _exerciseDataV3(amountIn, amountIn * 2, V3_FEE);

        cashToken.mint(address(swapFunder), TRADE_SIZE); // wouldn't matter
        vm.prank(buyer);
        vm.expectRevert(SwapExercisingFunder.InsufficientOutput.selector);
        pair.exercise(TRADE_SIZE, address(swapFunder), data);
    }

    /// @dev V3 path: signed fee tier with no deployed pool → PoolNotFound.
    function test_exerciseV3_unknownFee_revertsPoolNotFound() public {
        _doBuyCall();
        _warpPastEarliestExercise();

        // Fee 3000 is a valid V3 tier but we never created that pool.
        bytes memory data = _exerciseDataV3(TRADE_SIZE, 0, 3000);

        vm.prank(buyer);
        vm.expectRevert(SwapExercisingFunder.PoolNotFound.selector);
        pair.exercise(TRADE_SIZE, address(swapFunder), data);
    }

    /// @dev V3 swap callback must reject calls from anyone other than the
    ///      legitimate factory-derived pool. Direct call from a stranger
    ///      reverts NotV3Pool.
    function test_exerciseV3_callbackRejectsImpostor() public {
        bytes memory data = abi.encode(
            address(riskToken),
            address(cashToken),
            V3_FEE
        );
        // We are not the V3 pool — calling the callback directly must revert.
        vm.expectRevert(SwapExercisingFunder.NotV3Pool.selector);
        swapFunder.uniswapV3SwapCallback(int256(1), int256(-1), data);
    }

    // =========================================================================
    // Pool sanity checks
    // =========================================================================

    /// @dev Sanity check that the V4 pool was wired up correctly: a direct
    ///      caller-side swap returns ~1:1 minus fee.
    function test_v4Pool_directSwapReturnsRoughly1to1() public {
        // Use an internal swap helper — easier than asserting through the funder.
        DirectSwapper s = new DirectSwapper(poolManager);
        riskToken.mint(address(s), 1e18);
        bool zeroForOne = address(riskToken) < address(cashToken);
        uint256 outBalBefore = cashToken.balanceOf(address(s));
        s.swap(poolKey, zeroForOne, 1e18);
        uint256 received = cashToken.balanceOf(address(s)) - outBalBefore;
        // Expect within 1% of input (fee 0.01% + price impact on wide range).
        assertGt(received, (1e18 * 99) / 100, "swap output too low");
        assertLt(received, 1e18, "swap output should be < input");
    }
}

/// @dev Trivial direct swap helper used purely as a sanity test on the pool.
contract DirectSwapper is IUnlockCallback {
    IPoolManager public immutable manager;

    struct CB {
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
    }

    constructor(IPoolManager _m) {
        manager = _m;
    }

    function swap(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn
    ) external {
        manager.unlock(abi.encode(CB(key, zeroForOne, amountIn)));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        CB memory cb = abi.decode(raw, (CB));

        uint160 limit = cb.zeroForOne
            ? 4295128739 + 1
            : 1461446703485210103287273052203988822378723970342 - 1;

        BalanceDelta delta = manager.swap(
            cb.key,
            // exact-input: amountSpecified negative
            _swapParams(cb.zeroForOne, -int256(cb.amountIn), limit),
            ""
        );
        int128 d0 = int128(BalanceDelta.unwrap(delta) >> 128);
        int128 d1 = int128(BalanceDelta.unwrap(delta));

        Currency cIn = cb.zeroForOne ? cb.key.currency0 : cb.key.currency1;
        Currency cOut = cb.zeroForOne ? cb.key.currency1 : cb.key.currency0;
        int128 dIn = cb.zeroForOne ? d0 : d1;
        int128 dOut = cb.zeroForOne ? d1 : d0;

        manager.sync(cIn);
        IERC20(Currency.unwrap(cIn)).transfer(
            address(manager),
            uint256(uint128(-dIn))
        );
        manager.settle();
        manager.take(cOut, address(this), uint256(uint128(dOut)));
        return "";
    }

    function _swapParams(
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96
    ) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });
    }
}
