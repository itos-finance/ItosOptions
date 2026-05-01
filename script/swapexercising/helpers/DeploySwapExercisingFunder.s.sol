// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {SwapExercisingFunder} from "../../../src/utilities/SwapExercisingFunder.sol";

/// @notice Deploys a SwapExercisingFunder wired to the OPair factory, V4
///         PoolManager, and V3 factory. Optionally transfers
///         DEFAULT_ADMIN_ROLE + SIGNER_ROLE to a new owner.
///
/// Required env:
///   OPAIR_FACTORY, V4_POOL_MANAGER, V3_FACTORY
/// Optional env:
///   SWAP_FUNDER_NEW_OWNER  (transfers both roles, deployer renounces)
///
/// Bootstrap-friendly stdout marker:
///   OUT:SWAP_FUNDER=0x...
///
/// WARNING: SwapExercisingFunder is unaudited utility code.
contract DeploySwapExercisingFunder is Script {
    function run() external returns (SwapExercisingFunder funder) {
        address opairFactory = vm.envAddress("OPAIR_FACTORY");
        address poolManager = vm.envAddress("V4_POOL_MANAGER");
        address v3Factory = vm.envOr("V3_FACTORY", address(0));
        address newOwner = vm.envOr("SWAP_FUNDER_NEW_OWNER", address(0));

        vm.startBroadcast();
        funder = new SwapExercisingFunder(
            opairFactory,
            poolManager,
            v3Factory
        );

        if (newOwner != address(0)) {
            funder.grantRole(funder.SIGNER_ROLE(), newOwner);
            funder.renounceRole(funder.SIGNER_ROLE(), tx.origin);
            funder.grantRole(funder.DEFAULT_ADMIN_ROLE(), newOwner);
            funder.renounceRole(funder.DEFAULT_ADMIN_ROLE(), tx.origin);
        }
        vm.stopBroadcast();

        console.log("OUT:SWAP_FUNDER=", address(funder));

        console.log("SwapExercisingFunder:", address(funder));
        console.log("  OPair factory: ", opairFactory);
        console.log("  V4 PoolManager:", poolManager);
        console.log("  V3 Factory:    ", v3Factory);
        if (newOwner != address(0)) {
            console.log("  Owner transferred to:", newOwner);
        }
    }
}
