// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {Funder} from "../src/Funder.sol";

/// @notice Deploys a Funder for a single market-maker.
///
/// Required env vars:
///   FACTORY  — address of the deployed OPairFactory
///
/// Usage:
///   forge script script/02_DeployFunder.s.sol \
///     --rpc-url $RPC_URL \
///     --broadcast \
///     --private-key $PRIVATE_KEY
///
/// The deployer becomes the Funder owner. Use funder.addSigner(addr) to
/// authorise additional signing keys. Deposit tokens with funder.deposit().
contract DeployFunder is Script {
    function run() external returns (Funder funder) {
        address factory = vm.envAddress("FACTORY");

        vm.startBroadcast();
        funder = new Funder(factory);
        vm.stopBroadcast();

        console.log("Funder deployed at:", address(funder));
        console.log("Factory:           ", address(funder.factory()));
        console.log("Owner:             ", funder.owner());
    }
}
