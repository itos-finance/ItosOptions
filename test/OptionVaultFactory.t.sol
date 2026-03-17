// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OPairFactory} from "../src/OPairFactory.sol";
import {OPair} from "../src/OPair.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract OPairFactoryTest is Test {
    OPairFactory public factory;
    MockERC20 public weth;
    MockERC20 public usdc;
    address public admin;
    address public stranger;

    uint128 constant STRIKE = 2000e18;
    uint128 constant MIN_DEPOSIT = 0.01e18;
    uint256 EXPIRY;

    string constant ID  = "WETH-USDC-2000";
    string constant SYM = "WETH";

    function setUp() public {
        admin    = makeAddr("admin");
        stranger = makeAddr("stranger");
        EXPIRY   = block.timestamp + 7 days;

        vm.prank(admin);
        factory = new OPairFactory();

        weth = new MockERC20("WETH", "WETH", 18);
        usdc = new MockERC20("USDC", "USDC", 6);
    }

    // =========================================================================
    // createPair
    // =========================================================================

    function test_createPair_deploysWithCorrectParams() public {
        vm.prank(admin);
        address pairAddr = factory.createPair(address(weth), address(usdc), STRIKE, EXPIRY, true, MIN_DEPOSIT, ID, SYM);

        OPair pair = OPair(pairAddr);
        assertEq(address(pair.riskToken()),    address(weth));
        assertEq(address(pair.cashToken()),    address(usdc));
        assertEq(pair.strike(),        STRIKE);
        assertEq(pair.expiry(),        EXPIRY);
        assertTrue(pair.isCall());
        assertEq(pair.minDepositSize(), MIN_DEPOSIT);
        assertEq(pair.factory(),        address(factory));
    }

    function test_createPair_registeredInIsPair() public {
        vm.prank(admin);
        address pairAddr = factory.createPair(address(weth), address(usdc), STRIKE, EXPIRY, true, MIN_DEPOSIT, ID, SYM);

        assertTrue(factory.isPair(pairAddr));
        assertFalse(factory.isPair(address(0xdead)));
    }

    function test_createPair_isVaultAliasWorks() public {
        vm.prank(admin);
        address pairAddr = factory.createPair(address(weth), address(usdc), STRIKE, EXPIRY, true, MIN_DEPOSIT, ID, SYM);

        assertTrue(factory.isVault(pairAddr));
        assertFalse(factory.isVault(address(0xdead)));
    }

    function test_createPair_storesInPairsMapping() public {
        vm.prank(admin);
        address pairAddr = factory.createPair(address(weth), address(usdc), STRIKE, EXPIRY, true, MIN_DEPOSIT, ID, SYM);

        bytes32 key = keccak256(abi.encode(address(weth), address(usdc), STRIKE, EXPIRY, true));
        assertEq(factory.pairs(key), pairAddr);
    }

    function test_createPair_callAndPutAreDifferentAddresses() public {
        vm.startPrank(admin);
        address callPair = factory.createPair(address(weth), address(usdc), STRIKE, EXPIRY, true,  MIN_DEPOSIT, ID, SYM);
        address putPair  = factory.createPair(address(weth), address(usdc), STRIKE, EXPIRY, false, MIN_DEPOSIT, ID, SYM);
        vm.stopPrank();

        assertTrue(callPair != putPair);
        assertTrue(factory.isPair(callPair));
        assertTrue(factory.isPair(putPair));
    }

    function test_createPair_emitsPairCreated() public {
        vm.prank(admin);
        vm.expectEmit(false, true, true, true);
        emit OPairFactory.PairCreated(address(0), address(weth), address(usdc), STRIKE, EXPIRY, true, MIN_DEPOSIT);
        factory.createPair(address(weth), address(usdc), STRIKE, EXPIRY, true, MIN_DEPOSIT, ID, SYM);
    }

    function test_createPair_revertsZeroRiskToken() public {
        vm.prank(admin);
        vm.expectRevert(OPairFactory.ZeroAddress.selector);
        factory.createPair(address(0), address(usdc), STRIKE, EXPIRY, true, MIN_DEPOSIT, ID, SYM);
    }

    function test_createPair_revertsZeroCashToken() public {
        vm.prank(admin);
        vm.expectRevert(OPairFactory.ZeroAddress.selector);
        factory.createPair(address(weth), address(0), STRIKE, EXPIRY, true, MIN_DEPOSIT, ID, SYM);
    }

    function test_createPair_revertsSameToken() public {
        vm.prank(admin);
        vm.expectRevert(OPairFactory.SameToken.selector);
        factory.createPair(address(weth), address(weth), STRIKE, EXPIRY, true, MIN_DEPOSIT, ID, SYM);
    }

    function test_createPair_revertsExpiryInPast() public {
        vm.prank(admin);
        vm.expectRevert(OPairFactory.ExpiryInPast.selector);
        factory.createPair(address(weth), address(usdc), STRIKE, block.timestamp, true, MIN_DEPOSIT, ID, SYM);
    }

    function test_createPair_revertsDuplicate() public {
        vm.startPrank(admin);
        factory.createPair(address(weth), address(usdc), STRIKE, EXPIRY, true, MIN_DEPOSIT, ID, SYM);

        vm.expectRevert(OPairFactory.PairExists.selector);
        factory.createPair(address(weth), address(usdc), STRIKE, EXPIRY, true, MIN_DEPOSIT, ID, SYM);
        vm.stopPrank();
    }

    function test_createPair_revertsNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.createPair(address(weth), address(usdc), STRIKE, EXPIRY, true, MIN_DEPOSIT, ID, SYM);
    }

    // =========================================================================
    // Ownership (two-step)
    // =========================================================================

    function test_ownerIsDeployer() public view {
        assertEq(factory.owner(), admin);
    }

    function test_twoStepOwnershipTransfer() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(admin);
        factory.transferOwnership(newOwner);
        assertEq(factory.owner(), admin); // still admin until accepted

        vm.prank(newOwner);
        factory.acceptOwnership();
        assertEq(factory.owner(), newOwner);
    }

    function test_pendingOwnerCannotActBeforeAccept() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(admin);
        factory.transferOwnership(newOwner);

        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newOwner));
        factory.createPair(address(weth), address(usdc), STRIKE, EXPIRY, true, MIN_DEPOSIT, ID, SYM);
    }
}
