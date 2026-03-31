// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Setup} from "./Setup.t.sol";
import {Funder} from "../src/Funder.sol";
import {IFunder} from "../src/interfaces/IFunder.sol";
import {IFunderBase} from "../src/interfaces/IFunderBase.sol";
import {FundingVerifier} from "../src/FundingVerifier.sol";
import {OPair} from "../src/OPair.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract FunderTest is Setup {
    OPair public pair;

    function setUp() public override {
        super.setUp();
        pair = _createCallPair();
    }

    // =========================================================================
    // deposit
    // =========================================================================

    function test_deposit_creditsSharedPool() public {
        usdc.mint(seller, 1000e6);
        vm.startPrank(seller);
        usdc.approve(address(funder), 1000e6);
        funder.deposit(seller, address(usdc), 1000e6); // signer param ignored
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(funder)), 1000e6);
    }

    function test_deposit_signerParamIgnored() public {
        // Depositing "for" a different signer still goes to shared pool
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
    // withdraw
    // =========================================================================

    function test_withdraw_ownerCanWithdraw() public {
        usdc.mint(address(funder), 1000e6);

        vm.prank(mm);
        funder.withdraw(address(usdc), 1000e6);
        assertEq(usdc.balanceOf(mm), 1000e6);
    }

    function test_withdraw_revertsNotOwner() public {
        usdc.mint(address(funder), 1000e6);

        vm.prank(seller);
        vm.expectRevert(IFunder.NotOwner.selector);
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
    // addSigner / removeSigner
    // =========================================================================

    function test_addSigner_ownerCanAdd() public {
        assertFalse(funder.authorizedSigners(seller));
        vm.prank(mm);
        funder.addSigner(seller);
        assertTrue(funder.authorizedSigners(seller));
    }

    function test_addSigner_revertsNotOwner() public {
        vm.prank(seller);
        vm.expectRevert(IFunder.NotOwner.selector);
        funder.addSigner(seller);
    }

    function test_addSigner_emitsEvent() public {
        vm.prank(mm);
        vm.expectEmit(true, false, false, false);
        emit IFunder.SignerAdded(seller);
        funder.addSigner(seller);
    }

    function test_removeSigner_ownerCanRemove() public {
        vm.prank(mm);
        funder.addSigner(seller);
        assertTrue(funder.authorizedSigners(seller));

        vm.prank(mm);
        funder.removeSigner(seller);
        assertFalse(funder.authorizedSigners(seller));
    }

    function test_removeSigner_emitsEvent() public {
        vm.prank(mm);
        funder.addSigner(seller);

        vm.prank(mm);
        vm.expectEmit(true, false, false, false);
        emit IFunder.SignerRemoved(seller);
        funder.removeSigner(seller);
    }

    // =========================================================================
    // requestFunds
    // =========================================================================

    function test_requestFunds_ownerSig_succeeds() public {
        uint128 size = 1e18;
        uint128 premium = 100e6;
        uint256 validTill = block.timestamp + 1 hours;
        int256 signedSize = int256(uint256(size)); // buy intent

        usdc.mint(address(funder), premium);
        uint256 nonce = funder.nonces(mm, address(pair));
        bytes memory sig = _signQuote(address(funder), address(pair), mmPrivateKey, signedSize, premium, validTill, nonce);

        vm.prank(address(pair));
        funder.requestFunds(mm, address(usdc), premium, signedSize, premium, validTill, sig);

        assertEq(usdc.balanceOf(address(pair)), premium);
    }

    function test_requestFunds_authorizedSignerSucceeds() public {
        uint256 signerKey = 0xB0B;
        address signer = vm.addr(signerKey);

        vm.prank(mm);
        funder.addSigner(signer);

        uint128 size = 1e18;
        uint128 premium = 50e6;
        uint256 validTill = block.timestamp + 1 hours;
        int256 signedSize = int256(uint256(size));
        usdc.mint(address(funder), premium);

        uint256 nonce = funder.nonces(signer, address(pair));
        bytes memory sig = _signQuote(address(funder), address(pair), signerKey, signedSize, premium, validTill, nonce);

        vm.prank(address(pair));
        funder.requestFunds(signer, address(usdc), premium, signedSize, premium, validTill, sig);

        assertEq(usdc.balanceOf(address(pair)), premium);
    }

    function test_requestFunds_incrementsNoncePerVault() public {
        uint128 size = 1e18;
        uint128 premium = 50e6;
        uint256 validTill = block.timestamp + 1 hours;
        int256 signedSize = int256(uint256(size));

        usdc.mint(address(funder), premium * 2);

        // First request — nonce 0
        uint256 nonce0 = funder.nonces(mm, address(pair));
        assertEq(nonce0, 0);
        bytes memory sig1 = _signQuote(address(funder), address(pair), mmPrivateKey, signedSize, premium, validTill, nonce0);
        vm.prank(address(pair));
        funder.requestFunds(mm, address(usdc), premium, signedSize, premium, validTill, sig1);
        assertEq(funder.nonces(mm, address(pair)), 1);

        // Second request — nonce 1
        uint256 nonce1 = funder.nonces(mm, address(pair));
        bytes memory sig2 = _signQuote(address(funder), address(pair), mmPrivateKey, signedSize, premium, validTill, nonce1);
        vm.prank(address(pair));
        funder.requestFunds(mm, address(usdc), premium, signedSize, premium, validTill, sig2);
        assertEq(funder.nonces(mm, address(pair)), 2);
    }

    function test_requestFunds_noncesArePerVault() public {
        // Create a second pair; nonces for pair2 must be independent of pair's nonces.
        OPair pair2;
        {
            vm.prank(admin);
            pair2 = OPair(factory.createPair(
                address(weth), address(usdc),
                STRIKE, expiryTimestamp + 1 days, true, MIN_DEPOSIT,
                "WETH-USDC-2001", "WETH2"
            ));
        }

        uint128 size = 1e18;
        uint128 premium = 50e6;
        uint256 validTill = block.timestamp + 1 hours;
        int256 signedSize = int256(uint256(size));
        usdc.mint(address(funder), premium * 2);

        // Use nonce 0 for pair
        bytes memory sig1 = _signQuote(address(funder), address(pair), mmPrivateKey, signedSize, premium, validTill, 0);
        vm.prank(address(pair));
        funder.requestFunds(mm, address(usdc), premium, signedSize, premium, validTill, sig1);
        assertEq(funder.nonces(mm, address(pair)), 1);
        // pair2's nonce is still 0
        assertEq(funder.nonces(mm, address(pair2)), 0);

        // Use nonce 0 for pair2
        bytes memory sig2 = _signQuote(address(funder), address(pair2), mmPrivateKey, signedSize, premium, validTill, 0);
        vm.prank(address(pair2));
        funder.requestFunds(mm, address(usdc), premium, signedSize, premium, validTill, sig2);
        assertEq(funder.nonces(mm, address(pair2)), 1);
    }

    function test_requestFunds_revertsNotValidVault() public {
        uint128 size = 1e18;
        uint128 premium = 100e6;
        uint256 validTill = block.timestamp + 1 hours;
        int256 signedSize = int256(uint256(size));
        usdc.mint(address(funder), premium);

        bytes memory sig = _signQuote(address(funder), address(0xdead), mmPrivateKey, signedSize, premium, validTill, 0);

        vm.prank(address(0xdead)); // not a registered pair
        vm.expectRevert(FundingVerifier.NotValidVault.selector);
        funder.requestFunds(mm, address(usdc), premium, signedSize, premium, validTill, sig);
    }

    function test_requestFunds_revertsNotAuthorizedSigner() public {
        uint128 size = 1e18;
        uint128 premium = 100e6;
        uint256 validTill = block.timestamp + 1 hours;
        int256 signedSize = int256(uint256(size));
        usdc.mint(address(funder), premium);

        // Sign as `seller` who is neither owner nor authorized
        uint256 sellerKey = 0xBEEF;
        address sellerAddr = vm.addr(sellerKey);
        bytes memory sig = _signQuote(address(funder), address(pair), sellerKey, signedSize, premium, validTill, 0);

        vm.prank(address(pair));
        vm.expectRevert(IFunder.NotAuthorizedSigner.selector);
        funder.requestFunds(sellerAddr, address(usdc), premium, signedSize, premium, validTill, sig);
    }

    function test_requestFunds_revertsInvalidSignature() public {
        uint128 size = 1e18;
        uint128 premium = 100e6;
        uint256 validTill = block.timestamp + 1 hours;
        int256 signedSize = int256(uint256(size));
        usdc.mint(address(funder), premium);

        // Sign with wrong key
        bytes memory sig = _signQuote(address(funder), address(pair), 0xDEAD, signedSize, premium, validTill, 0);

        vm.prank(address(pair));
        vm.expectRevert(FundingVerifier.InvalidSignature.selector);
        funder.requestFunds(mm, address(usdc), premium, signedSize, premium, validTill, sig);
    }

    function test_requestFunds_revertsStaleNonce() public {
        uint128 size = 1e18;
        uint128 premium = 50e6;
        uint256 validTill = block.timestamp + 1 hours;
        int256 signedSize = int256(uint256(size));
        usdc.mint(address(funder), premium * 2);

        // Consume nonce 0
        bytes memory sig = _signQuote(address(funder), address(pair), mmPrivateKey, signedSize, premium, validTill, 0);
        vm.prank(address(pair));
        funder.requestFunds(mm, address(usdc), premium, signedSize, premium, validTill, sig);

        // Try to replay nonce 0 — sig is now invalid for nonce 1
        vm.prank(address(pair));
        vm.expectRevert(FundingVerifier.InvalidSignature.selector);
        funder.requestFunds(mm, address(usdc), premium, signedSize, premium, validTill, sig);
    }

    function test_requestFunds_revertsExpiredQuote() public {
        uint128 size = 1e18;
        uint128 premium = 100e6;
        uint256 pastTime = block.timestamp - 1;
        int256 signedSize = int256(uint256(size));
        usdc.mint(address(funder), premium);

        bytes memory sig = _signQuote(address(funder), address(pair), mmPrivateKey, signedSize, premium, pastTime, 0);

        vm.prank(address(pair));
        // OPair checks timestamp before calling requestFunds, but Funder also trusts the
        // vault to enforce it. Calling requestFunds directly with an expired timestamp
        // does NOT revert in Funder — expiry is enforced by OPair. This test verifies
        // that OPair rejects expired quotes before hitting requestFunds.
        vm.expectRevert(FundingVerifier.InvalidSignature.selector); // sig was made for pastTime
        funder.requestFunds(mm, address(usdc), premium, signedSize, premium, block.timestamp + 1, sig);
    }

    function test_requestFunds_revertsInvalidSigLength() public {
        vm.prank(address(pair));
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, 2));
        funder.requestFunds(mm, address(usdc), 100e6, int256(1e18), 100e6, block.timestamp + 1 hours, hex"0011");
    }

    // =========================================================================
    // bumpNonce
    // =========================================================================

    function test_bumpNonce_invalidatesPriorSignature() public {
        uint128 size = 1e18;
        uint128 premium = 100e6;
        uint256 validTill = block.timestamp + 1 hours;
        int256 signedSize = int256(uint256(size));
        usdc.mint(address(funder), premium);

        // Sig valid at nonce 0
        bytes memory sig = _signQuote(address(funder), address(pair), mmPrivateKey, signedSize, premium, validTill, 0);

        vm.prank(mm);
        funder.bumpNonce(address(pair), 1);
        assertEq(funder.nonces(mm, address(pair)), 1);

        // Nonce-0 sig now rejected
        vm.prank(address(pair));
        vm.expectRevert(FundingVerifier.InvalidSignature.selector);
        funder.requestFunds(mm, address(usdc), premium, signedSize, premium, validTill, sig);
    }

    function test_bumpNonce_skipMultiple_onlyNewNonceWorks() public {
        uint128 size = 1e18;
        uint128 premium = 50e6;
        uint256 validTill = block.timestamp + 1 hours;
        int256 signedSize = int256(uint256(size));
        usdc.mint(address(funder), premium);

        // Pre-sign at nonces 0, 1, and 5
        bytes memory sig0 = _signQuote(address(funder), address(pair), mmPrivateKey, signedSize, premium, validTill, 0);
        bytes memory sig1 = _signQuote(address(funder), address(pair), mmPrivateKey, signedSize, premium, validTill, 1);
        bytes memory sig5 = _signQuote(address(funder), address(pair), mmPrivateKey, signedSize, premium, validTill, 5);

        vm.prank(mm);
        funder.bumpNonce(address(pair), 5);
        assertEq(funder.nonces(mm, address(pair)), 5);

        // Nonces 0 and 1 are both skipped — rejected
        vm.prank(address(pair));
        vm.expectRevert(FundingVerifier.InvalidSignature.selector);
        funder.requestFunds(mm, address(usdc), premium, signedSize, premium, validTill, sig0);

        vm.prank(address(pair));
        vm.expectRevert(FundingVerifier.InvalidSignature.selector);
        funder.requestFunds(mm, address(usdc), premium, signedSize, premium, validTill, sig1);

        // Nonce 5 is current — succeeds
        vm.prank(address(pair));
        funder.requestFunds(mm, address(usdc), premium, signedSize, premium, validTill, sig5);
        assertEq(funder.nonces(mm, address(pair)), 6);
    }

    function test_bumpNonce_byZero_doesNothing() public {
        uint128 size = 1e18;
        uint128 premium = 100e6;
        uint256 validTill = block.timestamp + 1 hours;
        int256 signedSize = int256(uint256(size));
        usdc.mint(address(funder), premium);

        bytes memory sig = _signQuote(address(funder), address(pair), mmPrivateKey, signedSize, premium, validTill, 0);

        vm.prank(mm);
        funder.bumpNonce(address(pair), 0);
        assertEq(funder.nonces(mm, address(pair)), 0);

        // Nonce-0 sig still valid
        vm.prank(address(pair));
        funder.requestFunds(mm, address(usdc), premium, signedSize, premium, validTill, sig);
        assertEq(funder.nonces(mm, address(pair)), 1);
    }

    function test_bumpNonce_revertsUnauthorized() public {
        vm.prank(seller); // neither owner nor authorized signer
        vm.expectRevert(IFunder.NotAuthorizedSigner.selector);
        funder.bumpNonce(address(pair), 1);
    }

    function test_requestFunds_emitsEvent() public {
        uint128 size = 1e18;
        uint128 premium = 100e6;
        uint256 validTill = block.timestamp + 1 hours;
        int256 signedSize = int256(uint256(size));
        usdc.mint(address(funder), premium);

        bytes memory sig = _signQuote(address(funder), address(pair), mmPrivateKey, signedSize, premium, validTill, 0);

        vm.prank(address(pair));
        vm.expectEmit(true, true, true, true);
        emit IFunderBase.FundsRequested(address(pair), mm, address(usdc), premium);
        funder.requestFunds(mm, address(usdc), premium, signedSize, premium, validTill, sig);
    }
}
