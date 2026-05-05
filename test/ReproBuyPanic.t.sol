// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {OPair} from "../src/OPair.sol";
import {OPairFactory} from "../src/OPairFactory.sol";

/// One-off repro for a wallet-side estimateGas failure on Monad testnet.
/// Run with: forge test --match-test test_ReproBuyPanic -vvvv
contract ReproBuyPanic is Test {
    address constant PAIR    = 0x835e68fD72CCb70DD923E0Ea344A76e9F5345368; // call_3000_20260503
    address constant FACTORY = 0xFfCA41705ADCa7e8ea12fe74b96AD03C55025C7d;
    address constant BUYER   = 0x5c6816D0Ec8a02270c4Ad739aD2B6a3502a1576D;

    uint256 constant FORK_BLOCK = 29047919;

    /// Toggle to true if traces show raw opcodes (deployed bytecode does not
    /// match local artifact metadata). Overlays local OPair/OPairFactory
    /// bytecode at the deployed addresses while preserving forked storage.
    bool constant ETCH_LOCAL_BYTECODE = false;

    // Calldata copied verbatim from the wallet error (with leading 0x stripped).
    // Decoded:
    //   sellerFunder     = 0xb91d325703720ba9b5135ce1cc28cb66e0e51ec3
    //   sellerSigner     = 0x29c0e2fff128ffae7c22b87938c061d0d8127fc7
    //   size             = 1e18
    //   fill             = 1e18
    //   premiumPerUnit   = 363969 (0x58dc1)
    //   validTill        = 0x69f50273
    //   allowPartialFill = true
    //   channel          = 3
    //   signature        = 65 bytes
    bytes constant CALLDATA = hex"b3e0aaf8000000000000000000000000b91d325703720ba9b5135ce1cc28cb66e0e51ec300000000000000000000000029c0e2fff128ffae7c22b87938c061d0d8127fc70000000000000000000000000000000000000000000000000de0b6b3a76400000000000000000000000000000000000000000000000000000de0b6b3a76400000000000000000000000000000000000000000000000000000000000000058dc10000000000000000000000000000000000000000000000000000000069f5027300000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000000000412c3deb19465717578b93f1568b1c998295bc8908192f7d11ff030d401550253a5565e514f28b43180e1e3ab17f23a08b6c80fa3ae643e1fb53b80477c631b08e1c00000000000000000000000000000000000000000000000000000000000000";

    function setUp() public {
        vm.createSelectFork(vm.envString("TESTNET_RPC"), FORK_BLOCK);

        if (ETCH_LOCAL_BYTECODE) {
            vm.etch(PAIR,    vm.getDeployedCode("OPair.sol:OPair"));
            vm.etch(FACTORY, vm.getDeployedCode("OPairFactory.sol:OPairFactory"));
        }

        vm.label(PAIR,    "OPair(call_3000_0503)");
        vm.label(FACTORY, "OPairFactory");
        vm.label(BUYER,   "buyer");
        vm.label(0xb91d325703720bA9b5135cE1Cc28cb66E0E51EC3, "sellerFunder");
        vm.label(0x29c0e2fff128fFaE7c22B87938C061D0d8127fC7, "sellerSigner");
    }

    function test_ReproBuyPanic() public {
        assertEq(block.number, FORK_BLOCK, "fork did not attach at expected block");

        vm.prank(BUYER);
        (bool ok, bytes memory ret) = PAIR.call(CALLDATA);
        if (!ok) {
            emit log_named_bytes("revert_data", ret);
        }
        assertTrue(ok, "buy() reverted - see -vvvv trace above");
    }
}
