// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice Deploys mock BTC (8 decimals) and MON (18 decimals) ERC20 tokens for Monad testnet.
///
/// Usage:
///   forge script script/07_DeployBtcMon.s.sol \
///     --rpc-url $RPC_URL \
///     --broadcast \
///     --private-key $DEPLOYER_PRIVATE_KEY
contract DeployBtcMon is Script {
    function run() external returns (MockERC20 btc, MockERC20 mon) {
        vm.startBroadcast();
        btc = new MockERC20("Bitcoin", "BTC", 8);
        mon = new MockERC20("Monad", "MON", 18);
        vm.stopBroadcast();

        console.log("BTC deployed at:", address(btc));
        console.log("MON deployed at:", address(mon));
    }
}
