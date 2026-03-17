// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {Funder} from "../src/Funder.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Post-deployment script: mints tokens and sets up per-maker funders.
///
/// Required env vars:
///   FACTORY — address of the deployed OPairFactory
///   WETH    — address of the deployed MockERC20 (WETH)
///   USDC    — address of the deployed MockERC20 (USDC)
///
/// Usage:
///   FACTORY=0x... WETH=0x... USDC=0x... \
///     forge script script/06_SetupMakers.s.sol \
///     --rpc-url $RPC_URL --broadcast --private-key $DEPLOYER_PRIVATE_KEY
contract SetupMakers is Script {
    // Anvil deterministic addresses for mock makers (accounts #2, #3, #4)
    address constant MAKER_0 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address constant MAKER_1 = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address constant MAKER_2 = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;

    function run() external {
        address factory = vm.envAddress("FACTORY");
        MockERC20 weth = MockERC20(vm.envAddress("WETH"));
        MockERC20 usdc = MockERC20(vm.envAddress("USDC"));

        address[3] memory makers = [MAKER_0, MAKER_1, MAKER_2];

        vm.startBroadcast();

        // 1. Mint tokens to deployer
        weth.mint(msg.sender, 1000 ether);
        usdc.mint(msg.sender, 2_000_000e6);
        console.log("Minted 1000 WETH + 2M USDC to deployer:", msg.sender);

        // 2. For each maker: mint tokens, deploy funder, add signer, deposit
        for (uint256 i = 0; i < 3; i++) {
            address maker = makers[i];

            // Mint directly to maker wallet
            weth.mint(maker, 50 ether);
            usdc.mint(maker, 100_000e6);

            // Deploy a new Funder (deployer is owner)
            Funder funder = new Funder(factory);

            // Authorize the maker as a signer
            funder.addSigner(maker);

            // Approve funder to pull tokens from deployer
            IERC20(address(weth)).approve(address(funder), 100 ether);
            IERC20(address(usdc)).approve(address(funder), 500_000e6);

            // Deposit tokens into the funder on behalf of the maker
            funder.deposit(maker, address(weth), 100 ether);
            funder.deposit(maker, address(usdc), 500_000e6);

            console.log("---");
            console.log("Maker", i);
            console.log("  Address:", maker);
            console.log("  Funder deployed at:", address(funder));
            console.log("  Deposited: 100 WETH + 500K USDC");
        }

        vm.stopBroadcast();
    }
}
