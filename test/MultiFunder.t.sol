// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Setup} from "./Setup.t.sol";
import {MultiFunder} from "../src/MultiFunder.sol";
import {IMultiFunder} from "../src/interfaces/IMultiFunder.sol";
import {IFunderBase} from "../src/interfaces/IFunderBase.sol";
import {FundingVerifier} from "../src/FundingVerifier.sol";
import {OPair} from "../src/OPair.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract MultiFunderTest is Setup {
    OPair public pair;

    // Separate signer for MultiFunder (not mm, to test per-signer isolation)
    uint256 public signerKey;
    address public signer;

    function setUp() public override {
        super.setUp();
        pair = _createCallPair();
        signerKey = 0xC0DE;
        signer = vm.addr(signerKey);
    }

    // =========================================================================
    // deposit
    // =========================================================================

    function test_deposit_creditsSignerBalance() public {
        usdc.mint(seller, 1000e6);
        vm.startPrank(seller);
        usdc.approve(address(multiFunder), 1000e6);
        multiFunder.deposit(signer, address(usdc), 1000e6);
        vm.stopPrank();

        assertEq(multiFunder.balances(signer, address(usdc)), 1000e6);
        assertEq(usdc.balanceOf(address(multiFunder)), 1000e6);
    }

    function test_deposit_differentSignersIsolated() public {
        address signer2 = makeAddr("signer2");

        usdc.mint(seller, 600e6);
        vm.startPrank(seller);
        usdc.approve(address(multiFunder), 600e6);
        multiFunder.deposit(signer,  address(usdc), 400e6);
        multiFunder.deposit(signer2, address(usdc), 200e6);
        vm.stopPrank();

        assertEq(multiFunder.balances(signer,  address(usdc)), 400e6);
        assertEq(multiFunder.balances(signer2, address(usdc)), 200e6);
    }

    function test_deposit_anyoneCanDepositForAnySigner() public {
        // A third party (not the signer) can deposit on behalf of signer
        usdc.mint(buyer, 300e6);
        vm.startPrank(buyer);
        usdc.approve(address(multiFunder), 300e6);
        multiFunder.deposit(signer, address(usdc), 300e6);
        vm.stopPrank();

        assertEq(multiFunder.balances(signer, address(usdc)), 300e6);
    }

    function test_deposit_emitsEvent() public {
        usdc.mint(seller, 500e6);
        vm.startPrank(seller);
        usdc.approve(address(multiFunder), 500e6);
        vm.expectEmit(true, true, false, true);
        emit IFunderBase.FundsDeposited(signer, address(usdc), 500e6);
        multiFunder.deposit(signer, address(usdc), 500e6);
        vm.stopPrank();
    }

    // =========================================================================
    // withdraw
    // =========================================================================

    function test_withdraw_signerCanWithdraw() public {
        usdc.mint(seller, 1000e6);
        vm.startPrank(seller);
        usdc.approve(address(multiFunder), 1000e6);
        multiFunder.deposit(signer, address(usdc), 1000e6);
        vm.stopPrank();

        vm.prank(signer);
        multiFunder.withdraw(address(usdc), 600e6);

        assertEq(multiFunder.balances(signer, address(usdc)), 400e6);
        assertEq(usdc.balanceOf(signer), 600e6);
    }

    function test_withdraw_revertsInsufficientBalance() public {
        usdc.mint(seller, 100e6);
        vm.startPrank(seller);
        usdc.approve(address(multiFunder), 100e6);
        multiFunder.deposit(signer, address(usdc), 100e6);
        vm.stopPrank();

        vm.prank(signer);
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

        // signer has no balance, signer2 does — signer cannot take it
        vm.prank(signer);
        vm.expectRevert(IMultiFunder.InsufficientBalance.selector);
        multiFunder.withdraw(address(usdc), 1);
    }

    function test_withdraw_emitsEvent() public {
        usdc.mint(signer, 500e6);
        vm.startPrank(signer);
        usdc.approve(address(multiFunder), 500e6);
        multiFunder.deposit(signer, address(usdc), 500e6);

        vm.expectEmit(true, true, false, true);
        emit IMultiFunder.FundsWithdrawn(signer, address(usdc), 500e6);
        multiFunder.withdraw(address(usdc), 500e6);
        vm.stopPrank();
    }

    // =========================================================================
    // requestFunds
    // =========================================================================

    function test_requestFunds_debitsBalance() public {
        uint128 size = 1e18;
        uint128 premium = 100e6;
        uint256 validTill = block.timestamp + 1 hours;

        usdc.mint(seller, premium);
        vm.startPrank(seller);
        usdc.approve(address(multiFunder), premium);
        multiFunder.deposit(signer, address(usdc), premium);
        vm.stopPrank();

        assertEq(multiFunder.balances(signer, address(usdc)), premium);

        uint256 nonce = multiFunder.nonces(signer, address(pair));
        bytes memory sig = _signQuote(address(multiFunder), address(pair), signerKey, size, premium, validTill, nonce);

        vm.prank(address(pair));
        multiFunder.requestFunds(signer, address(usdc), premium, size, premium, validTill, sig);

        assertEq(multiFunder.balances(signer, address(usdc)), 0);
        assertEq(usdc.balanceOf(address(pair)), premium);
    }

    function test_requestFunds_incrementsNonce() public {
        uint128 size = 1e18;
        uint128 premium = 50e6;
        uint256 validTill = block.timestamp + 1 hours;

        usdc.mint(address(multiFunder), premium * 2);
        vm.prank(address(0)); // direct mint bypass; top up balance manually
        // Use deposit to credit the balance properly
        usdc.mint(seller, premium * 2);
        vm.startPrank(seller);
        usdc.approve(address(multiFunder), premium * 2);
        multiFunder.deposit(signer, address(usdc), premium * 2);
        vm.stopPrank();

        bytes memory sig1 = _signQuote(address(multiFunder), address(pair), signerKey, size, premium, validTill, 0);
        vm.prank(address(pair));
        multiFunder.requestFunds(signer, address(usdc), premium, size, premium, validTill, sig1);
        assertEq(multiFunder.nonces(signer, address(pair)), 1);

        bytes memory sig2 = _signQuote(address(multiFunder), address(pair), signerKey, size, premium, validTill, 1);
        vm.prank(address(pair));
        multiFunder.requestFunds(signer, address(usdc), premium, size, premium, validTill, sig2);
        assertEq(multiFunder.nonces(signer, address(pair)), 2);
    }

    function test_requestFunds_revertsInsufficientBalance() public {
        uint128 size = 1e18;
        uint128 premium = 100e6;
        uint256 validTill = block.timestamp + 1 hours;

        // Deposit less than the requested amount
        usdc.mint(seller, premium / 2);
        vm.startPrank(seller);
        usdc.approve(address(multiFunder), premium / 2);
        multiFunder.deposit(signer, address(usdc), premium / 2);
        vm.stopPrank();

        bytes memory sig = _signQuote(address(multiFunder), address(pair), signerKey, size, premium, validTill, 0);

        vm.prank(address(pair));
        vm.expectRevert(IMultiFunder.InsufficientBalance.selector);
        multiFunder.requestFunds(signer, address(usdc), premium, size, premium, validTill, sig);
    }

    function test_requestFunds_revertsNotValidVault() public {
        bytes memory sig = _signQuote(address(multiFunder), address(0xdead), signerKey, 1e18, 100e6, block.timestamp + 1, 0);

        vm.prank(address(0xdead));
        vm.expectRevert(FundingVerifier.NotValidVault.selector);
        multiFunder.requestFunds(signer, address(usdc), 100e6, 1e18, 100e6, block.timestamp + 1, sig);
    }

    function test_requestFunds_revertsInvalidSignature() public {
        uint128 size = 1e18;
        uint128 premium = 100e6;
        uint256 validTill = block.timestamp + 1 hours;

        usdc.mint(seller, premium);
        vm.startPrank(seller);
        usdc.approve(address(multiFunder), premium);
        multiFunder.deposit(signer, address(usdc), premium);
        vm.stopPrank();

        // Sign with wrong key (mmPrivateKey instead of signerKey)
        bytes memory sig = _signQuote(address(multiFunder), address(pair), mmPrivateKey, size, premium, validTill, 0);

        vm.prank(address(pair));
        vm.expectRevert(FundingVerifier.InvalidSignature.selector);
        multiFunder.requestFunds(signer, address(usdc), premium, size, premium, validTill, sig);
    }

    function test_requestFunds_revertsNonceReplay() public {
        uint128 size = 1e18;
        uint128 premium = 50e6;
        uint256 validTill = block.timestamp + 1 hours;

        usdc.mint(seller, premium * 2);
        vm.startPrank(seller);
        usdc.approve(address(multiFunder), premium * 2);
        multiFunder.deposit(signer, address(usdc), premium * 2);
        vm.stopPrank();

        bytes memory sig = _signQuote(address(multiFunder), address(pair), signerKey, size, premium, validTill, 0);
        vm.prank(address(pair));
        multiFunder.requestFunds(signer, address(usdc), premium, size, premium, validTill, sig);

        // Replay: nonce has advanced to 1, so sig (for nonce 0) is now invalid
        vm.prank(address(pair));
        vm.expectRevert(FundingVerifier.InvalidSignature.selector);
        multiFunder.requestFunds(signer, address(usdc), premium, size, premium, validTill, sig);
    }

    function test_requestFunds_emitsEvent() public {
        uint128 size = 1e18;
        uint128 premium = 100e6;
        uint256 validTill = block.timestamp + 1 hours;

        usdc.mint(seller, premium);
        vm.startPrank(seller);
        usdc.approve(address(multiFunder), premium);
        multiFunder.deposit(signer, address(usdc), premium);
        vm.stopPrank();

        bytes memory sig = _signQuote(address(multiFunder), address(pair), signerKey, size, premium, validTill, 0);

        vm.prank(address(pair));
        vm.expectEmit(true, true, true, true);
        emit IFunderBase.FundsRequested(address(pair), signer, address(usdc), premium);
        multiFunder.requestFunds(signer, address(usdc), premium, size, premium, validTill, sig);
    }
}
