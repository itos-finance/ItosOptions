// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

/// @notice Deploys a Uniswap V4 PoolManager (or reuses one) and initializes a
///         pool for `(RISK_TOKEN, CASH_TOKEN)`. Driven by env vars; use
///         `bootstrap.py` for orchestration.
///
/// Required env:
///   RISK_TOKEN, CASH_TOKEN, V4_FEE, V4_TICK_SPACING, V4_SQRT_PRICE
/// Optional env:
///   V4_POOL_MANAGER  (set → reuse existing PoolManager, only initialize the pool)
///   V4_HOOKS         (default 0x0)
///   V4_OWNER         (default tx.origin; PoolManager protocol-fee owner)
///
/// Bootstrap-friendly stdout markers:
///   OUT:V4_POOL_MANAGER=0x...     after deploy or reuse
///   OUT:V4_POOL_INITIALIZED=1     after initialize() returns
contract DeployV4Pool is Script {
    function run() external returns (IPoolManager poolManager, PoolKey memory key) {
        address risk = vm.envAddress("RISK_TOKEN");
        address cash = vm.envAddress("CASH_TOKEN");
        uint24 fee = uint24(vm.envUint("V4_FEE"));
        int24 tickSpacing = int24(vm.envInt("V4_TICK_SPACING"));
        uint160 sqrtPrice = uint160(vm.envUint("V4_SQRT_PRICE"));
        address existing = vm.envOr("V4_POOL_MANAGER", address(0));
        address hooks = vm.envOr("V4_HOOKS", address(0));

        require(risk != cash, "tokens must differ");
        (address t0, address t1) = risk < cash ? (risk, cash) : (cash, risk);

        vm.startBroadcast();
        if (existing == address(0)) {
            address owner = vm.envOr("V4_OWNER", tx.origin);
            poolManager = IPoolManager(_deployPoolManager(owner));
        } else {
            poolManager = IPoolManager(existing);
        }

        key = PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });
        int24 tick = poolManager.initialize(key, sqrtPrice);
        vm.stopBroadcast();

        console.log("OUT:V4_POOL_MANAGER=", address(poolManager));
        console.log("OUT:V4_POOL_INITIALIZED=1");

        console.log("V4 PoolManager:", address(poolManager));
        console.log("  fee:          ", uint256(fee));
        console.log("  tickSpacing:  ", int256(tickSpacing));
        console.log("  hooks:        ", hooks);
        console.log("  sqrtPriceX96: ", uint256(sqrtPrice));
        console.log("  tick:         ", int256(tick));
    }

    /// @dev Loads PoolManager creation bytecode from its compiled artifact and
    ///      deploys it. v4-core's source is pinned to solc 0.8.26, so we read
    ///      the artifact directly to keep this script in our ^0.8.34 unit.
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
}
