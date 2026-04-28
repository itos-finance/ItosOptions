// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {ExercisingFunder} from "../../src/utilities/ExercisingFunder.sol";

/// @notice Deploys an ExercisingFunder for a single market-maker.
///
/// WARNING: ExercisingFunder is unaudited utility code.
///
/// Required env vars:
///   FACTORY    — address of the deployed OPairFactory
/// Optional env vars:
///   NEW_OWNER  — if set, DEFAULT_ADMIN_ROLE and SIGNER_ROLE are transferred
///                to this address after deployment (deployer renounces both).
///
/// Usage:
///   forge script script/utilities/DeployExercisingFunder.s.sol \
///     --rpc-url $RPC_URL \
///     --broadcast \
///     --private-key $PRIVATE_KEY
///
/// The deployer becomes the owner. Use funder.grantRole(SIGNER_ROLE, addr) to
/// authorise additional signing keys. Deposit tokens with funder.deposit().
/// The contract also serves as an IExerciseCallback: pass it to
/// OPair.exercise / unexercise with `data = abi.encode(signer, signature)`
/// where the signature covers `Exercise(vault, nonce)`.
contract DeployExercisingFunder is Script {
    function run() external returns (ExercisingFunder funder) {
        address factory = vm.envAddress("FACTORY");
        address newOwner = vm.envOr("NEW_OWNER", address(0));

        vm.startBroadcast();
        funder = new ExercisingFunder(factory);

        if (newOwner != address(0)) {
            funder.grantRole(funder.SIGNER_ROLE(), newOwner);
            funder.renounceRole(funder.SIGNER_ROLE(), msg.sender);
            funder.grantRole(funder.DEFAULT_ADMIN_ROLE(), newOwner);
            funder.renounceRole(funder.DEFAULT_ADMIN_ROLE(), msg.sender);
        }
        vm.stopBroadcast();

        console.log("ExercisingFunder deployed at:", address(funder));
        console.log("Factory:                     ", address(funder.factory()));
        if (newOwner != address(0)) {
            console.log("Owner transferred:           ", newOwner);
        }
    }
}
