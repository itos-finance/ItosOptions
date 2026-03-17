// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {Bulletin} from "../src/Bulletin.sol";

/// @notice Deploys the Bulletin on-chain order book.
///
/// Required env vars:
///   FACTORY  — address of the deployed OPairFactory
///
/// Usage:
///   forge script script/04_DeployBulletin.s.sol \
///     --rpc-url $RPC_URL \
///     --broadcast \
///     --private-key $PRIVATE_KEY
///
/// The Bulletin is permissionless — no owner. Anyone can post a valid signed
/// order or cancel their own order.
contract DeployBulletin is Script {
    function run() external returns (Bulletin bulletin) {
        address factory = vm.envAddress("FACTORY");

        vm.startBroadcast();
        bulletin = new Bulletin(factory);
        vm.stopBroadcast();

        console.log("Bulletin deployed at:", address(bulletin));
        console.log("Factory:            ", address(bulletin.factory()));
    }
}
