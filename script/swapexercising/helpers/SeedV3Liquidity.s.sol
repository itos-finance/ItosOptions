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
    function mint(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bytes calldata data
    ) external returns (uint256 amount0, uint256 amount1);
}

/// @notice Seeds liquidity into the configured V3 pool.
///
/// Required env:
///   V3_FACTORY, RISK_TOKEN, CASH_TOKEN, V3_FEE, LIQUIDITY
/// Optional env:
///   TICK_LOWER  (default -887220, valid for tickSpacing=10)
///   TICK_UPPER  (default  887220)
///
/// Bootstrap-friendly stdout markers:
///   OUT:V3_LP_HELPER=0x...
///   OUT:V3_POOL=0x...
contract SeedV3Liquidity is Script {
    function run() external returns (V3LpHelper helper, address pool) {
        address factory = vm.envAddress("V3_FACTORY");
        address risk = vm.envAddress("RISK_TOKEN");
        address cash = vm.envAddress("CASH_TOKEN");
        uint24 fee = uint24(vm.envUint("V3_FEE"));
        uint128 liquidity = uint128(vm.envUint("LIQUIDITY"));
        int24 tickLower = int24(vm.envOr("TICK_LOWER", int256(-887220)));
        int24 tickUpper = int24(vm.envOr("TICK_UPPER", int256(887220)));

        require(risk != cash, "tokens must differ");
        (address t0, address t1) = risk < cash ? (risk, cash) : (cash, risk);
        pool = IV3Factory(factory).getPool(t0, t1, fee);
        require(pool != address(0), "v3 pool not found");

        vm.startBroadcast();
        helper = new V3LpHelper();
        IERC20(t0).approve(address(helper), type(uint256).max);
        IERC20(t1).approve(address(helper), type(uint256).max);
        helper.addLiquidity(pool, t0, t1, tickLower, tickUpper, liquidity);
        vm.stopBroadcast();

        console.log("OUT:V3_LP_HELPER=", address(helper));
        console.log("OUT:V3_POOL=", pool);
        console.log("V3 LP helper:", address(helper));
        console.log("  pool:      ", pool);
        console.log("  liquidity: ", uint256(liquidity));
    }
}

contract V3LpHelper {
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
