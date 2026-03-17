// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {MultiFunder} from "../src/MultiFunder.sol";

/// @notice Deploys MultiFunder — the shared funding contract where each signer
///         maintains their own per-token balance.
///
/// Required env vars:
///   FACTORY  — address of the deployed OPairFactory
///
/// Usage:
///   forge script script/03_DeployMultiFunder.s.sol \
///     --rpc-url $RPC_URL \
///     --broadcast \
///     --private-key $PRIVATE_KEY
///
/// After deployment, signers deposit tokens with multiFunder.deposit(signer, token, amount)
/// and can withdraw with multiFunder.withdraw(token, amount).
contract DeployMultiFunder is Script {
    function run() external returns (MultiFunder multiFunder) {
        address factory = vm.envAddress("FACTORY");

        vm.startBroadcast();
        multiFunder = new MultiFunder(factory);
        vm.stopBroadcast();

        console.log("MultiFunder deployed at:", address(multiFunder));
        console.log("Factory:               ", address(multiFunder.factory()));
    }
}
