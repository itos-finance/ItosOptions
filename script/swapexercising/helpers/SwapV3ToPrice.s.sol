// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

interface IV3Factory {
    function getPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external view returns (address);
}

interface IV3Pool {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16,
            uint16,
            uint16,
            uint8,
            bool
        );
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

/// @notice Pushes the configured V3 pool's spot price toward TARGET_SQRT_PRICE,
///         capped by MAX_INPUT.
///
/// Required env:
///   V3_FACTORY, RISK_TOKEN, CASH_TOKEN, V3_FEE, TARGET_SQRT_PRICE, MAX_INPUT
contract SwapV3ToPrice is Script {
    function run() external returns (V3SwapHelper helper, address pool) {
        address factory = vm.envAddress("V3_FACTORY");
        address risk = vm.envAddress("RISK_TOKEN");
        address cash = vm.envAddress("CASH_TOKEN");
        uint24 fee = uint24(vm.envUint("V3_FEE"));
        uint160 target = uint160(vm.envUint("TARGET_SQRT_PRICE"));
        uint256 maxInput = vm.envUint("MAX_INPUT");

        require(risk != cash, "tokens must differ");
        (address t0, address t1) = risk < cash ? (risk, cash) : (cash, risk);
        pool = IV3Factory(factory).getPool(t0, t1, fee);
        require(pool != address(0), "v3 pool not found");

        (uint160 currentSqrt, , , , , , ) = IV3Pool(pool).slot0();
        require(currentSqrt != 0, "pool not initialized");
        bool zeroForOne = target < currentSqrt;
        address tokenIn = zeroForOne ? t0 : t1;

        vm.startBroadcast();
        helper = new V3SwapHelper(factory);
        IERC20(tokenIn).approve(address(helper), maxInput);
        helper.swap(t0, t1, fee, zeroForOne, int256(maxInput), target, tx.origin);
        vm.stopBroadcast();

        (uint160 finalSqrt, , , , , , ) = IV3Pool(pool).slot0();
        console.log("V3 swap helper:", address(helper));
        console.log("  start sqrtPriceX96:", uint256(currentSqrt));
        console.log("  end sqrtPriceX96:  ", uint256(finalSqrt));
        console.log("  target sqrtPriceX96:", uint256(target));
    }
}

contract V3SwapHelper {
    IV3Factory public immutable factory;

    constructor(address _factory) {
        factory = IV3Factory(_factory);
    }

    function swap(
        address token0,
        address token1,
        uint24 fee,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        address payer
    ) external returns (int256 amount0, int256 amount1) {
        address pool = factory.getPool(token0, token1, fee);
        require(pool != address(0), "v3 pool not found");
        bytes memory data = abi.encode(token0, token1, fee, payer);
        (amount0, amount1) = IV3Pool(pool).swap(
            payer,
            zeroForOne,
            amountSpecified,
            sqrtPriceLimitX96,
            data
        );
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        (address token0, address token1, uint24 fee, address payer) = abi
            .decode(data, (address, address, uint24, address));
        require(msg.sender == factory.getPool(token0, token1, fee), "not v3 pool");

        if (amount0Delta > 0) {
            IERC20(token0).transferFrom(
                payer,
                msg.sender,
                uint256(amount0Delta)
            );
        }
        if (amount1Delta > 0) {
            IERC20(token1).transferFrom(
                payer,
                msg.sender,
                uint256(amount1Delta)
            );
        }
    }
}
