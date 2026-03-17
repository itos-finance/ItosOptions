// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {OPairFactory} from "../src/OPairFactory.sol";

/// @notice Calls OPairFactory.createPair to deploy a new OPair.
///         Must be run by the factory owner.
///
/// Required env vars:
///   FACTORY          — address of the deployed OPairFactory
///   RISK_TOKEN       — address of the risk token (e.g. WETH)
///   CASH_TOKEN       — address of the cash token (e.g. USDC)
///   STRIKE           — strike price, risk-token units per cash-token in 18-decimal fixed point
///                      e.g. for ETH/USDC at $2000: 2000 * 1e18 / 1e6 * 1e18 = depends on decimals;
///                      more simply: strike = strikeUSD * 10^(18 + cashDecimals - riskDecimals)
///   EXPIRY           — unix timestamp (must be in the future)
///   IS_CALL          — "true" for a call, "false" for a put
///   MIN_DEPOSIT_SIZE — minimum short position size in risk-token units (18-decimal)
///   IDENTIFIER       — human-readable name, e.g. "WETH-USDC-2000-20260101"
///   SYMBOL           — token symbol prefix, e.g. "WETH2K"
///
/// Usage:
///   forge script script/05_CreatePair.s.sol \
///     --rpc-url $RPC_URL \
///     --broadcast \
///     --private-key $PRIVATE_KEY
contract CreatePair is Script {
    function run() external returns (address pair) {
        address factory   = vm.envAddress("FACTORY");
        address riskToken = vm.envAddress("RISK_TOKEN");
        address cashToken = vm.envAddress("CASH_TOKEN");
        uint128 strike    = uint128(vm.envUint("STRIKE"));
        uint256 expiry    = vm.envUint("EXPIRY");
        bool    isCall    = vm.envBool("IS_CALL");
        uint128 minDeposit = uint128(vm.envUint("MIN_DEPOSIT_SIZE"));
        string memory identifier = vm.envString("IDENTIFIER");
        string memory symbol     = vm.envString("SYMBOL");

        vm.startBroadcast();
        pair = OPairFactory(factory).createPair(
            riskToken,
            cashToken,
            strike,
            expiry,
            isCall,
            minDeposit,
            identifier,
            symbol
        );
        vm.stopBroadcast();

        console.log("OPair deployed at:", pair);
        console.log("  riskToken:      ", riskToken);
        console.log("  cashToken:      ", cashToken);
        console.log("  strike:         ", strike);
        console.log("  expiry:         ", expiry);
        console.log("  isCall:         ", isCall);
        console.log("  minDepositSize: ", minDeposit);
    }
}
