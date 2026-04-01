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
/// The deployer is granted DEFAULT_ADMIN_ROLE and ISSUER_ROLE.
/// Transfer admin via factory.grantRole(DEFAULT_ADMIN_ROLE, newAdmin) then
/// factory.revokeRole(DEFAULT_ADMIN_ROLE, oldAdmin). Grant pair creation to other
/// addresses with factory.grantRole(ISSUER_ROLE, addr).
contract DeployFactory is Script {
    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 constant ISSUER_ROLE = keccak256("ISSUER_ROLE");

    function run() external returns (OPairFactory factory) {
        address deployer = msg.sender;

        vm.startBroadcast();
        factory = new OPairFactory();
        vm.stopBroadcast();

        console.log("OPairFactory deployed at:", address(factory));
        console.log("Admin (DEFAULT_ADMIN_ROLE):", factory.hasRole(DEFAULT_ADMIN_ROLE, deployer));
        console.log("Issuer (ISSUER_ROLE):      ", factory.hasRole(ISSUER_ROLE, deployer));
    }
}
