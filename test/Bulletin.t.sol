// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Setup} from "./Setup.t.sol";
import {Bulletin} from "../src/Bulletin.sol";
import {IBulletin} from "../src/interfaces/IBulletin.sol";
import {FundingVerifier} from "../src/FundingVerifier.sol";
import {OPair} from "../src/OPair.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract BulletinTest is Setup {
    OPair public pair;

    uint128 constant PREMIUM   = 0.5e18; // total premium for the entire size
    int128  constant SIZE      = 5e18;  // positive = buy intent

    function setUp() public override {
        super.setUp();
        pair = _createCallPair();
    }

    // =========================================================================
    // Signing helper — uses _signQuote from Setup which now signs total premium
    // =========================================================================

    /// @dev Convenience wrapper: sign a quote for bulletin posting.
    function _signBulletinQuote(
        address funderAddr,
        address vaultAddr,
        uint256 signerKey,
        int128 size,
        uint128 premium,
        uint256 validTill,
        uint256 nonce
    ) internal view returns (bytes memory) {
        bytes32 digest = _buildDigest(funderAddr, vaultAddr, int256(size), uint256(premium), validTill, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    // =========================================================================
    // postBid
    // =========================================================================

    function test_postBid_storesOrder() public {
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, SIZE, PREMIUM, validTill, 0);

        bulletin.postBid(address(pair), mm, address(funder), PREMIUM, SIZE, validTill, 0, sig);

        IBulletin.Order memory order = bulletin.getBid(address(pair), mm);
        assertEq(order.funder,             address(funder));
        assertEq(order.signer,             mm);
        assertEq(order.premium,     PREMIUM);
        assertEq(order.size,               SIZE);
        assertEq(order.validTillTimestamp, validTill);
        assertEq(order.nonce,              0);
        assertEq(order.signature,          sig);
    }

    function test_postBid_anyoneCanPostValidSignature() public {
        // A third party (not mm) can post mm's valid signature
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, SIZE, PREMIUM, validTill, 0);

        vm.prank(seller); // seller posts on behalf of mm
        bulletin.postBid(address(pair), mm, address(funder), PREMIUM, SIZE, validTill, 0, sig);

        IBulletin.Order memory order = bulletin.getBid(address(pair), mm);
        assertEq(order.signer, mm);
    }

    function test_postBid_replacesExistingBid() public {
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig1 = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, SIZE, PREMIUM, validTill, 0);
        bulletin.postBid(address(pair), mm, address(funder), PREMIUM, SIZE, validTill, 0, sig1);

        // Post again with different size
        int128 newSize = SIZE * 2;
        bytes memory sig2 = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, newSize, PREMIUM, validTill, 0);
        bulletin.postBid(address(pair), mm, address(funder), PREMIUM, newSize, validTill, 0, sig2);

        IBulletin.Order memory order = bulletin.getBid(address(pair), mm);
        assertEq(order.size, newSize);
    }

    function test_postBid_futureNonce() public {
        // Can post a bid for nonce 5 even though current nonce is 0
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, SIZE, PREMIUM, validTill, 5);

        bulletin.postBid(address(pair), mm, address(funder), PREMIUM, SIZE, validTill, 5, sig);

        IBulletin.Order memory order = bulletin.getBid(address(pair), mm);
        assertEq(order.nonce, 5);
    }

    function test_postBid_revertsVaultNotFromFactory() public {
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signBulletinQuote(address(funder), address(0xdead), mmPrivateKey, SIZE, PREMIUM, validTill, 0);

        vm.expectRevert(IBulletin.VaultNotFromFactory.selector);
        bulletin.postBid(address(0xdead), mm, address(funder), PREMIUM, SIZE, validTill, 0, sig);
    }

    function test_postBid_revertsInvalidSignature() public {
        uint256 validTill = block.timestamp + 1 hours;
        // Sign with a different key than the declared signer (mm)
        bytes memory badSig = _signBulletinQuote(address(funder), address(pair), 0xDEAD, SIZE, PREMIUM, validTill, 0);

        vm.expectRevert(FundingVerifier.InvalidSignature.selector);
        bulletin.postBid(address(pair), mm, address(funder), PREMIUM, SIZE, validTill, 0, badSig);
    }

    function test_postBid_revertsWrongFunderInSig() public {
        // Sig commits to funderAddr=funder, but we claim funderAddr=0xdead
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, SIZE, PREMIUM, validTill, 0);

        vm.expectRevert(FundingVerifier.InvalidSignature.selector);
        // Pass address(0xdead) as the funder — sig won't match
        bulletin.postBid(address(pair), mm, address(0xdead), PREMIUM, SIZE, validTill, 0, sig);
    }

    function test_postBid_emitsEvent() public {
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, SIZE, PREMIUM, validTill, 0);

        vm.expectEmit(true, true, false, false);
        emit IBulletin.BidPosted(address(pair), mm, IBulletin.Order(address(funder), mm, PREMIUM, SIZE, validTill, 0, sig));
        bulletin.postBid(address(pair), mm, address(funder), PREMIUM, SIZE, validTill, 0, sig);
    }

    // =========================================================================
    // postOffer
    // =========================================================================

    function test_postOffer_storesOrder() public {
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, SIZE, PREMIUM, validTill, 0);

        bulletin.postOffer(address(pair), mm, address(funder), PREMIUM, SIZE, validTill, 0, sig);

        IBulletin.Order memory order = bulletin.getOffer(address(pair), mm);
        assertEq(order.funder,         address(funder));
        assertEq(order.signer,         mm);
        assertEq(order.premium, PREMIUM);
        assertEq(order.size,           SIZE);
        assertEq(order.nonce,          0);
    }

    function test_postOffer_anyoneCanPostValidSignature() public {
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, SIZE, PREMIUM, validTill, 0);

        vm.prank(buyer); // buyer posts mm's offer
        bulletin.postOffer(address(pair), mm, address(funder), PREMIUM, SIZE, validTill, 0, sig);

        assertEq(bulletin.getOffer(address(pair), mm).signer, mm);
    }

    function test_postOffer_revertsInvalidSignature() public {
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory badSig = _signBulletinQuote(address(funder), address(pair), 0xDEAD, SIZE, PREMIUM, validTill, 0);

        vm.expectRevert(FundingVerifier.InvalidSignature.selector);
        bulletin.postOffer(address(pair), mm, address(funder), PREMIUM, SIZE, validTill, 0, badSig);
    }

    function test_postOffer_emitsEvent() public {
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, SIZE, PREMIUM, validTill, 0);

        vm.expectEmit(true, true, false, false);
        emit IBulletin.OfferPosted(address(pair), mm, IBulletin.Order(address(funder), mm, PREMIUM, SIZE, validTill, 0, sig));
        bulletin.postOffer(address(pair), mm, address(funder), PREMIUM, SIZE, validTill, 0, sig);
    }

    // =========================================================================
    // getBid / getOffer (views)
    // =========================================================================

    function test_getBid_returnsZeroStructWhenEmpty() public view {
        IBulletin.Order memory order = bulletin.getBid(address(pair), mm);
        assertEq(order.size, 0);
        assertEq(order.funder, address(0));
    }

    function test_getOffer_returnsZeroStructWhenEmpty() public view {
        IBulletin.Order memory order = bulletin.getOffer(address(pair), mm);
        assertEq(order.size, 0);
    }

    function test_bidsAndOffersAreIndependent() public {
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, SIZE, PREMIUM, validTill, 0);
        bulletin.postBid(address(pair), mm, address(funder), PREMIUM, SIZE, validTill, 0, sig);

        // offer is still empty
        assertEq(bulletin.getOffer(address(pair), mm).size, 0);
        assertEq(bulletin.getBid(address(pair), mm).size, SIZE);
    }
}
