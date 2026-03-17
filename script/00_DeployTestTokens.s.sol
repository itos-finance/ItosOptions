// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice Deploys test ERC20 tokens (WETH and USDC) for Monad testnet.
///
/// Usage:
///   forge script script/00_DeployTestTokens.s.sol \
///     --rpc-url $RPC_URL \
///     --broadcast \
///     --private-key $DEPLOYER_PRIVATE_KEY
contract DeployTestTokens is Script {
    function run() external returns (MockERC20 weth, MockERC20 usdc) {
        vm.startBroadcast();
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vm.stopBroadcast();

        console.log("WETH deployed at:", address(weth));
        console.log("USDC deployed at:", address(usdc));
    }
}
