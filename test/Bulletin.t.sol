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

    // pricePerOption helpers: Bulletin stores pricePerOption directly,
    // not the total amount. The digest uses pricePerOption as-is.
    uint128 constant PRICE_PER = 0.1e18; // 0.1 cashToken per risk unit
    uint128 constant SIZE      = 5e18;

    function setUp() public override {
        super.setUp();
        pair = _createCallPair();
    }

    // =========================================================================
    // Signing helper (pricePerOption-based, not amount-based like _signQuote)
    // =========================================================================

    /// @dev Build digest for a Bulletin post (pricePerOption is used directly, not derived).
    function _signBulletinQuote(
        address funderAddr,
        address vaultAddr,
        uint256 signerKey,
        uint128 size,
        uint128 pricePerOption,
        uint256 validTill,
        uint256 nonce
    ) internal view returns (bytes memory) {
        // Bulletin calls _buildDigest(funder, vault, size, pricePerOption, validTill, nonce)
        // which computes pricePerOption = (pricePerOption * 1e18) / size   ← No!
        // Actually _buildDigest takes pricePerOption directly:
        //   structHash = keccak256(abi.encode(TYPEHASH, funder, size, vault, pricePerOption, validTill, nonce))
        // And _recoverSigner calls _buildDigest(funder, vault, uint256(size), uint256(pricePerOption), validTill, nonce)
        // So pricePerOption IS stored directly in the struct hash.
        bytes32 domainTypehash = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
        bytes32 domainSeparator = keccak256(abi.encode(
            domainTypehash,
            keccak256("MonasteryFunder"),
            keccak256("1"),
            block.chainid,
            funderAddr
        ));
        bytes32 quoteTypehash = keccak256(
            "Quote(address funder,uint256 size,address vault,uint256 pricePerOption,uint256 validTillTimestamp,uint256 nonce)"
        );
        bytes32 structHash = keccak256(abi.encode(
            quoteTypehash,
            funderAddr,
            uint256(size),
            vaultAddr,
            uint256(pricePerOption),
            validTill,
            nonce
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    // =========================================================================
    // postBid
    // =========================================================================

    function test_postBid_storesOrder() public {
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, SIZE, PRICE_PER, validTill, 0);

        bulletin.postBid(address(pair), mm, address(funder), PRICE_PER, SIZE, validTill, 0, sig);

        IBulletin.Order memory order = bulletin.getBid(address(pair), mm);
        assertEq(order.funder,             address(funder));
        assertEq(order.signer,             mm);
        assertEq(order.pricePerOption,     PRICE_PER);
        assertEq(order.size,               SIZE);
        assertEq(order.validTillTimestamp, validTill);
        assertEq(order.nonce,              0);
        assertEq(order.signature,          sig);
    }

    function test_postBid_anyoneCanPostValidSignature() public {
        // A third party (not mm) can post mm's valid signature
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, SIZE, PRICE_PER, validTill, 0);

        vm.prank(seller); // seller posts on behalf of mm
        bulletin.postBid(address(pair), mm, address(funder), PRICE_PER, SIZE, validTill, 0, sig);

        IBulletin.Order memory order = bulletin.getBid(address(pair), mm);
        assertEq(order.signer, mm);
    }

    function test_postBid_replacesExistingBid() public {
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig1 = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, SIZE, PRICE_PER, validTill, 0);
        bulletin.postBid(address(pair), mm, address(funder), PRICE_PER, SIZE, validTill, 0, sig1);

        // Post again with different size
        uint128 newSize = SIZE * 2;
        bytes memory sig2 = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, newSize, PRICE_PER, validTill, 0);
        bulletin.postBid(address(pair), mm, address(funder), PRICE_PER, newSize, validTill, 0, sig2);

        IBulletin.Order memory order = bulletin.getBid(address(pair), mm);
        assertEq(order.size, newSize);
    }

    function test_postBid_futureNonce() public {
        // Can post a bid for nonce 5 even though current nonce is 0
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, SIZE, PRICE_PER, validTill, 5);

        bulletin.postBid(address(pair), mm, address(funder), PRICE_PER, SIZE, validTill, 5, sig);

        IBulletin.Order memory order = bulletin.getBid(address(pair), mm);
        assertEq(order.nonce, 5);
    }

    function test_postBid_revertsVaultNotFromFactory() public {
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signBulletinQuote(address(funder), address(0xdead), mmPrivateKey, SIZE, PRICE_PER, validTill, 0);

        vm.expectRevert(IBulletin.VaultNotFromFactory.selector);
        bulletin.postBid(address(0xdead), mm, address(funder), PRICE_PER, SIZE, validTill, 0, sig);
    }

    function test_postBid_revertsInvalidSignature() public {
        uint256 validTill = block.timestamp + 1 hours;
        // Sign with a different key than the declared signer (mm)
        bytes memory badSig = _signBulletinQuote(address(funder), address(pair), 0xDEAD, SIZE, PRICE_PER, validTill, 0);

        vm.expectRevert(FundingVerifier.InvalidSignature.selector);
        bulletin.postBid(address(pair), mm, address(funder), PRICE_PER, SIZE, validTill, 0, badSig);
    }

    function test_postBid_revertsWrongFunderInSig() public {
        // Sig commits to funderAddr=funder, but we claim funderAddr=0xdead
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, SIZE, PRICE_PER, validTill, 0);

        vm.expectRevert(FundingVerifier.InvalidSignature.selector);
        // Pass address(0xdead) as the funder — sig won't match
        bulletin.postBid(address(pair), mm, address(0xdead), PRICE_PER, SIZE, validTill, 0, sig);
    }

    function test_postBid_emitsEvent() public {
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, SIZE, PRICE_PER, validTill, 0);

        vm.expectEmit(true, true, false, false);
        emit IBulletin.BidPosted(address(pair), mm, IBulletin.Order(address(funder), mm, PRICE_PER, SIZE, validTill, 0, sig));
        bulletin.postBid(address(pair), mm, address(funder), PRICE_PER, SIZE, validTill, 0, sig);
    }

    // =========================================================================
    // postOffer
    // =========================================================================

    function test_postOffer_storesOrder() public {
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, SIZE, PRICE_PER, validTill, 0);

        bulletin.postOffer(address(pair), mm, address(funder), PRICE_PER, SIZE, validTill, 0, sig);

        IBulletin.Order memory order = bulletin.getOffer(address(pair), mm);
        assertEq(order.funder,         address(funder));
        assertEq(order.signer,         mm);
        assertEq(order.pricePerOption, PRICE_PER);
        assertEq(order.size,           SIZE);
        assertEq(order.nonce,          0);
    }

    function test_postOffer_anyoneCanPostValidSignature() public {
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, SIZE, PRICE_PER, validTill, 0);

        vm.prank(buyer); // buyer posts mm's offer
        bulletin.postOffer(address(pair), mm, address(funder), PRICE_PER, SIZE, validTill, 0, sig);

        assertEq(bulletin.getOffer(address(pair), mm).signer, mm);
    }

    function test_postOffer_revertsInvalidSignature() public {
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory badSig = _signBulletinQuote(address(funder), address(pair), 0xDEAD, SIZE, PRICE_PER, validTill, 0);

        vm.expectRevert(FundingVerifier.InvalidSignature.selector);
        bulletin.postOffer(address(pair), mm, address(funder), PRICE_PER, SIZE, validTill, 0, badSig);
    }

    function test_postOffer_emitsEvent() public {
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, SIZE, PRICE_PER, validTill, 0);

        vm.expectEmit(true, true, false, false);
        emit IBulletin.OfferPosted(address(pair), mm, IBulletin.Order(address(funder), mm, PRICE_PER, SIZE, validTill, 0, sig));
        bulletin.postOffer(address(pair), mm, address(funder), PRICE_PER, SIZE, validTill, 0, sig);
    }

    // =========================================================================
    // cancelBid
    // =========================================================================

    function test_cancelBid_signerCanCancel() public {
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, SIZE, PRICE_PER, validTill, 0);
        bulletin.postBid(address(pair), mm, address(funder), PRICE_PER, SIZE, validTill, 0, sig);

        vm.prank(mm);
        bulletin.cancelBid(address(pair));

        IBulletin.Order memory order = bulletin.getBid(address(pair), mm);
        assertEq(order.size, 0);
    }

    function test_cancelBid_revertsNoOrder() public {
        vm.prank(mm);
        vm.expectRevert(IBulletin.NoOrderToCancel.selector);
        bulletin.cancelBid(address(pair));
    }

    function test_cancelBid_emitsEvent() public {
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, SIZE, PRICE_PER, validTill, 0);
        bulletin.postBid(address(pair), mm, address(funder), PRICE_PER, SIZE, validTill, 0, sig);

        vm.prank(mm);
        vm.expectEmit(true, true, false, false);
        emit IBulletin.BidCancelled(address(pair), mm);
        bulletin.cancelBid(address(pair));
    }

    function test_cancelBid_onlySignerCanCancelTheirOwnOrder() public {
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, SIZE, PRICE_PER, validTill, 0);
        bulletin.postBid(address(pair), mm, address(funder), PRICE_PER, SIZE, validTill, 0, sig);

        // seller tries to cancel mm's bid — no order exists under seller, so NoOrderToCancel
        vm.prank(seller);
        vm.expectRevert(IBulletin.NoOrderToCancel.selector);
        bulletin.cancelBid(address(pair));
    }

    // =========================================================================
    // cancelOffer
    // =========================================================================

    function test_cancelOffer_signerCanCancel() public {
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, SIZE, PRICE_PER, validTill, 0);
        bulletin.postOffer(address(pair), mm, address(funder), PRICE_PER, SIZE, validTill, 0, sig);

        vm.prank(mm);
        bulletin.cancelOffer(address(pair));

        assertEq(bulletin.getOffer(address(pair), mm).size, 0);
    }

    function test_cancelOffer_revertsNoOrder() public {
        vm.prank(mm);
        vm.expectRevert(IBulletin.NoOrderToCancel.selector);
        bulletin.cancelOffer(address(pair));
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
        bytes memory sig = _signBulletinQuote(address(funder), address(pair), mmPrivateKey, SIZE, PRICE_PER, validTill, 0);
        bulletin.postBid(address(pair), mm, address(funder), PRICE_PER, SIZE, validTill, 0, sig);

        // offer is still empty
        assertEq(bulletin.getOffer(address(pair), mm).size, 0);
        assertEq(bulletin.getBid(address(pair), mm).size, SIZE);
    }
}
