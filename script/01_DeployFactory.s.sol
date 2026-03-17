// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {OPairFactory} from "../src/OPairFactory.sol";

/// @notice Deploys OPairFactory.
///
/// Usage:
///   forge script script/01_DeployFactory.s.sol \
///     --rpc-url $RPC_URL \
///     --broadcast \
///     --private-key $PRIVATE_KEY
///
/// The deployer becomes the factory owner and is the only address that can call
/// createPair or extendExpiry on pairs. Transfer ownership with
/// factory.transferOwnership(newOwner) followed by factory.acceptOwnership() (Ownable2Step).
contract DeployFactory is Script {
    function run() external returns (OPairFactory factory) {
        vm.startBroadcast();
        factory = new OPairFactory();
        vm.stopBroadcast();

        console.log("OPairFactory deployed at:", address(factory));
        console.log("Owner:                  ", factory.owner());
    }
}
