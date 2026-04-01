// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Setup} from "./Setup.t.sol";
import {MultiFunder} from "../src/MultiFunder.sol";
import {IMultiFunder} from "../src/interfaces/IMultiFunder.sol";
import {IFunderBase} from "../src/interfaces/IFunderBase.sol";
import {FunderBase} from "../src/FunderBase.sol";
import {OPair} from "../src/OPair.sol";

contract MultiFunderTest is Setup {
    OPair public pair;

    function setUp() public override {
        super.setUp();
        pair = _createCallPair();
    }

    // =========================================================================
    // deposit
    // =========================================================================

    function test_deposit_creditsSignerBalance() public {
        usdc.mint(seller, 1000e6);
        vm.startPrank(seller);
        usdc.approve(address(multiFunder), 1000e6);
        multiFunder.deposit(mm, address(usdc), 1000e6);
        vm.stopPrank();

        assertEq(multiFunder.balances(mm, address(usdc)), 1000e6);
        assertEq(usdc.balanceOf(address(multiFunder)), 1000e6);
    }

    function test_deposit_differentSignersIsolated() public {
        address signer2 = makeAddr("signer2");

        usdc.mint(seller, 600e6);
        vm.startPrank(seller);
        usdc.approve(address(multiFunder), 600e6);
        multiFunder.deposit(mm,      address(usdc), 400e6);
        multiFunder.deposit(signer2, address(usdc), 200e6);
        vm.stopPrank();

        assertEq(multiFunder.balances(mm,      address(usdc)), 400e6);
        assertEq(multiFunder.balances(signer2, address(usdc)), 200e6);
    }

    function test_deposit_anyoneCanDepositForAnySigner() public {
        usdc.mint(buyer, 300e6);
        vm.startPrank(buyer);
        usdc.approve(address(multiFunder), 300e6);
        multiFunder.deposit(mm, address(usdc), 300e6);
        vm.stopPrank();

        assertEq(multiFunder.balances(mm, address(usdc)), 300e6);
    }

    function test_deposit_emitsEvent() public {
        usdc.mint(seller, 500e6);
        vm.startPrank(seller);
        usdc.approve(address(multiFunder), 500e6);
        vm.expectEmit(true, true, false, true);
        emit IFunderBase.FundsDeposited(mm, address(usdc), 500e6);
        multiFunder.deposit(mm, address(usdc), 500e6);
        vm.stopPrank();
    }

    // =========================================================================
    // withdraw
    // =========================================================================

    function test_withdraw_signerCanWithdraw() public {
        usdc.mint(seller, 1000e6);
        vm.startPrank(seller);
        usdc.approve(address(multiFunder), 1000e6);
        multiFunder.deposit(mm, address(usdc), 1000e6);
        vm.stopPrank();

        vm.prank(mm);
        multiFunder.withdraw(address(usdc), 600e6);

        assertEq(multiFunder.balances(mm, address(usdc)), 400e6);
        assertEq(usdc.balanceOf(mm), 600e6);
    }

    function test_withdraw_revertsInsufficientBalance() public {
        usdc.mint(seller, 100e6);
        vm.startPrank(seller);
        usdc.approve(address(multiFunder), 100e6);
        multiFunder.deposit(mm, address(usdc), 100e6);
        vm.stopPrank();

        vm.prank(mm);
        vm.expectRevert(IMultiFunder.InsufficientBalance.selector);
        multiFunder.withdraw(address(usdc), 200e6);
    }

    function test_withdraw_cannotWithdrawOtherSignerBalance() public {
        address signer2 = makeAddr("signer2");
        usdc.mint(seller, 100e6);
        vm.startPrank(seller);
        usdc.approve(address(multiFunder), 100e6);
        multiFunder.deposit(signer2, address(usdc), 100e6);
        vm.stopPrank();

        vm.prank(mm);
        vm.expectRevert(IMultiFunder.InsufficientBalance.selector);
        multiFunder.withdraw(address(usdc), 1);
    }

    function test_withdraw_emitsEvent() public {
        usdc.mint(mm, 500e6);
        vm.startPrank(mm);
        usdc.approve(address(multiFunder), 500e6);
        multiFunder.deposit(mm, address(usdc), 500e6);

        vm.expectEmit(true, true, false, true);
        emit IMultiFunder.FundsWithdrawn(mm, address(usdc), 500e6);
        multiFunder.withdraw(address(usdc), 500e6);
        vm.stopPrank();
    }

    // =========================================================================
    // requestFunds
    // =========================================================================

    function test_requestFunds_debitsBalance() public {
        uint128 premium = 100e6;

        usdc.mint(seller, premium);
        vm.startPrank(seller);
        usdc.approve(address(multiFunder), premium);
        multiFunder.deposit(mm, address(usdc), premium);
        vm.stopPrank();

        assertEq(multiFunder.balances(mm, address(usdc)), premium);

        vm.prank(address(pair));
        multiFunder.requestFunds(mm, address(usdc), premium);

        assertEq(multiFunder.balances(mm, address(usdc)), 0);
        assertEq(usdc.balanceOf(address(pair)), premium);
    }

    function test_requestFunds_zeroAcquireAmount_doesNotDebit() public {
        uint128 balance = 100e6;
        usdc.mint(seller, balance);
        vm.startPrank(seller);
        usdc.approve(address(multiFunder), balance);
        multiFunder.deposit(mm, address(usdc), balance);
        vm.stopPrank();

        vm.prank(address(pair));
        multiFunder.requestFunds(mm, address(usdc), 0);

        // Balance unchanged, nothing transferred
        assertEq(multiFunder.balances(mm, address(usdc)), balance);
    }

    function test_requestFunds_revertsInsufficientBalance() public {
        uint128 premium = 100e6;

        usdc.mint(seller, premium / 2);
        vm.startPrank(seller);
        usdc.approve(address(multiFunder), premium / 2);
        multiFunder.deposit(mm, address(usdc), premium / 2);
        vm.stopPrank();

        vm.prank(address(pair));
        vm.expectRevert(IMultiFunder.InsufficientBalance.selector);
        multiFunder.requestFunds(mm, address(usdc), premium);
    }

    function test_requestFunds_revertsNotValidVault() public {
        vm.prank(address(0xdead));
        vm.expectRevert(FunderBase.NotValidVault.selector);
        multiFunder.requestFunds(mm, address(usdc), 100e6);
    }

    function test_requestFunds_emitsEvent() public {
        uint128 premium = 100e6;

        usdc.mint(seller, premium);
        vm.startPrank(seller);
        usdc.approve(address(multiFunder), premium);
        multiFunder.deposit(mm, address(usdc), premium);
        vm.stopPrank();

        vm.prank(address(pair));
        vm.expectEmit(true, true, true, true);
        emit IFunderBase.FundsRequested(address(pair), mm, address(usdc), premium);
        multiFunder.requestFunds(mm, address(usdc), premium);
    }
}
