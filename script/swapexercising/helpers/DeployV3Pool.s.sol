// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";

interface IV3Factory {
    function owner() external view returns (address);
    function feeAmountTickSpacing(uint24 fee) external view returns (int24);
    function enableFeeAmount(uint24 fee, int24 tickSpacing) external;
    function getPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external view returns (address);
    function createPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external returns (address);
}

interface IV3Pool {
    function initialize(uint160 sqrtPriceX96) external;
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
}

/// @notice Deploys a Uniswap V3 factory (or reuses one) and initializes a
///         pool for `(RISK_TOKEN, CASH_TOKEN, V3_FEE)`. Idempotent — skips
///         create/initialize when state already exists on-chain.
///
/// Required env:
///   RISK_TOKEN, CASH_TOKEN, V3_FEE, V3_SQRT_PRICE
/// Optional env:
///   V3_FACTORY       (set → reuse existing factory)
///   V3_TICK_SPACING  (only used when enabling a non-default fee tier)
///
/// Bootstrap-friendly stdout markers:
///   OUT:V3_FACTORY=0x...
///   OUT:V3_POOL=0x...
///   OUT:V3_POOL_INITIALIZED=1
contract DeployV3Pool is Script {
    function run() external returns (IV3Factory factory, address pool) {
        address risk = vm.envAddress("RISK_TOKEN");
        address cash = vm.envAddress("CASH_TOKEN");
        uint24 fee = uint24(vm.envUint("V3_FEE"));
        uint160 sqrtPrice = uint160(vm.envUint("V3_SQRT_PRICE"));
        address existing = vm.envOr("V3_FACTORY", address(0));
        int24 tickSpacing = int24(vm.envOr("V3_TICK_SPACING", int256(0)));

        require(risk != cash, "tokens must differ");
        (address t0, address t1) = risk < cash ? (risk, cash) : (cash, risk);

        vm.startBroadcast();
        if (existing == address(0)) {
            factory = IV3Factory(_deployV3Factory());
        } else {
            factory = IV3Factory(existing);
        }

        if (
            factory.feeAmountTickSpacing(fee) == 0 &&
            factory.owner() == tx.origin
        ) {
            require(tickSpacing > 0, "tick spacing required for new fee");
            factory.enableFeeAmount(fee, tickSpacing);
        }

        pool = factory.getPool(t0, t1, fee);
        if (pool == address(0)) {
            pool = factory.createPool(t0, t1, fee);
        }
        (uint160 currentSqrt, , , , , , ) = IV3Pool(pool).slot0();
        if (currentSqrt == 0) {
            IV3Pool(pool).initialize(sqrtPrice);
        }
        vm.stopBroadcast();

        console.log("OUT:V3_FACTORY=", address(factory));
        console.log("OUT:V3_POOL=", pool);
        console.log("OUT:V3_POOL_INITIALIZED=1");

        console.log("V3 Factory:", address(factory));
        console.log("V3 Pool:   ", pool);
        console.log("  fee:          ", uint256(fee));
        console.log("  sqrtPriceX96: ", uint256(sqrtPrice));
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
}
