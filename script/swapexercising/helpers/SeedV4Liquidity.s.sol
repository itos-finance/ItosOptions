// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";

/// @notice Seeds liquidity into the configured V4 pool.
///
/// Required env:
///   V4_POOL_MANAGER, RISK_TOKEN, CASH_TOKEN, V4_FEE, V4_TICK_SPACING, LIQUIDITY
/// Optional env:
///   V4_HOOKS    (default 0x0)
///   TICK_LOWER  (default -10000)
///   TICK_UPPER  (default 10000)
///
/// Bootstrap-friendly stdout marker:
///   OUT:V4_LP_HELPER=0x...
contract SeedV4Liquidity is Script {
    function run() external returns (V4LpHelper helper) {
        IPoolManager pm = IPoolManager(vm.envAddress("V4_POOL_MANAGER"));
        address risk = vm.envAddress("RISK_TOKEN");
        address cash = vm.envAddress("CASH_TOKEN");
        uint24 fee = uint24(vm.envUint("V4_FEE"));
        int24 tickSpacing = int24(vm.envInt("V4_TICK_SPACING"));
        uint256 liquidity = vm.envUint("LIQUIDITY");
        address hooks = vm.envOr("V4_HOOKS", address(0));
        int24 tickLower = int24(vm.envOr("TICK_LOWER", int256(-10000)));
        int24 tickUpper = int24(vm.envOr("TICK_UPPER", int256(10000)));

        require(risk != cash, "tokens must differ");
        (address t0, address t1) = risk < cash ? (risk, cash) : (cash, risk);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });

        vm.startBroadcast();
        helper = new V4LpHelper(pm);
        IERC20(t0).approve(address(helper), type(uint256).max);
        IERC20(t1).approve(address(helper), type(uint256).max);
        helper.addLiquidity(key, tickLower, tickUpper, liquidity);
        vm.stopBroadcast();

        console.log("OUT:V4_LP_HELPER=", address(helper));
        console.log("V4 LP helper:", address(helper));
        console.log("  liquidityDelta:", liquidity);
        console.log("  tickLower:     ", int256(tickLower));
        console.log("  tickUpper:     ", int256(tickUpper));
    }
}

contract V4LpHelper is IUnlockCallback {
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

    function unlockCallback(
        bytes calldata raw
    ) external returns (bytes memory) {
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
