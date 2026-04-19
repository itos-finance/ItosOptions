// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Setup} from "./Setup.t.sol";
import {Bulletin} from "../src/Bulletin.sol";
import {IBulletin} from "../src/interfaces/IBulletin.sol";
import {SigVerifier} from "../src/SigVerifier.sol";
import {OPair} from "../src/OPair.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract BulletinTest is Setup {
    OPair public pair;

    uint128 constant PREMIUM_PER_UNIT = 0.5e18; // premium per unit of size
    int128  constant BID_SIZE = 5e18;   // positive = buy intent
    int128  constant OFFER_SIZE = -5e18; // negative = sell intent

    function setUp() public override {
        super.setUp();
        pair = _createCallPair();
    }

    // =========================================================================
    // Signing helper
    // =========================================================================

    function _signBulletinQuote(
        address funderAddr,
        address vaultAddr,
        uint256 signerKey,
        int128 size,
        uint128 premium,
        uint256 validTill,
        uint256 nonce
    ) internal view returns (bytes memory) {
        bytes32 digest = _buildDigest(funderAddr, vaultAddr, int256(size), uint256(premium), validTill, false, 0, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    // =========================================================================
    // post — bids (positive size)
    // =========================================================================

    function test_post_bid_storesOrder() public {
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, BID_SIZE, PREMIUM_PER_UNIT, validTill, 0);

        bulletin.post(address(pair), mm, address(funder), PREMIUM_PER_UNIT, BID_SIZE, validTill, 0, 0, sig);

        IBulletin.Order memory order = bulletin.getOrder(address(pair), mm, 0, 0);
        assertEq(order.funder,             address(funder));
        assertEq(order.signer,             mm);
        assertEq(order.premiumPerUnit,            PREMIUM_PER_UNIT);
        assertEq(order.size,               BID_SIZE);
        assertEq(order.validTillTimestamp, validTill);
        assertEq(order.nonce,              0);
        assertEq(order.allowPartialFill,   false);
        assertEq(order.signature,          sig);
    }

    function test_post_bid_anyoneCanPostValidSignature() public {
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, BID_SIZE, PREMIUM_PER_UNIT, validTill, 0);

        vm.prank(seller); // third party posts on behalf of mm
        bulletin.post(address(pair), mm, address(funder), PREMIUM_PER_UNIT, BID_SIZE, validTill, 0, 0, sig);

        assertEq(bulletin.getOrder(address(pair), mm, 0, 0).signer, mm);
    }

    function test_post_replacesOrderAtSameNonce() public {
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig1 = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, BID_SIZE, PREMIUM_PER_UNIT, validTill, 0);
        bulletin.post(address(pair), mm, address(funder), PREMIUM_PER_UNIT, BID_SIZE, validTill, 0, 0, sig1);

        // Post a new bid at the same nonce — overwrites
        int128 newSize = BID_SIZE * 2;
        bytes memory sig2 = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, newSize, PREMIUM_PER_UNIT, validTill, 0);
        bulletin.post(address(pair), mm, address(funder), PREMIUM_PER_UNIT, newSize, validTill, 0, 0, sig2);

        assertEq(bulletin.getOrder(address(pair), mm, 0, 0).size, newSize);
    }

    function test_post_futureNonce() public {
        // Can post for nonce 5 even though the current Funder nonce is 0
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, BID_SIZE, PREMIUM_PER_UNIT, validTill, 5);

        bulletin.post(address(pair), mm, address(funder), PREMIUM_PER_UNIT, BID_SIZE, validTill, 0, 5, sig);

        assertEq(bulletin.getOrder(address(pair), mm, 0, 5).nonce, 5);
    }

    // =========================================================================
    // post — offers (negative size)
    // =========================================================================

    function test_post_offer_storesOrder() public {
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, OFFER_SIZE, PREMIUM_PER_UNIT, validTill, 0);

        bulletin.post(address(pair), mm, address(funder), PREMIUM_PER_UNIT, OFFER_SIZE, validTill, 0, 0, sig);

        IBulletin.Order memory order = bulletin.getOrder(address(pair), mm, 0, 0);
        assertEq(order.funder,   address(funder));
        assertEq(order.signer,   mm);
        assertEq(order.premiumPerUnit,  PREMIUM_PER_UNIT);
        assertEq(order.size,     OFFER_SIZE);
        assertEq(order.nonce,    0);
    }

    function test_post_offer_anyoneCanPostValidSignature() public {
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, OFFER_SIZE, PREMIUM_PER_UNIT, validTill, 0);

        vm.prank(buyer); // third party posts mm's offer
        bulletin.post(address(pair), mm, address(funder), PREMIUM_PER_UNIT, OFFER_SIZE, validTill, 0, 0, sig);

        assertEq(bulletin.getOrder(address(pair), mm, 0, 0).signer, mm);
    }

    // =========================================================================
    // Multiple nonces coexist
    // =========================================================================

    function test_post_differentNoncesCoexist() public {
        uint256 validTill = block.timestamp + 1 hours;

        // Bid at nonce 0
        bytes memory bidSig = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, BID_SIZE, PREMIUM_PER_UNIT, validTill, 0);
        bulletin.post(address(pair), mm, address(funder), PREMIUM_PER_UNIT, BID_SIZE, validTill, 0, 0, bidSig);

        // Offer at nonce 1 — stored independently
        bytes memory offerSig = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, OFFER_SIZE, PREMIUM_PER_UNIT, validTill, 1);
        bulletin.post(address(pair), mm, address(funder), PREMIUM_PER_UNIT, OFFER_SIZE, validTill, 0, 1, offerSig);

        assertEq(bulletin.getOrder(address(pair), mm, 0, 0).size, BID_SIZE);
        assertEq(bulletin.getOrder(address(pair), mm, 0, 1).size, OFFER_SIZE);
    }

    // =========================================================================
    // Revert cases
    // =========================================================================

    function test_post_revertsZeroSize() public {
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, 0, PREMIUM_PER_UNIT, validTill, 0);

        vm.expectRevert(IBulletin.ZeroSize.selector);
        bulletin.post(address(pair), mm, address(funder), PREMIUM_PER_UNIT, 0, validTill, 0, 0, sig);
    }

    function test_post_revertsPairNotFromFactory() public {
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signBulletinQuote(address(funder), address(0xdead), mmPrivateKey, BID_SIZE, PREMIUM_PER_UNIT, validTill, 0);

        vm.expectRevert(IBulletin.VaultNotFromFactory.selector);
        bulletin.post(address(0xdead), mm, address(funder), PREMIUM_PER_UNIT, BID_SIZE, validTill, 0, 0, sig);
    }

    function test_post_revertsInvalidSignature() public {
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory badSig = _signBulletinQuote(address(funder), address(pair), 0xDEAD, BID_SIZE, PREMIUM_PER_UNIT, validTill, 0);

        vm.expectRevert(SigVerifier.InvalidSignature.selector);
        bulletin.post(address(pair), mm, address(funder), PREMIUM_PER_UNIT, BID_SIZE, validTill, 0, 0, badSig);
    }

    function test_post_revertsWrongFunderInSig() public {
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, BID_SIZE, PREMIUM_PER_UNIT, validTill, 0);

        vm.expectRevert(SigVerifier.InvalidSignature.selector);
        bulletin.post(address(pair), mm, address(0xdead), PREMIUM_PER_UNIT, BID_SIZE, validTill, 0, 0, sig);
    }

    // =========================================================================
    // Events
    // =========================================================================

    function test_post_emitsOrderPosted_bid() public {
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, BID_SIZE, PREMIUM_PER_UNIT, validTill, 0);

        vm.expectEmit(true, true, false, false);
        emit IBulletin.OrderPosted(address(pair), mm, IBulletin.Order(address(funder), mm, PREMIUM_PER_UNIT, BID_SIZE, validTill, 0, 0, false, sig));
        bulletin.post(address(pair), mm, address(funder), PREMIUM_PER_UNIT, BID_SIZE, validTill, 0, 0, sig);
    }

    function test_post_emitsOrderPosted_offer() public {
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, OFFER_SIZE, PREMIUM_PER_UNIT, validTill, 0);

        vm.expectEmit(true, true, false, false);
        emit IBulletin.OrderPosted(address(pair), mm, IBulletin.Order(address(funder), mm, PREMIUM_PER_UNIT, OFFER_SIZE, validTill, 0, 0, false, sig));
        bulletin.post(address(pair), mm, address(funder), PREMIUM_PER_UNIT, OFFER_SIZE, validTill, 0, 0, sig);
    }

    // =========================================================================
    // getOrder (view)
    // =========================================================================

    function test_getOrder_returnsZeroStructWhenEmpty() public view {
        IBulletin.Order memory order = bulletin.getOrder(address(pair), mm, 0, 0);
        assertEq(order.size,   0);
        assertEq(order.funder, address(0));
    }

    // =========================================================================
    // Channel isolation
    // =========================================================================

    function test_post_differentChannels_storedIndependently() public {
        uint256 validTill = block.timestamp + 1 hours;

        // Post bid on channel 0, nonce 0
        bytes memory sig0 = _signQuote(address(funder), address(pair), mmPrivateKey, int256(BID_SIZE), uint256(PREMIUM_PER_UNIT), validTill, false, 0, 0);
        bulletin.post(address(pair), mm, address(funder), PREMIUM_PER_UNIT, BID_SIZE, validTill, 0, 0, sig0);

        // Post offer on channel 1, nonce 0
        bytes memory sig1 = _signQuote(address(funder), address(pair), mmPrivateKey, int256(OFFER_SIZE), uint256(PREMIUM_PER_UNIT), validTill, false, 1, 0);
        bulletin.post(address(pair), mm, address(funder), PREMIUM_PER_UNIT, OFFER_SIZE, validTill, 1, 0, sig1);

        // Both stored independently
        IBulletin.Order memory orderCh0 = bulletin.getOrder(address(pair), mm, 0, 0);
        IBulletin.Order memory orderCh1 = bulletin.getOrder(address(pair), mm, 1, 0);
        assertEq(orderCh0.size, BID_SIZE);
        assertEq(orderCh0.channel, 0);
        assertEq(orderCh1.size, OFFER_SIZE);
        assertEq(orderCh1.channel, 1);
    }
}
