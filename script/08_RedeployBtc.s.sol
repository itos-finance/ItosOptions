// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice Redeploy testnet BTC at 8 decimals.
///
/// PR #91 deployed the testnet BTC mock at 18 decimals to match the rest of
/// the stack. That alignment cost us the canonical Bitcoin convention (real
/// WBTC is 8) and made the testnet BTC stand apart from mainnet BTC, which
/// matters for everything that infers decimals from the address (e.g.
/// itos-core::strike::decimals_for_token, the indicative quoter, the SDKs).
/// This script redeploys BTC at 8 decimals so testnet matches mainnet.
///
/// MON stays where it is — only BTC is being rolled back.
///
/// Usage (the redeploy-testnet-btc.sh wrapper handles JSON + Rust updates):
///   forge script script/08_RedeployBtc.s.sol \
///     --rpc-url $RPC_URL \
///     --broadcast \
///     --private-key $DEPLOYER_PRIVATE_KEY
contract RedeployBtc is Script {
    function run() external returns (MockERC20 btc) {
        vm.startBroadcast();
        btc = new MockERC20("Bitcoin", "BTC", 8);
        vm.stopBroadcast();

        console.log("BTC deployed at:", address(btc));
        console.log("decimals:", btc.decimals());
    }
}
