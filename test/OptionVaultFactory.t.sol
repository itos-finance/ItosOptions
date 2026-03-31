// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {OPairFactory} from "../src/OPairFactory.sol";
import {OPair} from "../src/OPair.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract OPairFactoryTest is Test {
    OPairFactory public factory;
    MockERC20 public weth;
    MockERC20 public usdc;
    address public admin;
    address public issuer;
    address public stranger;

    uint128 constant STRIKE = 2000e18;
    uint128 constant MIN_DEPOSIT = 0.01e18;
    uint256 EXPIRY;

    string constant ID  = "WETH-USDC-2000";
    string constant SYM = "WETH";

    // Cache roles as constants to avoid consuming vm.prank when used as call arguments.
    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 constant ISSUER_ROLE = keccak256("ISSUER_ROLE");

    function setUp() public {
        admin    = makeAddr("admin");
        issuer   = makeAddr("issuer");
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
        assertEq(address(pair.riskToken()), address(weth));
        assertEq(address(pair.cashToken()), address(usdc));
        assertEq(pair.strike(),             STRIKE);
        assertEq(pair.expiry(),             EXPIRY);
        assertTrue(pair.isCall());
        assertEq(pair.minDepositSize(),     MIN_DEPOSIT);
        assertEq(pair.factory(),            address(factory));
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

    function test_createPair_revertsWithoutIssuerRole() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            stranger,
            ISSUER_ROLE
        ));
        factory.createPair(address(weth), address(usdc), STRIKE, EXPIRY, true, MIN_DEPOSIT, ID, SYM);
    }

    // =========================================================================
    // ISSUER_ROLE
    // =========================================================================

    function test_issuerRole_grantedToDeployer() public view {
        assertTrue(factory.hasRole(ISSUER_ROLE, admin));
    }

    function test_issuerRole_grantedAccountCanCreatePair() public {
        vm.prank(admin);
        factory.grantRole(ISSUER_ROLE, issuer);

        vm.prank(issuer);
        address pairAddr = factory.createPair(address(weth), address(usdc), STRIKE, EXPIRY, true, MIN_DEPOSIT, ID, SYM);
        assertTrue(factory.isPair(pairAddr));
    }

    function test_issuerRole_revokedAccountCannotCreatePair() public {
        vm.startPrank(admin);
        factory.grantRole(ISSUER_ROLE, issuer);
        factory.revokeRole(ISSUER_ROLE, issuer);
        vm.stopPrank();

        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            issuer,
            ISSUER_ROLE
        ));
        factory.createPair(address(weth), address(usdc), STRIKE, EXPIRY, true, MIN_DEPOSIT, ID, SYM);
    }

    function test_issuerRole_onlyAdminCanGrant() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            stranger,
            DEFAULT_ADMIN_ROLE
        ));
        factory.grantRole(ISSUER_ROLE, issuer);
    }

    // =========================================================================
    // DEFAULT_ADMIN_ROLE
    // =========================================================================

    function test_adminRoleGrantedToDeployer() public view {
        assertTrue(factory.hasRole(DEFAULT_ADMIN_ROLE, admin));
    }

    function test_adminRole_canTransferViaGrantAndRevoke() public {
        address newAdmin = makeAddr("newAdmin");

        vm.startPrank(admin);
        factory.grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        factory.revokeRole(DEFAULT_ADMIN_ROLE, admin);
        vm.stopPrank();

        assertFalse(factory.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertTrue(factory.hasRole(DEFAULT_ADMIN_ROLE, newAdmin));

        // New admin can grant roles
        vm.prank(newAdmin);
        factory.grantRole(ISSUER_ROLE, issuer);
        assertTrue(factory.hasRole(ISSUER_ROLE, issuer));
    }
}
