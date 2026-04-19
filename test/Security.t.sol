// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Setup} from "./Setup.t.sol";
import {OPair} from "../src/OPair.sol";
import {IOPair} from "../src/interfaces/IOPair.sol";
import {Funder} from "../src/Funder.sol";
import {SigVerifier} from "../src/SigVerifier.sol";
import {FunderBase} from "../src/FunderBase.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IExerciseCallback} from "../src/interfaces/IExerciseCallback.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Attack contracts
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Fake funder that does nothing in requestFunds — no token transfer.
contract FakeFunder {
    function requestFunds(address, address, uint256) external {}
}

/// @dev Reentrant callback that tries to re-enter exercise during onExercise.
contract ReentrantExerciseCallback {
    OPair public pair;
    uint128 public reentrantSize;
    bool public attacked;
    IERC20 public swapToken;

    constructor(OPair _pair) {
        pair = _pair;
        swapToken = _pair.swapToken();
    }

    function onExercise(
        address,
        address tokenExpected,
        uint256,
        uint256 amountExpected,
        bytes calldata
    ) external {
        // Pay what's owed first
        IERC20(tokenExpected).transfer(msg.sender, amountExpected);

        // Attempt re-entry
        if (!attacked && reentrantSize > 0) {
            try pair.exercise(reentrantSize, address(this), "") {
                attacked = true;
            } catch {
                // Expected: InsufficientLongPosition (rights already consumed)
            }
        }
    }

    function setReentrantSize(uint128 _size) external { reentrantSize = _size; }
}

/// @dev Funder that redirects requestFunds token transfer to an attacker address.
contract DrainFunder {
    address public attacker;
    IERC20 public token;

    constructor(address _attacker, address _token) {
        attacker = _attacker;
        token    = IERC20(_token);
    }

    function requestFunds(address, address, uint256 acquireAmount) external {
        // Transfer tokens out to attacker instead of msg.sender (the pair)
        token.transfer(attacker, acquireAmount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Security tests
// ─────────────────────────────────────────────────────────────────────────────

contract SecurityTest is Setup {

    // =========================================================================
    // Fake funder — PremiumUnderpaid
    //
    // OPair validates the sig (passes because buyer signed for fakeFunder),
    // then calls fake.requestFunds which does nothing → PremiumUnderpaid.
    // =========================================================================

    function test_fakeFunder_revertsPremiumUnderpaid() public {
        OPair pair = _createCallPair();
        FakeFunder fake = new FakeFunder();

        uint128 size = 1e18;
        uint128 premium = 100e6;
        uint256 validTill = block.timestamp + 1 hours;
        weth.mint(seller, size);
        vm.prank(seller);
        weth.approve(address(pair), size);

        // mm signs for the fake funder — OPair sig check passes, but fake pays nothing
        uint256 nonce = pair.nonces(mm, 0);
        bytes memory sig = _signQuote(address(fake), address(pair), mmPrivateKey, int256(uint256(size)), premium, validTill, true, 0, nonce);

        vm.prank(seller);
        vm.expectRevert(IOPair.PremiumUnderpaid.selector);
        pair.sell(address(fake), mm, size, size, premium, validTill, true, 0, sig);
    }

    // =========================================================================
    // Fake funder on buy — CollateralUnderpaid
    // =========================================================================

    function test_fakeFunder_revertsCollateralUnderpaid() public {
        OPair pair = _createCallPair();
        FakeFunder fake = new FakeFunder();

        uint128 size = 1e18;
        uint128 premium = 100e6;
        uint256 validTill = block.timestamp + 1 hours;
        usdc.mint(buyer, premium);
        vm.prank(buyer);
        usdc.approve(address(pair), premium);

        // mm signs for the fake funder — OPair sig check passes, but fake provides no collateral
        uint256 nonce = pair.nonces(mm, 0);
        bytes memory sig = _signQuote(address(fake), address(pair), mmPrivateKey, -int256(uint256(size)), premium, validTill, true, 0, nonce);

        vm.prank(buyer);
        vm.expectRevert(IOPair.CollateralUnderpaid.selector);
        pair.buy(address(fake), mm, size, size, premium, validTill, true, 0, sig);
    }

    // =========================================================================
    // Drain funder: funds go to wrong address, pair still reverts
    // =========================================================================

    function test_drainFunder_revertsCollateralUnderpaid() public {
        OPair pair = _createCallPair();
        DrainFunder drain = new DrainFunder(makeAddr("attacker"), address(weth));
        weth.mint(address(drain), 1e18);

        uint128 size = 1e18;
        uint128 premium = 100e6;
        uint256 validTill = block.timestamp + 1 hours;
        usdc.mint(buyer, premium);
        vm.prank(buyer);
        usdc.approve(address(pair), premium);

        // mm signs for the drain funder
        uint256 nonce = pair.nonces(mm, 0);
        bytes memory sig = _signQuote(address(drain), address(pair), mmPrivateKey, -int256(uint256(size)), premium, validTill, true, 0, nonce);

        vm.prank(buyer);
        vm.expectRevert(IOPair.CollateralUnderpaid.selector);
        pair.buy(address(drain), mm, size, size, premium, validTill, true, 0, sig);
    }

    // =========================================================================
    // Tampered funder: attacker substitutes a different funder address
    //
    // This is the core attack that the Option B refactor closes. The seller
    // signs for realFunder; the attacker passes fakeFunder. OPair now validates
    // the sig (which commits to funder) before calling requestFunds, so the
    // funder address cannot be swapped.
    // =========================================================================

    function test_tamperedFunder_buy_rejected() public {
        OPair pair = _createCallPair();
        FakeFunder fake = new FakeFunder();

        uint128 size = 1e18;
        uint128 premium = 100e6;
        uint256 validTill = block.timestamp + 1 hours;

        usdc.mint(buyer, premium);
        vm.prank(buyer);
        usdc.approve(address(pair), premium);
        weth.mint(address(funder), size);

        // mm signs committing to address(funder)
        uint256 nonce = pair.nonces(mm, 0);
        bytes memory sig = _signQuote(address(funder), address(pair), mmPrivateKey, -int256(uint256(size)), premium, validTill, true, 0, nonce);

        // Attacker substitutes fake funder — sig is for realFunder, not fake
        vm.prank(buyer);
        vm.expectRevert(SigVerifier.InvalidSignature.selector);
        pair.buy(address(fake), mm, size, size, premium, validTill, true, 0, sig);
    }

    function test_tamperedFunder_sell_rejected() public {
        OPair pair = _createCallPair();
        FakeFunder fake = new FakeFunder();

        uint128 size = 1e18;
        uint128 premium = 100e6;
        uint256 validTill = block.timestamp + 1 hours;

        weth.mint(seller, size);
        vm.prank(seller);
        weth.approve(address(pair), size);

        // mm signs committing to address(funder)
        uint256 nonce = pair.nonces(mm, 0);
        bytes memory sig = _signQuote(address(funder), address(pair), mmPrivateKey, int256(uint256(size)), premium, validTill, true, 0, nonce);

        // Seller substitutes fake funder — rejected
        vm.prank(seller);
        vm.expectRevert(SigVerifier.InvalidSignature.selector);
        pair.sell(address(fake), mm, size, size, premium, validTill, true, 0, sig);
    }

    // =========================================================================
    // Tampered parameters: buyer passes different premium or size than signed
    // =========================================================================

    function test_tamperedPremium_buy_rejected() public {
        OPair pair = _createCallPair();

        uint128 size = 1e18;
        uint128 signedPremium = 200e6;
        uint128 calledPremium = 1e6; // buyer tries to pay less
        uint256 validTill = block.timestamp + 1 hours;

        usdc.mint(buyer, calledPremium);
        vm.prank(buyer);
        usdc.approve(address(pair), calledPremium);
        weth.mint(address(funder), size);

        // mm signs for 200e6
        uint256 nonce = pair.nonces(mm, 0);
        bytes memory sig = _signQuote(address(funder), address(pair), mmPrivateKey, -int256(uint256(size)), signedPremium, validTill, true, 0, nonce);

        // Buyer passes 1e6 instead of 200e6 — digest mismatch
        vm.prank(buyer);
        vm.expectRevert(SigVerifier.InvalidSignature.selector);
        pair.buy(address(funder), mm, size, size, calledPremium, validTill, true, 0, sig);
    }

    function test_tamperedSize_buy_rejected() public {
        OPair pair = _createCallPair();

        uint128 signedSize = 1e18;
        uint128 calledSize = 5e18; // buyer tries to fill more than quoted
        uint128 premium = 100e6;
        uint256 validTill = block.timestamp + 1 hours;

        usdc.mint(buyer, premium);
        vm.prank(buyer);
        usdc.approve(address(pair), premium);
        weth.mint(address(funder), calledSize);

        // mm signs for signedSize=1e18 with premiumPerUnit=100e6
        uint256 nonce = pair.nonces(mm, 0);
        bytes memory sig = _signQuote(address(funder), address(pair), mmPrivateKey, -int256(uint256(signedSize)), premium, validTill, true, 0, nonce);

        // Buyer passes fill=5e18 > size=1e18 — fill exceeds quoted size
        vm.prank(buyer);
        vm.expectRevert(IOPair.FillExceedsQuotedSize.selector);
        pair.buy(address(funder), mm, signedSize, calledSize, premium, validTill, true, 0, sig);
    }

    // =========================================================================
    // Wrong signer: buyer specifies victim as sellerSigner but signature is
    // from attacker — OPair recovers attacker address, not victim → rejected
    // =========================================================================

    function test_wrongSigner_buy_rejected() public {
        OPair pair = _createCallPair();

        uint256 attackerKey = 0xDEAD;
        address victim = mm;

        uint128 size = 1e18;
        uint128 premium = 100e6;
        uint256 validTill = block.timestamp + 1 hours;

        usdc.mint(buyer, premium);
        vm.prank(buyer);
        usdc.approve(address(pair), premium);
        weth.mint(address(funder), size);

        // Attacker signs for themselves but buyer claims victim is the signer
        uint256 nonce = pair.nonces(victim, 0);
        bytes memory sig = _signQuote(address(funder), address(pair), attackerKey, -int256(uint256(size)), premium, validTill, true, 0, nonce);

        vm.prank(buyer);
        vm.expectRevert(SigVerifier.InvalidSignature.selector);
        pair.buy(address(funder), victim, size, size, premium, validTill, true, 0, sig);
    }

    // =========================================================================
    // Signature malleability: OZ ECDSA rejects high-s
    // =========================================================================

    function test_signatureMalleability_rejected() public {
        OPair pair = _createCallPair();
        uint128 size = 1e18;
        uint128 premium = 100e6;
        uint256 validTill = block.timestamp + 1 hours;

        weth.mint(seller, size);
        vm.prank(seller);
        weth.approve(address(pair), size);
        usdc.mint(address(funder), premium);

        // Build a legitimate signature
        bytes32 digest = _buildDigest(address(funder), address(pair), int256(uint256(size)), premium, validTill, true, 0, 0);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(mmPrivateKey, digest);

        // Flip to high-s
        uint256 secp256k1n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 sMalleable = bytes32(secp256k1n - uint256(s));
        uint8   vMalleable = v == 27 ? 28 : 27;
        bytes memory malleableSig = abi.encodePacked(r, sMalleable, vMalleable);

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, sMalleable));
        pair.sell(address(funder), mm, size, size, premium, validTill, true, 0, malleableSig);
    }

    // =========================================================================
    // Cross-vault replay: sig for pair A cannot be used on pair B
    // =========================================================================

    function test_crossVaultReplay_rejected() public {
        OPair pairA = _createCallPair();
        // Create a second pair at a different expiry
        OPair pairB;
        {
            vm.prank(admin);
            pairB = OPair(factory.createPair(
                address(weth), address(usdc), STRIKE, expiryTimestamp + 1 days,
                true, MIN_DEPOSIT, "P2", "P2"
            ));
        }

        uint128 size = 1e18;
        uint128 premium = 100e6;
        uint256 validTill = block.timestamp + 1 hours;

        // Sign for pairA
        bytes memory sigForA = _signQuote(address(funder), address(pairA), mmPrivateKey, int256(uint256(size)), premium, validTill, true, 0, 0);

        // Attempt to use on pairB
        weth.mint(seller, size);
        vm.prank(seller);
        weth.approve(address(pairB), size);
        usdc.mint(address(funder), premium);

        vm.prank(seller);
        vm.expectRevert(SigVerifier.InvalidSignature.selector);
        pairB.sell(address(funder), mm, size, size, premium, validTill, true, 0, sigForA);
    }

    // =========================================================================
    // Cross-funder replay: sig for funderA cannot be used on funderB
    // =========================================================================

    function test_crossFunderReplay_rejected() public {
        OPair pair = _createCallPair();
        uint128 size = 1e18;
        uint128 premium = 100e6;
        uint256 validTill = block.timestamp + 1 hours;

        // Create a second funder
        vm.prank(mm);
        Funder funder2 = new Funder(address(factory));

        // Sign for funder (not funder2)
        bytes memory sigForFunder1 = _signQuote(address(funder), address(pair), mmPrivateKey, int256(uint256(size)), premium, validTill, true, 0, 0);

        // Attempt to use on funder2
        usdc.mint(address(funder2), premium);
        weth.mint(seller, size);
        vm.prank(seller);
        weth.approve(address(pair), size);

        vm.prank(seller);
        vm.expectRevert(SigVerifier.InvalidSignature.selector);
        pair.sell(address(funder2), mm, size, size, premium, validTill, true, 0, sigForFunder1);
    }

    // =========================================================================
    // Nonce replay: used signature cannot be reused
    // =========================================================================

    function test_nonceReplay_rejected() public {
        OPair pair = _createCallPair();
        uint128 size = 1e18;
        uint128 premium = 100e6;
        uint256 validTill = block.timestamp + 1 hours;

        // First sell — consumes nonce 0
        _doSell(pair, seller, size, premium);
        assertEq(pair.nonces(mm, 0), 1);

        // Replay: build the same sig (nonce 0) and try to use it again
        bytes memory replaySig = _signQuote(address(funder), address(pair), mmPrivateKey, int256(uint256(size)), premium, validTill, true, 0, 0);
        weth.mint(seller, size);
        vm.prank(seller);
        weth.approve(address(pair), size);
        usdc.mint(address(funder), premium);

        vm.prank(seller);
        vm.expectRevert(SigVerifier.InvalidSignature.selector);
        pair.sell(address(funder), mm, size, size, premium, validTill, true, 0, replaySig);
    }

    // =========================================================================
    // Non-vault calling requestFunds directly
    // =========================================================================

    function test_nonVault_cannotCallRequestFunds() public {
        usdc.mint(address(funder), 100e6);

        // attacker is not a registered pair
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(FunderBase.NotValidPair.selector);
        funder.requestFunds(mm, address(usdc), 100e6);
    }

    // =========================================================================
    // Unauthorized signer on Funder
    // =========================================================================

    function test_unauthorizedSigner_cannotDrainFunder() public {
        OPair pair = _createCallPair();
        address attacker = makeAddr("attacker");
        usdc.mint(address(funder), 1000e6);

        vm.prank(address(pair));
        bytes32 signerRole = keccak256("SIGNER_ROLE");
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            attacker,
            signerRole
        ));
        funder.requestFunds(attacker, address(usdc), 100e6);
    }

    // =========================================================================
    // CEI: exercise updates state before external callback
    // =========================================================================

    function test_exercise_stateUpdatedBeforeCallback() public {
        OPair pair = _createCallPair();
        _doSell(pair, seller, 2e18, 200e6);

        _fundCallbackForExercise(pair, 2e18);
        vm.warp(pair.exerciseEarliest());
        vm.prank(mm);
        pair.exercise(2e18, address(callback), "");

        assertEq(pair.totalExercised(), 2e18);
        assertEq(pair.exercised(mm), 2e18);
        assertEq(pair.netPosition(mm), 0);
    }

    function test_exercise_reentrancy_cannotDoubleSpendRights() public {
        OPair pair = _createCallPair();
        _doSell(pair, seller, 1e18, 100e6);
        assertEq(pair.netPosition(mm), int256(1e18));

        ReentrantExerciseCallback reentrantCb = new ReentrantExerciseCallback(pair);
        uint256 swapAmt = (uint256(1e18) * STRIKE) / 1e18;
        usdc.mint(address(reentrantCb), swapAmt);
        reentrantCb.setReentrantSize(1e18);

        vm.warp(pair.exerciseEarliest());
        vm.prank(mm);
        pair.exercise(1e18, address(reentrantCb), "");

        // Rights fully consumed; re-entry silently failed
        assertEq(pair.netPosition(mm), 0);
        assertEq(pair.exercised(mm), 1e18);
        assertEq(pair.totalExercised(), 1e18);
        assertFalse(reentrantCb.attacked());
    }

}
