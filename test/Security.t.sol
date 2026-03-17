// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Setup} from "./Setup.t.sol";
import {OPair} from "../src/OPair.sol";
import {OPairFactory} from "../src/OPairFactory.sol";
import {Funder} from "../src/Funder.sol";
import {FundingVerifier} from "../src/FundingVerifier.sol";
import {IFunder} from "../src/interfaces/IFunder.sol";
import {IFunderBase} from "../src/interfaces/IFunderBase.sol";
import {IExerciseCallback} from "../src/interfaces/IExerciseCallback.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Attack contracts
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Fake funder that does nothing in requestFunds — no token transfer.
contract FakeFunder {
    function requestFunds(address, address, uint256, uint256, uint256, uint256, bytes calldata) external {}
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

    function requestFunds(address, address, uint256, uint256, uint256 acquireAmount, uint256, bytes calldata) external {
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
    // =========================================================================

    function test_fakeFunder_revertsPremiumUnderpaid() public {
        OPair pair = _createCallPair();
        FakeFunder fake = new FakeFunder();

        uint128 size = 1e18;
        uint128 premium = 100e6;
        weth.mint(seller, size);
        vm.prank(seller);
        weth.approve(address(pair), size);

        bytes memory sig = hex"00"; // fake funder ignores it

        vm.prank(seller);
        vm.expectRevert(OPair.PremiumUnderpaid.selector);
        pair.sell(address(fake), mm, size, premium, block.timestamp + 1 hours, sig);
    }

    // =========================================================================
    // Fake funder on buy — CollateralUnderpaid
    // =========================================================================

    function test_fakeFunder_revertsCollateralUnderpaid() public {
        OPair pair = _createCallPair();
        FakeFunder fake = new FakeFunder();

        uint128 size = 1e18;
        uint128 premium = 100e6;
        usdc.mint(buyer, premium);
        vm.prank(buyer);
        usdc.approve(address(pair), premium);

        vm.prank(buyer);
        vm.expectRevert(OPair.CollateralUnderpaid.selector);
        pair.buy(address(fake), mm, size, premium, block.timestamp + 1 hours, hex"00");
    }

    // =========================================================================
    // Drain funder: funds go to wrong address, pair still reverts
    // =========================================================================

    function test_drainFunder_revertsCollateralUnderpaid() public {
        OPair pair = _createCallPair();
        DrainFunder drain = new DrainFunder(makeAddr("attacker"), address(weth));
        weth.mint(address(drain), 1e18);

        usdc.mint(buyer, 100e6);
        vm.prank(buyer);
        usdc.approve(address(pair), 100e6);

        vm.prank(buyer);
        vm.expectRevert(OPair.CollateralUnderpaid.selector);
        pair.buy(address(drain), mm, 1e18, 100e6, block.timestamp + 1 hours, hex"00");
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
        bytes32 digest = _buildDigest(address(funder), address(pair), size, premium, validTill, 0);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(mmPrivateKey, digest);

        // Flip to high-s
        uint256 secp256k1n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 sMalleable = bytes32(secp256k1n - uint256(s));
        uint8   vMalleable = v == 27 ? 28 : 27;
        bytes memory malleableSig = abi.encodePacked(r, sMalleable, vMalleable);

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, sMalleable));
        pair.sell(address(funder), mm, size, premium, validTill, malleableSig);
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
        bytes memory sigForA = _signQuote(address(funder), address(pairA), mmPrivateKey, size, premium, validTill, 0);

        // Attempt to use on pairB
        weth.mint(seller, size);
        vm.prank(seller);
        weth.approve(address(pairB), size);
        usdc.mint(address(funder), premium);

        vm.prank(seller);
        vm.expectRevert(FundingVerifier.InvalidSignature.selector);
        pairB.sell(address(funder), mm, size, premium, validTill, sigForA);
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
        bytes memory sigForFunder1 = _signQuote(address(funder), address(pair), mmPrivateKey, size, premium, validTill, 0);

        // Attempt to use on funder2
        usdc.mint(address(funder2), premium);
        weth.mint(seller, size);
        vm.prank(seller);
        weth.approve(address(pair), size);

        vm.prank(seller);
        vm.expectRevert(FundingVerifier.InvalidSignature.selector);
        pair.sell(address(funder2), mm, size, premium, validTill, sigForFunder1);
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
        assertEq(funder.nonces(mm, address(pair)), 1);

        // Replay: build the same sig (nonce 0) and try to use it again
        bytes memory replaySig = _signQuote(address(funder), address(pair), mmPrivateKey, size, premium, validTill, 0);
        weth.mint(seller, size);
        vm.prank(seller);
        weth.approve(address(pair), size);
        usdc.mint(address(funder), premium);

        vm.prank(seller);
        vm.expectRevert(FundingVerifier.InvalidSignature.selector);
        pair.sell(address(funder), mm, size, premium, validTill, replaySig);
    }

    // =========================================================================
    // Non-vault calling requestFunds directly
    // =========================================================================

    function test_nonVault_cannotCallRequestFunds() public {
        OPair pair = _createCallPair();
        usdc.mint(address(funder), 100e6);
        bytes memory sig = _signQuote(address(funder), address(pair), mmPrivateKey, 1e18, 100e6, block.timestamp + 1, 0);

        // attacker is not a registered pair
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(FundingVerifier.NotValidVault.selector);
        funder.requestFunds(mm, address(usdc), 100e6, 1e18, 100e6, block.timestamp + 1, sig);
    }

    // =========================================================================
    // Unauthorized signer on Funder
    // =========================================================================

    function test_unauthorizedSigner_cannotDrainFunder() public {
        OPair pair = _createCallPair();
        uint256 attackerKey = 0xDEAD;
        address attacker = vm.addr(attackerKey);

        usdc.mint(address(funder), 1000e6);
        bytes memory sig = _signQuote(address(funder), address(pair), attackerKey, 1e18, 100e6, block.timestamp + 1, 0);

        vm.prank(address(pair));
        vm.expectRevert(IFunder.NotAuthorizedSigner.selector);
        funder.requestFunds(attacker, address(usdc), 100e6, 1e18, 100e6, block.timestamp + 1, sig);
    }

    // =========================================================================
    // CEI: exercise updates state before external callback
    // =========================================================================

    function test_exercise_stateUpdatedBeforeCallback() public {
        OPair pair = _createCallPair();
        _doSell(pair, seller, 2e18, 200e6);

        _fundCallbackForExercise(pair, 2e18);
        vm.prank(mm);
        pair.exercise(2e18, address(callback), "");

        assertEq(pair.totalExercised(), 2e18);
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

        vm.prank(mm);
        pair.exercise(1e18, address(reentrantCb), "");

        // Rights fully consumed; re-entry silently failed
        assertEq(pair.netPosition(mm), 0);
        assertEq(pair.totalExercised(), 1e18);
        assertFalse(reentrantCb.attacked());
    }

    // =========================================================================
    // Factory input validation
    // =========================================================================

    function test_factory_revertsZeroRiskToken() public {
        vm.prank(admin);
        vm.expectRevert(OPairFactory.ZeroAddress.selector);
        factory.createPair(address(0), address(usdc), STRIKE, expiryTimestamp, true, MIN_DEPOSIT, "X", "X");
    }

    function test_factory_revertsZeroCashToken() public {
        vm.prank(admin);
        vm.expectRevert(OPairFactory.ZeroAddress.selector);
        factory.createPair(address(weth), address(0), STRIKE, expiryTimestamp, true, MIN_DEPOSIT, "X", "X");
    }

    function test_factory_revertsSameToken() public {
        vm.prank(admin);
        vm.expectRevert(OPairFactory.SameToken.selector);
        factory.createPair(address(weth), address(weth), STRIKE, expiryTimestamp, true, MIN_DEPOSIT, "X", "X");
    }

    function test_factory_revertsExpiryInPast() public {
        vm.prank(admin);
        vm.expectRevert(OPairFactory.ExpiryInPast.selector);
        factory.createPair(address(weth), address(usdc), STRIKE, block.timestamp, true, MIN_DEPOSIT, "X", "X");
    }

    // =========================================================================
    // Min deposit enforcement
    // =========================================================================

    function test_sell_revertsIfBelowMinDeposit() public {
        OPair pair = _createCallPair();
        uint128 tinySize = MIN_DEPOSIT - 1;

        weth.mint(seller, tinySize);
        vm.prank(seller);
        weth.approve(address(pair), tinySize);
        usdc.mint(address(funder), 1);

        bytes memory sig = _signQuote(address(funder), address(pair), mmPrivateKey, tinySize, 1, block.timestamp + 1, 0);
        vm.prank(seller);
        vm.expectRevert(OPair.BelowMinDeposit.selector);
        pair.sell(address(funder), mm, tinySize, 1, block.timestamp + 1, sig);
    }

    function test_sell_exactlyMinDeposit_succeeds() public {
        OPair pair = _createCallPair();
        uint128 size = MIN_DEPOSIT;

        weth.mint(seller, size);
        vm.prank(seller);
        weth.approve(address(pair), size);
        usdc.mint(address(funder), 1);

        bytes memory sig = _signQuote(address(funder), address(pair), mmPrivateKey, size, 1, block.timestamp + 1, 0);
        vm.prank(seller);
        pair.sell(address(funder), mm, size, 1, block.timestamp + 1, sig);
        assertEq(pair.totalSold(), size);
    }

    // =========================================================================
    // Quote expiry enforced by OPair
    // =========================================================================

    function test_sell_revertsExpiredQuote() public {
        OPair pair = _createCallPair();
        uint256 pastTime = block.timestamp - 1;

        weth.mint(seller, 1e18);
        vm.prank(seller);
        weth.approve(address(pair), 1e18);
        usdc.mint(address(funder), 100e6);

        bytes memory sig = _signQuote(address(funder), address(pair), mmPrivateKey, 1e18, 100e6, pastTime, 0);
        vm.prank(seller);
        vm.expectRevert(OPair.QuoteExpired.selector);
        pair.sell(address(funder), mm, 1e18, 100e6, pastTime, sig);
    }

    // =========================================================================
    // Withdrawal access control on Funder
    // =========================================================================

    function test_funder_withdrawOnlyOwner() public {
        usdc.mint(address(funder), 1000e6);

        vm.prank(seller); // not owner
        vm.expectRevert(IFunder.NotOwner.selector);
        funder.withdraw(address(usdc), 1000e6);

        vm.prank(mm); // owner
        funder.withdraw(address(usdc), 1000e6);
        assertEq(usdc.balanceOf(mm), 1000e6);
    }

    // =========================================================================
    // extendExpiry: only factory owner can extend; cannot shorten
    // =========================================================================

    function test_extendExpiry_revertsNonFactoryOwner() public {
        OPair pair = _createCallPair();
        vm.prank(seller);
        vm.expectRevert(OPair.NotFactoryOwner.selector);
        pair.extendExpiry(expiryTimestamp + 1 days);
    }

    function test_extendExpiry_cannotShortenExpiry() public {
        OPair pair = _createCallPair();
        vm.prank(admin);
        vm.expectRevert(OPair.NewExpiryNotLater.selector);
        pair.extendExpiry(expiryTimestamp - 1);
    }

    // =========================================================================
    // Bulletin: posting invalid or mismatched signatures is rejected
    // =========================================================================

    function test_bulletin_rejectsBadSig() public {
        OPair pair = _createCallPair();
        uint256 validTill = block.timestamp + 1 hours;
        // Sign with wrong key
        uint256 wrongKey = 0xBAD;
        bytes32 ds = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("MonasteryFunder"), keccak256("1"), block.chainid, address(funder)
        ));
        bytes32 sh = keccak256(abi.encode(
            keccak256("Quote(address funder,uint256 size,address vault,uint256 pricePerOption,uint256 validTillTimestamp,uint256 nonce)"),
            address(funder), uint256(1e18), address(pair), uint256(0.1e18), validTill, uint256(0)
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", ds, sh));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);
        bytes memory badSig = abi.encodePacked(r, s, v);

        vm.expectRevert(FundingVerifier.InvalidSignature.selector);
        bulletin.postBid(address(pair), mm, address(funder), 0.1e18, 1e18, validTill, 0, badSig);
    }

    function test_bulletin_rejectsUnregisteredVault() public {
        bytes memory sig = hex"00";
        vm.expectRevert();
        bulletin.postBid(address(0xdead), mm, address(funder), 100, 1e18, block.timestamp + 1, 0, sig);
    }
}
