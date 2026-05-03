// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {OPairFactory} from "../src/OPairFactory.sol";

/// @notice Hands ISSUER_ROLE on the Monad-mainnet OPairFactory from the
/// deployer EOA to the production Trezor.
///
/// Run BEFORE 10_TransferAdmin — once DEFAULT_ADMIN_ROLE moves to the
/// multisig the deployer can no longer grant or revoke roles, so the
/// issuer-side handoff must happen first.
///
/// Steps performed:
///   1. grantRole(ISSUER_ROLE, NEW_ISSUER)
///   2. renounceRole(ISSUER_ROLE, deployer)
///
/// Usage:
///   cd contracts
///   forge script script/09_TransferIssuer.s.sol \
///     --rpc-url $MONAD_MAINNET_RPC \
///     --private-key $DEPLOYER_PRIVATE_KEY \
///     --broadcast
contract TransferIssuer is Script {
    /// Monad mainnet chain id. The script refuses to broadcast on any
    /// other chain so a misconfigured RPC can't accidentally run it.
    uint256 constant EXPECTED_CHAIN_ID = 143;

    /// Monad-mainnet OPairFactory (deploy block 70959015).
    address constant FACTORY = 0xcaD3e639BE89f673d7dBa41b2614369126CbD38f;

    /// Production Trezor — new ISSUER_ROLE holder.
    address constant NEW_ISSUER = 0x81785e00055159FCae25703D06422aBF5603f8A8;

    function run() external {
        require(
            block.chainid == EXPECTED_CHAIN_ID,
            "wrong chain - this script only runs on Monad mainnet (143)"
        );

        OPairFactory factory = OPairFactory(FACTORY);
        bytes32 ISSUER_ROLE = factory.ISSUER_ROLE();
        address deployer = msg.sender;

        require(
            factory.hasRole(ISSUER_ROLE, deployer),
            "deployer does not hold ISSUER_ROLE"
        );
        require(
            factory.hasRole(factory.DEFAULT_ADMIN_ROLE(), deployer),
            "deployer does not hold DEFAULT_ADMIN_ROLE (needed to grant)"
        );

        console.log("=== ISSUER_ROLE handoff ===");
        console.log("  factory:    ", FACTORY);
        console.log("  from:       ", deployer);
        console.log("  to:         ", NEW_ISSUER);

        vm.startBroadcast();
        factory.grantRole(ISSUER_ROLE, NEW_ISSUER);
        factory.renounceRole(ISSUER_ROLE, deployer);
        vm.stopBroadcast();

        require(factory.hasRole(ISSUER_ROLE, NEW_ISSUER), "grant failed");
        require(!factory.hasRole(ISSUER_ROLE, deployer), "renounce failed");

        console.log("  granted:    ", NEW_ISSUER);
        console.log("  renounced:  ", deployer);
    }
}
