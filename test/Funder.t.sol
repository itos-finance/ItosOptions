// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Setup} from "./Setup.t.sol";
import {Funder} from "../src/Funder.sol";
import {IFunder} from "../src/interfaces/IFunder.sol";
import {IFunderBase} from "../src/interfaces/IFunderBase.sol";
import {FunderBase} from "../src/FunderBase.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {OPair} from "../src/OPair.sol";

contract FunderTest is Setup {
    OPair public pair;

    // Cache roles as constants to avoid consuming vm.prank when used as arguments.
    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 constant SIGNER_ROLE = keccak256("SIGNER_ROLE");

    function setUp() public override {
        super.setUp();
        pair = _createCallPair();
    }

    // =========================================================================
    // Roles — initial state
    // =========================================================================

    function test_roles_deployerHasAdminRole() public view {
        assertTrue(funder.hasRole(DEFAULT_ADMIN_ROLE, mm));
    }

    function test_roles_deployerHasSignerRole() public view {
        assertTrue(funder.hasRole(SIGNER_ROLE, mm));
    }

    function test_roles_strangerHasNoRoles() public view {
        assertFalse(funder.hasRole(DEFAULT_ADMIN_ROLE, seller));
        assertFalse(funder.hasRole(SIGNER_ROLE, seller));
    }

    // =========================================================================
    // SIGNER_ROLE — grant / revoke
    // =========================================================================

    function test_signerRole_adminCanGrant() public {
        assertFalse(funder.hasRole(SIGNER_ROLE, seller));
        vm.prank(mm);
        funder.grantRole(SIGNER_ROLE, seller);
        assertTrue(funder.hasRole(SIGNER_ROLE, seller));
    }

    function test_signerRole_adminCanRevoke() public {
        vm.prank(mm);
        funder.grantRole(SIGNER_ROLE, seller);

        vm.prank(mm);
        funder.revokeRole(SIGNER_ROLE, seller);
        assertFalse(funder.hasRole(SIGNER_ROLE, seller));
    }

    function test_signerRole_nonAdminCannotGrant() public {
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            seller,
            DEFAULT_ADMIN_ROLE
        ));
        funder.grantRole(SIGNER_ROLE, seller);
    }

    // =========================================================================
    // DEFAULT_ADMIN_ROLE — transfer
    // =========================================================================

    function test_adminRole_canTransferViaGrantAndRevoke() public {
        address newAdmin = makeAddr("newAdmin");
        vm.startPrank(mm);
        funder.grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        funder.revokeRole(DEFAULT_ADMIN_ROLE, mm);
        vm.stopPrank();

        assertFalse(funder.hasRole(DEFAULT_ADMIN_ROLE, mm));
        assertTrue(funder.hasRole(DEFAULT_ADMIN_ROLE, newAdmin));

        // New admin can grant SIGNER_ROLE
        vm.prank(newAdmin);
        funder.grantRole(SIGNER_ROLE, seller);
        assertTrue(funder.hasRole(SIGNER_ROLE, seller));
    }

    // =========================================================================
    // deposit
    // =========================================================================

    function test_deposit_creditsSharedPool() public {
        usdc.mint(seller, 1000e6);
        vm.startPrank(seller);
        usdc.approve(address(funder), 1000e6);
        funder.deposit(seller, address(usdc), 1000e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(funder)), 1000e6);
    }

    function test_deposit_signerParamIgnored() public {
        usdc.mint(seller, 500e6);
        vm.startPrank(seller);
        usdc.approve(address(funder), 500e6);
        funder.deposit(address(0xdead), address(usdc), 500e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(funder)), 500e6);
    }

    function test_deposit_emitsEvent() public {
        usdc.mint(seller, 500e6);
        vm.startPrank(seller);
        usdc.approve(address(funder), 500e6);
        vm.expectEmit(true, true, false, true);
        emit IFunderBase.FundsDeposited(address(0xdead), address(usdc), 500e6);
        funder.deposit(address(0xdead), address(usdc), 500e6);
        vm.stopPrank();
    }

    // =========================================================================
    // setFactory
    // =========================================================================

    function test_setFactory_adminCanUpdate() public {
        address newFactory = makeAddr("newFactory");
        vm.prank(mm);
        funder.setFactory(newFactory);
        assertEq(address(funder.factory()), newFactory);
    }

    function test_setFactory_emitsEvent() public {
        address newFactory = makeAddr("newFactory");
        vm.prank(mm);
        vm.expectEmit(true, false, false, false);
        emit IFunderBase.FactoryUpdated(newFactory);
        funder.setFactory(newFactory);
    }

    function test_setFactory_revertsNonAdmin() public {
        address newFactory = makeAddr("newFactory");
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            seller,
            DEFAULT_ADMIN_ROLE
        ));
        funder.setFactory(newFactory);
    }

    // =========================================================================
    // withdraw
    // =========================================================================

    function test_withdraw_adminCanWithdraw() public {
        usdc.mint(address(funder), 1000e6);

        vm.prank(mm);
        funder.withdraw(address(usdc), 1000e6);
        assertEq(usdc.balanceOf(mm), 1000e6);
    }

    function test_withdraw_revertsNonAdmin() public {
        usdc.mint(address(funder), 1000e6);

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            seller,
            DEFAULT_ADMIN_ROLE
        ));
        funder.withdraw(address(usdc), 1000e6);
    }

    function test_withdraw_emitsEvent() public {
        usdc.mint(address(funder), 1000e6);

        vm.prank(mm);
        vm.expectEmit(true, false, false, true);
        emit IFunder.FundsWithdrawn(address(usdc), 1000e6);
        funder.withdraw(address(usdc), 1000e6);
    }

    // =========================================================================
    // requestFunds
    // =========================================================================

    function test_requestFunds_signerRoleSucceeds() public {
        uint128 premium = 100e6;
        usdc.mint(address(funder), premium);

        vm.prank(address(pair));
        funder.requestFunds(mm, address(usdc), premium);

        assertEq(usdc.balanceOf(address(pair)), premium);
    }

    function test_requestFunds_grantedSignerSucceeds() public {
        uint256 signerKey = 0xB0B;
        address signer = vm.addr(signerKey);

        vm.prank(mm);
        funder.grantRole(SIGNER_ROLE, signer);

        uint128 premium = 50e6;
        usdc.mint(address(funder), premium);

        vm.prank(address(pair));
        funder.requestFunds(signer, address(usdc), premium);

        assertEq(usdc.balanceOf(address(pair)), premium);
    }

    function test_requestFunds_zeroAcquireAmount_doesNotTransfer() public {
        usdc.mint(address(funder), 100e6);

        vm.prank(address(pair));
        funder.requestFunds(mm, address(usdc), 0);

        assertEq(usdc.balanceOf(address(funder)), 100e6);
        assertEq(usdc.balanceOf(address(pair)), 0);
    }

    function test_requestFunds_revertsNotValidPair() public {
        usdc.mint(address(funder), 100e6);

        vm.prank(makeAddr("attacker"));
        vm.expectRevert(FunderBase.NotValidPair.selector);
        funder.requestFunds(mm, address(usdc), 100e6);
    }

    function test_requestFunds_revertsUnauthorizedSigner() public {
        usdc.mint(address(funder), 100e6);

        vm.prank(address(pair));
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            seller,
            SIGNER_ROLE
        ));
        funder.requestFunds(seller, address(usdc), 100e6);
    }

    function test_requestFunds_revokedSignerRejected() public {
        address signer = makeAddr("signer");
        vm.prank(mm);
        funder.grantRole(SIGNER_ROLE, signer);

        vm.prank(mm);
        funder.revokeRole(SIGNER_ROLE, signer);

        usdc.mint(address(funder), 100e6);
        vm.prank(address(pair));
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            signer,
            SIGNER_ROLE
        ));
        funder.requestFunds(signer, address(usdc), 100e6);
    }

    function test_requestFunds_emitsEvent() public {
        uint128 premium = 100e6;
        usdc.mint(address(funder), premium);

        vm.prank(address(pair));
        vm.expectEmit(true, true, true, true);
        emit IFunderBase.FundsRequested(address(pair), mm, address(usdc), premium);
        funder.requestFunds(mm, address(usdc), premium);
    }
}
