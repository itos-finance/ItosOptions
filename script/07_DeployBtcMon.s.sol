// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice Deploys mock BTC (18 decimals) and MON (18 decimals) ERC20 tokens for Monad testnet.
///
/// BTC is deployed with 18 decimals (NOT real Bitcoin's 8) so the mock matches
/// every other risk token in the testnet stack. Real WBTC on mainnet is still 8;
/// keep that in mind when bringing this script up against a non-mock chain.
///
/// Usage:
///   forge script script/07_DeployBtcMon.s.sol \
///     --rpc-url $RPC_URL \
///     --broadcast \
///     --private-key $DEPLOYER_PRIVATE_KEY
contract DeployBtcMon is Script {
    function run() external returns (MockERC20 btc, MockERC20 mon) {
        vm.startBroadcast();
        btc = new MockERC20("Bitcoin", "BTC", 18);
        mon = new MockERC20("Monad", "MON", 18);
        vm.stopBroadcast();

        console.log("BTC deployed at:", address(btc));
        console.log("MON deployed at:", address(mon));
    }
}
