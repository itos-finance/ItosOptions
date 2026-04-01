// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {MintExerciseCallback} from "./MintExerciseCallback.sol";

/// @notice Deploys MintExerciseCallback for testnet use.
///
/// WARNING: MintExerciseCallback relies on MockERC20's permissionless mint().
///          It is only useful on testnets where the swap token has a public mint.
///          Do NOT deploy this on mainnet.
///
/// Usage:
///   forge script script/utilities/DeployMintExerciseCallback.s.sol \
///     --rpc-url $RPC_URL \
///     --broadcast \
///     --private-key $PRIVATE_KEY
contract DeployMintExerciseCallback is Script {
    function run() external returns (MintExerciseCallback cb) {
        vm.startBroadcast();
        cb = new MintExerciseCallback();
        vm.stopBroadcast();

        console.log("MintExerciseCallback deployed at:", address(cb));
    }
}
