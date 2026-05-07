// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {OPairFactory} from "../src/OPairFactory.sol";

/// @notice Hands DEFAULT_ADMIN_ROLE on the Monad-mainnet OPairFactory from
/// the deployer EOA to the production multisig. This also migrates per-pair
/// admin powers (extendExpiry, setDepositDeadline, setExerciseEarliest,
/// claimFees) since OPair gates them on factory.DEFAULT_ADMIN_ROLE.
///
/// Run AFTER 09_TransferIssuer — this script renounces the deployer's admin,
/// after which the deployer can no longer grant or revoke any role on the
/// factory or any OPair it has issued.
///
/// IRREVERSIBLE. The script refuses to broadcast unless the env var
/// CONFIRM_TRANSFER_ADMIN=true is set, so the renounce can't be a typo.
///
/// Steps performed:
///   1. grantRole(DEFAULT_ADMIN_ROLE, NEW_ADMIN)
///   2. renounceRole(DEFAULT_ADMIN_ROLE, deployer)
///
/// Usage:
///   cd contracts
///   CONFIRM_TRANSFER_ADMIN=true forge script script/10_TransferAdmin.s.sol \
///     --rpc-url $RPC_URL_143 \
///     --account $DEPLOYER_KEYSTORE \
///     --sender $DEPLOYER_PUBLIC_KEY \
///     --broadcast
contract TransferAdmin is Script {
    /// Monad mainnet chain id. The script refuses to broadcast on any
    /// other chain so a misconfigured RPC can't accidentally run it.
    uint256 constant EXPECTED_CHAIN_ID = 143;

    /// Monad-mainnet OPairFactory (deploy block 70959015).
    address constant FACTORY = 0xcaD3e639BE89f673d7dBa41b2614369126CbD38f;

    /// Production multisig — new DEFAULT_ADMIN_ROLE holder.
    address constant NEW_ADMIN = 0xAFD30d1a63A1E355ee6c113D3e709Ed06DAda03B;

    function run() external {
        require(
            block.chainid == EXPECTED_CHAIN_ID,
            "wrong chain - this script only runs on Monad mainnet (143)"
        );
        require(
            vm.envOr("CONFIRM_TRANSFER_ADMIN", false),
            "set CONFIRM_TRANSFER_ADMIN=true to acknowledge irreversible renounce"
        );

        OPairFactory factory = OPairFactory(FACTORY);
        bytes32 ADMIN_ROLE = factory.DEFAULT_ADMIN_ROLE();
        address deployer = msg.sender;

        require(factory.hasRole(ADMIN_ROLE, deployer), "deployer is not admin");

        // ISSUER_ROLE must already be off the deployer — otherwise running
        // 10_TransferAdmin first leaves an orphaned issuer the multisig has
        // to revoke later. Refuse here so the order is enforced on-chain.
        require(
            !factory.hasRole(factory.ISSUER_ROLE(), deployer),
            "deployer still holds ISSUER_ROLE - run 09_TransferIssuer first"
        );

        console.log("=== DEFAULT_ADMIN_ROLE handoff ===");
        console.log("  factory:    ", FACTORY);
        console.log("  from:       ", deployer);
        console.log("  to:         ", NEW_ADMIN);
        console.log("  IRREVERSIBLE: deployer renounce follows the grant.");

        vm.startBroadcast();
        factory.grantRole(ADMIN_ROLE, NEW_ADMIN);
        factory.renounceRole(ADMIN_ROLE, deployer);
        vm.stopBroadcast();

        require(factory.hasRole(ADMIN_ROLE, NEW_ADMIN), "grant failed");
        require(!factory.hasRole(ADMIN_ROLE, deployer), "renounce failed");

        console.log("  granted:    ", NEW_ADMIN);
        console.log("  renounced:  ", deployer);
    }
}
