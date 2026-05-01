// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @notice Pushes the configured V4 pool's spot price toward TARGET_SQRT_PRICE,
///         capped by MAX_INPUT.
///
/// Required env:
///   V4_POOL_MANAGER, RISK_TOKEN, CASH_TOKEN, V4_FEE, V4_TICK_SPACING,
///   TARGET_SQRT_PRICE, MAX_INPUT
/// Optional env:
///   V4_HOOKS  (default 0x0)
contract SwapV4ToPrice is Script {
    using StateLibrary for IPoolManager;

    function run() external returns (V4SwapHelper helper) {
        IPoolManager pm = IPoolManager(vm.envAddress("V4_POOL_MANAGER"));
        address risk = vm.envAddress("RISK_TOKEN");
        address cash = vm.envAddress("CASH_TOKEN");
        uint24 fee = uint24(vm.envUint("V4_FEE"));
        int24 tickSpacing = int24(vm.envInt("V4_TICK_SPACING"));
        address hooks = vm.envOr("V4_HOOKS", address(0));
        uint160 target = uint160(vm.envUint("TARGET_SQRT_PRICE"));
        uint256 maxInput = vm.envUint("MAX_INPUT");

        require(risk != cash, "tokens must differ");
        (address t0, address t1) = risk < cash ? (risk, cash) : (cash, risk);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });

        (uint160 currentSqrt, , , ) = pm.getSlot0(_id(key));
        require(currentSqrt != 0, "pool not initialized");
        bool zeroForOne = target < currentSqrt;
        address tokenIn = zeroForOne ? t0 : t1;

        vm.startBroadcast();
        helper = new V4SwapHelper(pm);
        IERC20(tokenIn).approve(address(helper), maxInput);
        helper.swap(key, zeroForOne, maxInput, target, tx.origin);
        vm.stopBroadcast();

        (uint160 finalSqrt, , , ) = pm.getSlot0(_id(key));
        console.log("V4 swap helper:", address(helper));
        console.log("  start sqrtPriceX96:", uint256(currentSqrt));
        console.log("  end sqrtPriceX96:  ", uint256(finalSqrt));
        console.log("  target sqrtPriceX96:", uint256(target));
    }

    function _id(PoolKey memory k) internal pure returns (PoolId) {
        return PoolId.wrap(keccak256(abi.encode(k)));
    }
}

contract V4SwapHelper is IUnlockCallback {
    IPoolManager public immutable manager;

    struct Data {
        PoolKey key;
        bool zeroForOne;
        uint256 maxInput;
        uint160 limit;
        address payer;
    }

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function swap(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 maxInput,
        uint160 limit,
        address payer
    ) external {
        manager.unlock(
            abi.encode(Data(key, zeroForOne, maxInput, limit, payer))
        );
    }

    function unlockCallback(
        bytes calldata raw
    ) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        Data memory d = abi.decode(raw, (Data));

        BalanceDelta delta = manager.swap(
            d.key,
            SwapParams({
                zeroForOne: d.zeroForOne,
                amountSpecified: -int256(d.maxInput),
                sqrtPriceLimitX96: d.limit
            }),
            ""
        );
        int128 d0 = int128(BalanceDelta.unwrap(delta) >> 128);
        int128 d1 = int128(BalanceDelta.unwrap(delta));
        int128 inDelta = d.zeroForOne ? d0 : d1;
        int128 outDelta = d.zeroForOne ? d1 : d0;

        Currency cIn = d.zeroForOne ? d.key.currency0 : d.key.currency1;
        Currency cOut = d.zeroForOne ? d.key.currency1 : d.key.currency0;

        if (inDelta < 0) {
            uint256 owed = uint256(uint128(-inDelta));
            manager.sync(cIn);
            IERC20(Currency.unwrap(cIn)).transferFrom(
                d.payer,
                address(manager),
                owed
            );
            manager.settle();
        }
        if (outDelta > 0) {
            manager.take(cOut, d.payer, uint256(uint128(outDelta)));
        }
        return "";
    }
}
