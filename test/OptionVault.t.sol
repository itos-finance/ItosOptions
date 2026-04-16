// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Setup} from "./Setup.t.sol";
import {OPair} from "../src/OPair.sol";
import {IOPair} from "../src/interfaces/IOPair.sol";
import {SigVerifier} from "../src/SigVerifier.sol";
import {Funder} from "../src/Funder.sol";

contract OPairTest is Setup {
    OPair public pair;

    // Cache role constant to avoid consuming vm.prank when passed as argument.
    bytes32 constant SIGNER_ROLE = keccak256("SIGNER_ROLE");

    function setUp() public override {
        super.setUp();
        pair = _createCallPair();
    }

    // @dev `other` (as buyer) buys `size` from mm (as seller via the shared funder).
    function _buyAsOther(address _other, uint128 size, uint128 premium) internal {
        usdc.mint(_other, premium);
        vm.prank(_other);
        usdc.approve(address(pair), premium);
        weth.mint(address(funder), size);

        uint256 nonce = pair.nonces(mm, 0);
        uint256 validTill = block.timestamp + 1 hours;
        uint128 premiumPerUnit = uint128(uint256(premium) * 1e18 / uint256(size));
        bytes memory sig = _signQuote(
            address(funder), address(pair), mmPrivateKey,
            -int256(uint256(size)), premiumPerUnit, validTill, true, 0, nonce
        );
        vm.prank(_other);
        pair.buy(address(funder), mm, size, size, premiumPerUnit, validTill, true, 0, sig);
    }

    // =========================================================================
    // sell
    // =========================================================================

    function test_sell_shortPositionCreated() public {
        _doSell(pair, seller, 1e18, 100e6);
        assertEq(pair.totalSold(), 1e18);
        // seller has short: netPosition = -1e18
        assertEq(pair.netPosition(seller), -int256(1e18));
        // mm has long: netPosition = +1e18
        assertEq(pair.netPosition(mm), int256(1e18));
    }

    function test_sell_sellerReceivesPremiumMinusFee() public {
        uint128 size = 1e18;
        uint128 premium = 100e6;
        _doSell(pair, seller, size, premium);

        uint256 fee = (uint256(premium) * pair.FEE_BPS()) / pair.BPS();
        assertEq(usdc.balanceOf(seller), premium - fee);
        assertEq(pair.totalFees(), fee);
    }

    function test_sell_revertsAfterDepositDeadline() public {
        vm.warp(pair.depositDeadline());

        uint256 depositAmt = 1e18;
        weth.mint(seller, depositAmt);
        vm.prank(seller);
        weth.approve(address(pair), depositAmt);
        usdc.mint(address(funder), 100e6);

        bytes memory sig = _signQuote(
            address(funder),
            address(pair),
            mmPrivateKey,
            int256(1e18),
            100e6,
            expiryTimestamp + 1,
            true,
            0,
            0
        );

        vm.prank(seller);
        vm.expectRevert(IOPair.DepositWindowClosed.selector);
        pair.sell(address(funder), mm, 1e18, 1e18, 100e6, expiryTimestamp + 1, true, 0, sig);
    }

    function test_sell_revertsExpiredQuote() public {
        uint256 pastTime = block.timestamp - 1;
        weth.mint(seller, 1e18);
        vm.prank(seller);
        weth.approve(address(pair), 1e18);
        usdc.mint(address(funder), 100e6);

        bytes memory sig = _signQuote(
            address(funder),
            address(pair),
            mmPrivateKey,
            int256(1e18),
            100e6,
            pastTime,
            true,
            0,
            0
        );

        vm.prank(seller);
        vm.expectRevert(IOPair.QuoteExpired.selector);
        pair.sell(address(funder), mm, 1e18, 1e18, 100e6, pastTime, true, 0, sig);
    }

    function test_sell_revertsZeroSize() public {
        vm.prank(seller);
        vm.expectRevert(IOPair.ZeroSize.selector);
        pair.sell(address(funder), mm, 0, 0, 100e6, block.timestamp + 1, true, 0, hex"");
    }

    function test_sell_revertsBelowMinDeposit() public {
        uint128 tinySize = MIN_DEPOSIT - 1;
        weth.mint(seller, tinySize);
        vm.prank(seller);
        weth.approve(address(pair), tinySize);
        usdc.mint(address(funder), 1e6);

        bytes memory sig = _signQuote(
            address(funder),
            address(pair),
            mmPrivateKey,
            int256(uint256(tinySize)),
            1e6,
            block.timestamp + 1,
            true,
            0,
            0
        );

        vm.prank(seller);
        vm.expectRevert(IOPair.BelowMinDeposit.selector);
        pair.sell(address(funder), mm, tinySize, tinySize, 1e6, block.timestamp + 1, true, 0, sig);
    }

    function test_sell_exactlyMinDeposit_succeeds() public {
        uint128 size = MIN_DEPOSIT;
        weth.mint(seller, size);
        vm.prank(seller);
        weth.approve(address(pair), size);
        usdc.mint(address(funder), 1);

        bytes memory sig = _signQuote(address(funder), address(pair), mmPrivateKey, int256(uint256(size)), 1, block.timestamp + 1, true, 0, 0);
        vm.prank(seller);
        pair.sell(address(funder), mm, size, size, 1, block.timestamp + 1, true, 0, sig);
        assertEq(pair.totalSold(), size);
    }

    function test_sell_emitsSold() public {
        uint128 size = 1e18;
        uint128 premium = 100e6;
        uint256 validTill = block.timestamp + 1 hours;

        weth.mint(seller, size);
        vm.prank(seller);
        weth.approve(address(pair), size);
        usdc.mint(address(funder), premium);

        bytes memory sig = _signQuote(
            address(funder),
            address(pair),
            mmPrivateKey,
            int256(uint256(size)),
            premium,
            validTill,
            true,
            0,
            0
        );

        vm.prank(seller);
        vm.expectEmit(true, true, false, true);
        emit IOPair.Sold(seller, mm, size, premium, 0, 0);
        pair.sell(address(funder), mm, size, size, premium, validTill, true, 0, sig);
    }

    function test_sell_partialFill_succeeds_whenAllowed() public {
        uint128 size = 2e18;
        uint128 fill = 1e18;
        uint128 premiumPerUnit = 100e6; // 100 USDC per 1e18 units
        uint256 validTill = block.timestamp + 1 hours;

        weth.mint(seller, fill);
        vm.prank(seller);
        weth.approve(address(pair), fill);
        usdc.mint(address(funder), premiumPerUnit); // 100e6 * 1e18 / 1e18 = 100e6

        bytes memory sig = _signQuote(address(funder), address(pair), mmPrivateKey, int256(uint256(size)), premiumPerUnit, validTill, true, 0, 0);
        vm.prank(seller);
        pair.sell(address(funder), mm, size, fill, premiumPerUnit, validTill, true, 0, sig);

        assertEq(pair.totalSold(), fill);
        assertEq(pair.netPosition(seller), -int256(uint256(fill)));
        assertEq(pair.netPosition(mm), int256(uint256(fill)));
    }

    function test_sell_partialFill_reverts_whenNotAllowed() public {
        uint128 size = 2e18;
        uint128 fill = 1e18;
        uint128 premiumPerUnit = 100e6;
        uint256 validTill = block.timestamp + 1 hours;

        weth.mint(seller, fill);
        vm.prank(seller);
        weth.approve(address(pair), fill);
        usdc.mint(address(funder), premiumPerUnit);

        bytes memory sig = _signQuote(address(funder), address(pair), mmPrivateKey, int256(uint256(size)), premiumPerUnit, validTill, false, 0, 0);
        vm.prank(seller);
        vm.expectRevert(IOPair.PartialFillNotAllowed.selector);
        pair.sell(address(funder), mm, size, fill, premiumPerUnit, validTill, false, 0, sig);
    }

    function test_sell_fullFill_succeeds_whenPartialFillNotAllowed() public {
        uint128 size = 1e18;
        uint128 premiumPerUnit = 100e6;
        uint256 validTill = block.timestamp + 1 hours;

        weth.mint(seller, size);
        vm.prank(seller);
        weth.approve(address(pair), size);
        usdc.mint(address(funder), premiumPerUnit);

        bytes memory sig = _signQuote(address(funder), address(pair), mmPrivateKey, int256(uint256(size)), premiumPerUnit, validTill, false, 0, 0);
        vm.prank(seller);
        pair.sell(address(funder), mm, size, size, premiumPerUnit, validTill, false, 0, sig);

        assertEq(pair.totalSold(), size);
    }

    function test_sell_wrongAllowPartialFill_revertsInvalidSignature() public {
        uint128 size = 1e18;
        uint128 premiumPerUnit = 100e6;
        uint256 validTill = block.timestamp + 1 hours;

        weth.mint(seller, size);
        vm.prank(seller);
        weth.approve(address(pair), size);
        usdc.mint(address(funder), premiumPerUnit);

        // Sign with allowPartialFill = true, but call with false
        bytes memory sig = _signQuote(address(funder), address(pair), mmPrivateKey, int256(uint256(size)), premiumPerUnit, validTill, true, 0, 0);
        vm.prank(seller);
        vm.expectRevert(SigVerifier.InvalidSignature.selector);
        pair.sell(address(funder), mm, size, size, premiumPerUnit, validTill, false, 0, sig);
    }

    // =========================================================================
    // buy
    // =========================================================================

    function test_buy_longPositionCreated() public {
        _doBuy(pair, buyer, 1e18, 100e6);
        // buyer has long
        assertEq(pair.netPosition(buyer), int256(1e18));
        // mm (seller via funder) has short
        assertEq(pair.netPosition(mm), -int256(1e18));
        assertEq(pair.totalSold(), 1e18);
    }

    function test_buy_sellerFunderReceivesPremiumMinusFee() public {
        uint128 size = 1e18;
        uint128 premium = 200e6;
        _doBuy(pair, buyer, size, premium);

        uint256 fee = (uint256(premium) * pair.FEE_BPS()) / pair.BPS();
        // earnings deposited into funder's shared pool
        assertEq(usdc.balanceOf(address(funder)), premium - fee);
    }

    function test_buy_revertsAfterDepositDeadline() public {
        vm.warp(pair.depositDeadline());

        usdc.mint(buyer, 100e6);
        vm.prank(buyer);
        usdc.approve(address(pair), 100e6);

        bytes memory sig = _signQuote(
            address(funder),
            address(pair),
            mmPrivateKey,
            -int256(1e18),
            1e18,
            expiryTimestamp + 1,
            true,
            0,
            0
        );

        vm.prank(buyer);
        vm.expectRevert(IOPair.DepositWindowClosed.selector);
        pair.buy(address(funder), mm, 1e18, 1e18, 100e6, expiryTimestamp + 1, true, 0, sig);
    }

    function test_buy_revertsZeroSize() public {
        vm.prank(buyer);
        vm.expectRevert(IOPair.ZeroSize.selector);
        pair.buy(address(funder), mm, 0, 0, 100e6, block.timestamp + 1, true, 0, hex"");
    }

    function test_buy_revertsExpiredQuote() public {
        uint256 pastTime = block.timestamp - 1;
        usdc.mint(buyer, 100e6);
        vm.prank(buyer);
        usdc.approve(address(pair), 100e6);

        bytes memory sig = _signQuote(
            address(funder), address(pair), mmPrivateKey,
            -int256(1e18), 100e6, pastTime, true, 0, 0
        );

        vm.prank(buyer);
        vm.expectRevert(IOPair.QuoteExpired.selector);
        pair.buy(address(funder), mm, 1e18, 1e18, 100e6, pastTime, true, 0, sig);
    }

    function test_buy_revertsBelowMinDeposit() public {
        uint128 tinySize = MIN_DEPOSIT - 1;
        usdc.mint(buyer, 1e6);
        vm.prank(buyer);
        usdc.approve(address(pair), 1e6);

        bytes memory sig = _signQuote(
            address(funder), address(pair), mmPrivateKey,
            -int256(uint256(tinySize)), 1e6, block.timestamp + 1, true, 0, 0
        );

        vm.prank(buyer);
        vm.expectRevert(IOPair.BelowMinDeposit.selector);
        pair.buy(address(funder), mm, tinySize, tinySize, 1e6, block.timestamp + 1, true, 0, sig);
    }

    function test_bumpNonce_buy_invalidatesPriorSignature() public {
        uint128 size = 1e18;
        uint128 premium = 100e6;
        uint256 validTill = block.timestamp + 1 hours;

        usdc.mint(buyer, premium);
        vm.prank(buyer);
        usdc.approve(address(pair), premium);
        weth.mint(address(funder), size);

        // Seller sig valid at nonce 0
        bytes memory sig = _signQuote(
            address(funder), address(pair), mmPrivateKey,
            -int256(uint256(size)), premium, validTill, true, 0, 0
        );

        // mm bumps their own nonce
        vm.prank(mm);
        pair.bumpNonce(0, 1);
        assertEq(pair.nonces(mm, 0), 1);

        vm.prank(buyer);
        vm.expectRevert(SigVerifier.InvalidSignature.selector);
        pair.buy(address(funder), mm, size, size, premium, validTill, true, 0, sig);
    }

    function test_nonces_perSigner_independent() public {
        uint256 signer2Key = 0xB0B;
        address signer2 = vm.addr(signer2Key);
        vm.prank(mm);
        funder.grantRole(SIGNER_ROLE, signer2);

        uint128 size = 1e18;
        uint128 premium = 50e6;
        uint256 validTill = block.timestamp + 1 hours;

        usdc.mint(address(funder), premium * 2);
        weth.mint(seller, size * 2);
        vm.prank(seller);
        weth.approve(address(pair), size * 2);

        // Consume mm's nonce 0
        bytes memory sig1 = _signQuote(address(funder), address(pair), mmPrivateKey, int256(uint256(size)), premium, validTill, true, 0, 0);
        vm.prank(seller);
        pair.sell(address(funder), mm, size, size, premium, validTill, true, 0, sig1);
        assertEq(pair.nonces(mm, 0), 1);

        // signer2's nonce is still 0 — independent
        assertEq(pair.nonces(signer2, 0), 0);
        bytes memory sig2 = _signQuote(address(funder), address(pair), signer2Key, int256(uint256(size)), premium, validTill, true, 0, 0);
        vm.prank(seller);
        pair.sell(address(funder), signer2, size, size, premium, validTill, true, 0, sig2);
        assertEq(pair.nonces(signer2, 0), 1);
    }

    function test_buy_emitsBought() public {
        uint128 size = 1e18;
        uint128 premium = 100e6;
        uint256 validTill = block.timestamp + 1 hours;
        uint256 depositAmt = size; // call: depositAmt = size

        usdc.mint(buyer, premium);
        vm.prank(buyer);
        usdc.approve(address(pair), premium);
        weth.mint(address(funder), depositAmt);

        // mm is seller → negative size
        bytes memory sig = _signQuote(
            address(funder),
            address(pair),
            mmPrivateKey,
            -int256(uint256(size)),
            premium,
            validTill,
            true,
            0,
            0
        );

        vm.prank(buyer);
        vm.expectEmit(true, true, false, true);
        emit IOPair.Bought(buyer, mm, size, premium, 0, 0);
        pair.buy(address(funder), mm, size, size, premium, validTill, true, 0, sig);
    }

    function test_buy_partialFill_succeeds_whenAllowed() public {
        uint128 size = 2e18;
        uint128 fill = 1e18;
        uint128 premiumPerUnit = 100e6;
        uint256 validTill = block.timestamp + 1 hours;

        usdc.mint(buyer, premiumPerUnit); // 100e6 * 1e18 / 1e18 = 100e6
        vm.prank(buyer);
        usdc.approve(address(pair), premiumPerUnit);
        weth.mint(address(funder), fill);

        bytes memory sig = _signQuote(address(funder), address(pair), mmPrivateKey, -int256(uint256(size)), premiumPerUnit, validTill, true, 0, 0);
        vm.prank(buyer);
        pair.buy(address(funder), mm, size, fill, premiumPerUnit, validTill, true, 0, sig);

        assertEq(pair.netPosition(buyer), int256(uint256(fill)));
        assertEq(pair.netPosition(mm), -int256(uint256(fill)));
    }

    function test_buy_partialFill_reverts_whenNotAllowed() public {
        uint128 size = 2e18;
        uint128 fill = 1e18;
        uint128 premiumPerUnit = 100e6;
        uint256 validTill = block.timestamp + 1 hours;

        usdc.mint(buyer, premiumPerUnit);
        vm.prank(buyer);
        usdc.approve(address(pair), premiumPerUnit);
        weth.mint(address(funder), fill);

        bytes memory sig = _signQuote(address(funder), address(pair), mmPrivateKey, -int256(uint256(size)), premiumPerUnit, validTill, false, 0, 0);
        vm.prank(buyer);
        vm.expectRevert(IOPair.PartialFillNotAllowed.selector);
        pair.buy(address(funder), mm, size, fill, premiumPerUnit, validTill, false, 0, sig);
    }

    function test_buy_fullFill_succeeds_whenPartialFillNotAllowed() public {
        uint128 size = 1e18;
        uint128 premiumPerUnit = 100e6;
        uint256 validTill = block.timestamp + 1 hours;

        usdc.mint(buyer, premiumPerUnit);
        vm.prank(buyer);
        usdc.approve(address(pair), premiumPerUnit);
        weth.mint(address(funder), size);

        bytes memory sig = _signQuote(address(funder), address(pair), mmPrivateKey, -int256(uint256(size)), premiumPerUnit, validTill, false, 0, 0);
        vm.prank(buyer);
        pair.buy(address(funder), mm, size, size, premiumPerUnit, validTill, false, 0, sig);

        assertEq(pair.netPosition(buyer), int256(uint256(size)));
    }

    function test_buy_wrongAllowPartialFill_revertsInvalidSignature() public {
        uint128 size = 1e18;
        uint128 premiumPerUnit = 100e6;
        uint256 validTill = block.timestamp + 1 hours;

        usdc.mint(buyer, premiumPerUnit);
        vm.prank(buyer);
        usdc.approve(address(pair), premiumPerUnit);
        weth.mint(address(funder), size);

        // Sign with allowPartialFill = false, but call with true
        bytes memory sig = _signQuote(address(funder), address(pair), mmPrivateKey, -int256(uint256(size)), premiumPerUnit, validTill, false, 0, 0);
        vm.prank(buyer);
        vm.expectRevert(SigVerifier.InvalidSignature.selector);
        pair.buy(address(funder), mm, size, size, premiumPerUnit, validTill, true, 0, sig);
    }

    // =========================================================================
    // exercise
    // =========================================================================

    function test_exercise_reducesLongPosition() public {
        _doSell(pair, seller, 1e18, 100e6);
        _fundCallbackForExercise(pair, 1e18);

        vm.warp(pair.exerciseEarliest());
        vm.prank(mm);
        pair.exercise(1e18, address(callback), "");

        assertEq(pair.netPosition(mm), 0);
        assertEq(pair.exercised(mm), 1e18);
        assertEq(pair.totalExercised(), 1e18);
    }

    function test_exercise_callVaultSendsRiskTokenReceivesCash() public {
        _doSell(pair, seller, 1e18, 100e6);
        _fundCallbackForExercise(pair, 1e18);

        vm.warp(pair.exerciseEarliest());
        uint256 swapAmt = (uint256(1e18) * STRIKE) / 1e18;
        vm.prank(mm);
        pair.exercise(1e18, address(callback), "");

        assertEq(weth.balanceOf(address(callback)), 1e18);
        // Vault received cashToken
        assertEq(usdc.balanceOf(address(pair)), swapAmt + pair.totalFees());
    }

    function test_exercise_partialExercise() public {
        _doSell(pair, seller, 2e18, 200e6);
        _fundCallbackForExercise(pair, 1e18);

        vm.warp(pair.exerciseEarliest());
        vm.prank(mm);
        pair.exercise(1e18, address(callback), "");

        assertEq(pair.totalExercised(), 1e18);
        assertEq(pair.exercised(mm), 1e18);
        assertEq(pair.netPosition(mm), int256(1e18));
    }

    function test_exercise_revertsInsufficientLongPosition() public {
        _doSell(pair, seller, 1e18, 100e6);

        vm.warp(pair.exerciseEarliest());
        vm.prank(mm);
        vm.expectRevert(IOPair.InsufficientLongPosition.selector);
        pair.exercise(2e18, address(callback), "");
    }

    function test_exercise_revertsZeroSize() public {
        vm.warp(pair.exerciseEarliest());
        vm.prank(mm);
        vm.expectRevert(IOPair.ZeroSize.selector);
        pair.exercise(0, address(callback), "");
    }

    function test_exercise_revertsAfterExpiry() public {
        _doSell(pair, seller, 1e18, 100e6);
        vm.warp(expiryTimestamp);

        vm.prank(mm);
        vm.expectRevert(IOPair.Expired.selector);
        pair.exercise(1e18, address(callback), "");
    }

    function test_exercise_revertsCallbackUnderpaid() public {
        _doSell(pair, seller, 1e18, 100e6);
        _fundCallbackForExercise(pair, 1e18);
        callback.setUnderpay(true);

        vm.warp(pair.exerciseEarliest());
        vm.prank(mm);
        vm.expectRevert(IOPair.CallbackUnderpaid.selector);
        pair.exercise(1e18, address(callback), "");
    }

    function test_exercise_emitsExercised() public {
        _doSell(pair, seller, 1e18, 100e6);
        _fundCallbackForExercise(pair, 1e18);

        vm.warp(pair.exerciseEarliest());
        vm.prank(mm);
        vm.expectEmit(true, false, false, true);
        emit IOPair.Exercised(mm, 1e18);
        pair.exercise(1e18, address(callback), "");
    }

    // =========================================================================
    // unexercise
    // =========================================================================

    function test_unexercise_restoresLongPosition() public {
        _doSell(pair, seller, 1e18, 100e6);
        _fundCallbackForExercise(pair, 1e18);

        vm.warp(pair.exerciseEarliest());
        vm.prank(mm);
        pair.exercise(1e18, address(callback), "");
        assertEq(pair.netPosition(mm), 0);
        assertEq(pair.exercised(mm), 1e18);

        _fundCallbackForUnexercise(pair, 1e18);
        vm.prank(mm);
        pair.unexercise(1e18, address(callback), "");

        assertEq(pair.netPosition(mm), int256(1e18));
        assertEq(pair.exercised(mm), 0);
        assertEq(pair.totalExercised(), 0);
    }

    function test_unexercise_partialUnexercise() public {
        _doSell(pair, seller, 2e18, 200e6);
        _fundCallbackForExercise(pair, 2e18);

        vm.warp(pair.exerciseEarliest());
        vm.prank(mm);
        pair.exercise(2e18, address(callback), "");

        _fundCallbackForUnexercise(pair, 1e18);
        vm.prank(mm);
        pair.unexercise(1e18, address(callback), "");

        assertEq(pair.netPosition(mm), int256(1e18));
        assertEq(pair.exercised(mm), 1e18);
        assertEq(pair.totalExercised(), 1e18);
    }

    function test_unexercise_callPairSwapsTokensCorrectly() public {
        _doSell(pair, seller, 1e18, 100e6);
        _fundCallbackForExercise(pair, 1e18);

        vm.warp(pair.exerciseEarliest());
        vm.prank(mm);
        pair.exercise(1e18, address(callback), "");

        // After exercise: callback has 1 WETH (depositToken sent during exercise)
        // and 0 USDC (swapToken was consumed by exercise callback).
        // For unexercise: pair sends USDC (swapToken) to callback, expects WETH (depositToken) back.
        _fundCallbackForUnexercise(pair, 1e18);
        uint256 pairWethBefore = weth.balanceOf(address(pair));
        vm.prank(mm);
        pair.unexercise(1e18, address(callback), "");

        // Pair got depositToken (WETH) back
        assertEq(weth.balanceOf(address(pair)) - pairWethBefore, 1e18);
    }

    function test_unexercise_revertsInsufficientExercisedPosition() public {
        _doSell(pair, seller, 1e18, 100e6);
        _fundCallbackForExercise(pair, 1e18);

        vm.warp(pair.exerciseEarliest());
        vm.prank(mm);
        pair.exercise(1e18, address(callback), "");

        // Try to unexercise more than exercised
        vm.prank(mm);
        vm.expectRevert(IOPair.InsufficientExercisedPosition.selector);
        pair.unexercise(2e18, address(callback), "");
    }

    function test_unexercise_revertsZeroSize() public {
        vm.warp(pair.exerciseEarliest());
        vm.prank(mm);
        vm.expectRevert(IOPair.ZeroSize.selector);
        pair.unexercise(0, address(callback), "");
    }

    function test_unexercise_revertsAfterExpiry() public {
        _doSell(pair, seller, 1e18, 100e6);
        _fundCallbackForExercise(pair, 1e18);

        vm.warp(pair.exerciseEarliest());
        vm.prank(mm);
        pair.exercise(1e18, address(callback), "");

        vm.warp(expiryTimestamp);
        vm.prank(mm);
        vm.expectRevert(IOPair.Expired.selector);
        pair.unexercise(1e18, address(callback), "");
    }

    function test_unexercise_revertsBeforeExerciseEarliest() public {
        _doSell(pair, seller, 1e18, 100e6);
        _fundCallbackForExercise(pair, 1e18);

        vm.warp(pair.exerciseEarliest());
        vm.prank(mm);
        pair.exercise(1e18, address(callback), "");

        // Rewind before exerciseEarliest
        vm.warp(pair.exerciseEarliest() - 1);
        vm.prank(mm);
        vm.expectRevert(IOPair.ExerciseTooEarly.selector);
        pair.unexercise(1e18, address(callback), "");
    }

    function test_unexercise_revertsCallbackUnderpaid() public {
        _doSell(pair, seller, 1e18, 100e6);
        _fundCallbackForExercise(pair, 1e18);

        vm.warp(pair.exerciseEarliest());
        vm.prank(mm);
        pair.exercise(1e18, address(callback), "");

        _fundCallbackForUnexercise(pair, 1e18);
        callback.setUnderpay(true);

        vm.prank(mm);
        vm.expectRevert(IOPair.CallbackUnderpaid.selector);
        pair.unexercise(1e18, address(callback), "");
    }

    function test_unexercise_emitsUnexercised() public {
        _doSell(pair, seller, 1e18, 100e6);
        _fundCallbackForExercise(pair, 1e18);

        vm.warp(pair.exerciseEarliest());
        vm.prank(mm);
        pair.exercise(1e18, address(callback), "");

        _fundCallbackForUnexercise(pair, 1e18);
        vm.prank(mm);
        vm.expectEmit(true, false, false, true);
        emit IOPair.Unexercised(mm, 1e18);
        pair.unexercise(1e18, address(callback), "");
    }

    // =========================================================================
    // addShort: exercised longs cannot be netted
    // =========================================================================

    function test_sell_exercisedLongsNotNetted() public {
        // mm goes long 2e18, exercises 2e18
        _doSell(pair, seller, 2e18, 200e6);
        _fundCallbackForExercise(pair, 2e18);
        vm.warp(pair.exerciseEarliest());
        vm.prank(mm);
        pair.exercise(2e18, address(callback), "");

        assertEq(pair.netPosition(mm), 0);
        assertEq(pair.exercised(mm), 2e18);

        // Now mm goes short (via _doBuy where mm is seller).
        // Because all of mm's longs are exercised (netPosition=0), no netting occurs.
        // mm must provide full collateral.
        _doBuy(pair, buyer, 1e18, 100e6);
        assertEq(pair.netPosition(mm), -int256(1e18));
        // totalSold increases by the full amount (no netting)
        assertEq(pair.totalSold(), 3e18);
    }

    function test_sell_partialExercisedLongs_onlyNetsUnexercised() public {
        // mm goes long 3e18, exercises 2e18
        _doSell(pair, seller, 3e18, 300e6);
        _fundCallbackForExercise(pair, 2e18);
        vm.warp(pair.exerciseEarliest());
        vm.prank(mm);
        pair.exercise(2e18, address(callback), "");

        assertEq(pair.netPosition(mm), int256(1e18));
        assertEq(pair.exercised(mm), 2e18);

        // mm goes short for 2e18 (via buyer calling buy, mm is seller via funder).
        // mm has 1e18 unexercised longs, so only 1e18 is netted.
        // physicalSize = 2e18 - 1e18 = 1e18 → only 1e18 collateral needed.
        // Note: we call _doBuy after the warp, but must re-ensure timestamp is set.
        uint256 totalSoldBefore = pair.totalSold();
        {
            uint128 buySize = 2e18;
            uint128 buyPremium = 200e6;
            uint256 depositAmt = buySize;
            usdc.mint(buyer, buyPremium);
            vm.prank(buyer);
            usdc.approve(address(pair), buyPremium);
            weth.mint(address(funder), depositAmt);

            uint256 nonce = pair.nonces(mm, 0);
            // Use exerciseEarliest directly since block.timestamp may not reflect warp in helpers
            uint256 validTill = pair.exerciseEarliest() + 1 hours;
            uint128 premiumPerUnit = uint128(uint256(buyPremium) * 1e18 / uint256(buySize));
            bytes memory sig = _signQuote(address(funder), address(pair), mmPrivateKey, -int256(uint256(buySize)), premiumPerUnit, validTill, true, 0, nonce);
            vm.prank(buyer);
            pair.buy(address(funder), mm, buySize, buySize, premiumPerUnit, validTill, true, 0, sig);
        }
        assertEq(pair.netPosition(mm), -int256(1e18));
        // Only 1e18 physically added (1e18 netted)
        assertEq(pair.totalSold() - totalSoldBefore, 1e18);
    }

    // =========================================================================
    // Self-trade rejection
    // =========================================================================

    function test_sell_revertsSelfTrade() public {
        // mm signs a buy quote (positive size) and then tries to fill it as seller.
        uint128 size = 1e18;
        uint128 premium = 100e6;
        uint128 premiumPerUnit = premium;
        uint256 validTill = block.timestamp + 1 hours;

        weth.mint(mm, size);
        vm.prank(mm);
        weth.approve(address(pair), size);
        usdc.mint(address(funder), premium);

        bytes memory sig = _signQuote(
            address(funder), address(pair), mmPrivateKey,
            int256(uint256(size)), premiumPerUnit, validTill, true, 0, 0
        );

        vm.prank(mm);
        vm.expectRevert(IOPair.SelfTrade.selector);
        pair.sell(address(funder), mm, size, size, premiumPerUnit, validTill, true, 0, sig);
    }

    function test_buy_revertsSelfTrade() public {
        // mm signs a sell quote (negative size) and then tries to fill it as buyer.
        uint128 size = 1e18;
        uint128 premium = 100e6;
        uint128 premiumPerUnit = premium;
        uint256 validTill = block.timestamp + 1 hours;

        usdc.mint(mm, premium);
        vm.prank(mm);
        usdc.approve(address(pair), premium);
        weth.mint(address(funder), size);

        bytes memory sig = _signQuote(
            address(funder), address(pair), mmPrivateKey,
            -int256(uint256(size)), premiumPerUnit, validTill, true, 0, 0
        );

        vm.prank(mm);
        vm.expectRevert(IOPair.SelfTrade.selector);
        pair.buy(address(funder), mm, size, size, premiumPerUnit, validTill, true, 0, sig);
    }

    function test_take_revertsSelfTrade_sellSide() public {
        // take() with negative size dispatches to sell().
        uint128 size = 1e18;
        uint128 premium = 100e6;
        uint128 premiumPerUnit = premium;
        uint256 validTill = block.timestamp + 1 hours;

        weth.mint(mm, size);
        vm.prank(mm);
        weth.approve(address(pair), size);
        usdc.mint(address(funder), premium);

        // take() is called with the opposite sign (negative size = sell path),
        // but the signed quote is still the counterparty's (buy intent, +size).
        bytes memory sig = _signQuote(
            address(funder), address(pair), mmPrivateKey,
            int256(uint256(size)), premiumPerUnit, validTill, true, 0, 0
        );

        vm.prank(mm);
        vm.expectRevert(IOPair.SelfTrade.selector);
        pair.take(address(funder), mm, -int128(size), size, premiumPerUnit, validTill, true, 0, sig);
    }

    function test_take_revertsSelfTrade_buySide() public {
        uint128 size = 1e18;
        uint128 premium = 100e6;
        uint128 premiumPerUnit = premium;
        uint256 validTill = block.timestamp + 1 hours;

        usdc.mint(mm, premium);
        vm.prank(mm);
        usdc.approve(address(pair), premium);
        weth.mint(address(funder), size);

        bytes memory sig = _signQuote(
            address(funder), address(pair), mmPrivateKey,
            -int256(uint256(size)), premiumPerUnit, validTill, true, 0, 0
        );

        vm.prank(mm);
        vm.expectRevert(IOPair.SelfTrade.selector);
        pair.take(address(funder), mm, int128(size), size, premiumPerUnit, validTill, true, 0, sig);
    }

    // =========================================================================
    // Unexercise netting — swap-token settlement + per-user exercised decrement
    // =========================================================================

    function test_unexercise_fullyNetted_settlesSwapTokenAndSkipsCallback() public {
        // Setup: mm longs 2, exercises 2, then shorts 1. Now unexercise 1 → fully netted.
        _doSell(pair, seller, 2e18, 200e6);
        _fundCallbackForExercise(pair, 2e18);
        vm.warp(pair.exerciseEarliest());
        vm.prank(mm);
        pair.exercise(2e18, address(callback), "");
        _doBuy(pair, buyer, 1e18, 100e6);

        assertEq(pair.netPosition(mm), -int256(1e18));
        assertEq(pair.exercised(mm), 2e18);
        assertEq(pair.totalExercised(), 2e18);

        uint256 swapBefore = pair.settledSwapToken(mm);
        uint256 callbackWethBefore = weth.balanceOf(address(callback));

        // Note: no _fundCallbackForUnexercise call — fully-netted path must NOT touch callback.
        vm.prank(mm);
        pair.unexercise(1e18, address(callback), "");

        // Fully netted: netPosition moves from -1 to 0; exercised[mm] -= 1; totalExercised -= 1;
        // settledSwapToken[mm] += 1e18.
        assertEq(pair.netPosition(mm), 0);
        assertEq(pair.exercised(mm), 1e18);
        assertEq(pair.totalExercised(), 1e18);
        assertEq(pair.settledSwapToken(mm) - swapBefore, 1e18);
        // Callback was not invoked (no transfer in or out).
        assertEq(weth.balanceOf(address(callback)), callbackWethBefore);
    }

    function test_unexercise_partiallyNetted_settlesAndSwapsRemainder() public {
        // Setup: mm longs 3, exercises 3, shorts 1. Unexercise 2 → 1 netted, 1 physical.
        _doSell(pair, seller, 3e18, 300e6);
        _fundCallbackForExercise(pair, 3e18);
        vm.warp(pair.exerciseEarliest());
        vm.prank(mm);
        pair.exercise(3e18, address(callback), "");
        _doBuy(pair, buyer, 1e18, 100e6);

        assertEq(pair.netPosition(mm), -int256(1e18));
        assertEq(pair.exercised(mm), 3e18);

        uint256 swapBefore = pair.settledSwapToken(mm);
        // Only need to fund callback for the physical (non-netted) portion: 1e18.
        _fundCallbackForUnexercise(pair, 1e18);

        vm.prank(mm);
        pair.unexercise(2e18, address(callback), "");

        // 1e18 netted against short, 1e18 physically swapped.
        assertEq(pair.netPosition(mm), int256(1e18));
        assertEq(pair.exercised(mm), 1e18);
        assertEq(pair.totalExercised(), 1e18);
        assertEq(pair.settledSwapToken(mm) - swapBefore, 1e18);
    }

    function test_invariant_exercisedSumEqualsTotal_complexFlow() public {
        // Build up several exercised positions, then do trades that cause netting,
        // and finally unexercise. Assert sum(exercised[*]) == totalExercised at each step.
        address other = makeAddr("other");

        // Step 1: mm goes long 4, exercises 3. seller is short 4.
        _doSell(pair, seller, 4e18, 400e6);
        _fundCallbackForExercise(pair, 3e18);
        vm.warp(pair.exerciseEarliest());
        vm.prank(mm);
        pair.exercise(3e18, address(callback), "");
        assertEq(pair.exercised(mm) + pair.exercised(seller) + pair.exercised(buyer) + pair.exercised(other), pair.totalExercised());

        // Step 2: `other` buys 1 from mm (mm sells via funder). mm was long 1, now long 0.
        _buyAsOther(other, 1e18, 100e6);
        // mm had netPosition=1, now 0. exercised[mm] unchanged.
        assertEq(pair.netPosition(mm), 0);
        assertEq(pair.exercised(mm), 3e18);
        assertEq(pair.exercised(mm) + pair.exercised(seller) + pair.exercised(buyer) + pair.exercised(other), pair.totalExercised());

        // Step 3: `other` now long, buys another 1 from mm. mm goes from 0 → -1 short.
        _buyAsOther(other, 1e18, 100e6);
        assertEq(pair.netPosition(mm), -int256(1e18));
        assertEq(pair.exercised(mm) + pair.exercised(seller) + pair.exercised(buyer) + pair.exercised(other), pair.totalExercised());

        // Step 4: mm unexercises 2 — 1 nets against short, 1 goes through physical swap.
        _fundCallbackForUnexercise(pair, 1e18);
        vm.prank(mm);
        pair.unexercise(2e18, address(callback), "");
        assertEq(pair.exercised(mm), 1e18);
        assertEq(pair.exercised(mm) + pair.exercised(seller) + pair.exercised(buyer) + pair.exercised(other), pair.totalExercised());
    }

    // =========================================================================
    // claim
    // =========================================================================

    function test_claim_fullyUnexercised_getsDepositBack() public {
        _doSell(pair, seller, 1e18, 100e6);
        vm.warp(expiryTimestamp);

        uint256 wethBefore = weth.balanceOf(seller);
        vm.prank(seller);
        pair.claim(seller, 1e18, false);
        assertEq(weth.balanceOf(seller) - wethBefore, 1e18);
    }

    function test_claim_fullyExercised_getsSwapToken() public {
        _doSell(pair, seller, 1e18, 100e6);
        _fundCallbackForExercise(pair, 1e18);

        vm.warp(pair.exerciseEarliest());
        vm.prank(mm);
        pair.exercise(1e18, address(callback), "");

        vm.warp(expiryTimestamp);
        uint256 usdcBefore = usdc.balanceOf(seller);
        vm.prank(seller);
        pair.claim(seller, 1e18, false);
        assertEq(
            usdc.balanceOf(seller) - usdcBefore,
            (uint256(1e18) * STRIKE) / 1e18
        );
    }

    function test_claim_revertsBeforeExpiry() public {
        _doSell(pair, seller, 1e18, 100e6);

        vm.prank(seller);
        vm.expectRevert(IOPair.NotExpired.selector);
        pair.claim(seller, 1e18, false);
    }

    function test_claim_revertsInsufficientShortPosition() public {
        _doSell(pair, seller, 1e18, 100e6);
        vm.warp(expiryTimestamp);

        vm.prank(seller);
        vm.expectRevert(IOPair.InsufficientShortPosition.selector);
        pair.claim(seller, 2e18, false);
    }

    function test_claim_revertsZeroSize() public {
        vm.warp(expiryTimestamp);
        vm.prank(seller);
        vm.expectRevert(IOPair.ZeroSize.selector);
        pair.claim(seller, 0, false);
    }

    function test_claim_emitsClaimed() public {
        _doSell(pair, seller, 1e18, 100e6);
        vm.warp(expiryTimestamp);

        vm.prank(seller);
        vm.expectEmit(true, true, false, true);
        emit IOPair.Claimed(seller, seller, 1e18, 0); // fully unexercised: fromUnexercised=1e18, fromExercised=0
        pair.claim(seller, 1e18, false);
    }

    // =========================================================================
    // claimFees
    // =========================================================================

    function test_claimFees_factoryOwnerCanClaim() public {
        _doSell(pair, seller, 1e18, 100e6);
        uint256 expectedFee = (100e6 * pair.FEE_BPS()) / pair.BPS();

        vm.warp(expiryTimestamp);
        uint256 adminUsdcBefore = usdc.balanceOf(admin);

        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit IOPair.FeesClaimed(admin, expectedFee);
        pair.claimFees(admin);
        assertEq(usdc.balanceOf(admin) - adminUsdcBefore, expectedFee);
        assertEq(pair.totalFees(), 0);
    }

    function test_claimFees_revertsNotFactoryOwner() public {
        _doSell(pair, seller, 1e18, 100e6);
        vm.warp(expiryTimestamp);

        vm.prank(seller);
        vm.expectRevert(IOPair.NotFactoryOwner.selector);
        pair.claimFees(seller);
    }

    function test_claimFees_revertsBeforeExpiry() public {
        _doSell(pair, seller, 1e18, 100e6);

        vm.prank(admin);
        vm.expectRevert(IOPair.NotExpired.selector);
        pair.claimFees(admin);
    }

    // =========================================================================
    // extendExpiry
    // =========================================================================

    function test_extendExpiry_factoryOwnerCanExtend() public {
        uint256 newExpiry = expiryTimestamp + 1 days;
        vm.prank(admin);
        pair.extendExpiry(newExpiry);
        assertEq(pair.expiry(), newExpiry);
    }

    function test_extendExpiry_revertsNotLater() public {
        vm.prank(admin);
        vm.expectRevert(IOPair.NewExpiryNotLater.selector);
        pair.extendExpiry(expiryTimestamp); // same, not strictly later
    }

    function test_extendExpiry_revertsNotFactoryOwner() public {
        vm.prank(seller);
        vm.expectRevert(IOPair.NotFactoryOwner.selector);
        pair.extendExpiry(expiryTimestamp + 1 days);
    }

    // =========================================================================
    // setDepositDeadline
    // =========================================================================

    function test_depositDeadline_defaultIs3HoursBeforeExpiry() public view {
        assertEq(pair.depositDeadline(), expiryTimestamp - 3 hours);
    }

    function test_setDepositDeadline_factoryOwnerCanSet() public {
        uint256 newDeadline = expiryTimestamp - 1 hours;
        vm.prank(admin);
        pair.setDepositDeadline(newDeadline);
        assertEq(pair.depositDeadline(), newDeadline);
    }

    function test_setDepositDeadline_revertsNotFactoryOwner() public {
        vm.prank(seller);
        vm.expectRevert(IOPair.NotFactoryOwner.selector);
        pair.setDepositDeadline(expiryTimestamp - 1 hours);
    }

    function test_setDepositDeadline_revertsAtOrPastExpiry() public {
        vm.startPrank(admin);
        vm.expectRevert(IOPair.DepositDeadlinePastExpiry.selector);
        pair.setDepositDeadline(expiryTimestamp); // equal to expiry

        vm.expectRevert(IOPair.DepositDeadlinePastExpiry.selector);
        pair.setDepositDeadline(expiryTimestamp + 1 days); // after expiry
        vm.stopPrank();
    }

    function test_exercise_allowedAfterDepositDeadline() public {
        // Create a position before the deposit deadline
        _doSell(pair, seller, 1e18, 100e6);
        _fundCallbackForExercise(pair, 1e18);

        // Warp past deposit deadline but before expiry
        vm.warp(pair.depositDeadline());

        // New deposits are blocked
        vm.prank(seller);
        vm.expectRevert(IOPair.DepositWindowClosed.selector);
        pair.sell(address(funder), mm, 1e18, 1e18, 100e6, block.timestamp + 1, true, 0, hex"");

        // But exercise still works
        vm.prank(mm);
        pair.exercise(1e18, address(callback), "");
        assertEq(pair.totalExercised(), 1e18);
    }

    function test_setDepositDeadline_allowsTradesAfterExtension() public {
        // Close deposit window
        vm.prank(admin);
        pair.setDepositDeadline(block.timestamp);

        // Trading blocked
        vm.prank(seller);
        vm.expectRevert(IOPair.DepositWindowClosed.selector);
        pair.sell(address(funder), mm, 1e18, 1e18, 100e6, block.timestamp + 1, true, 0, hex"");

        // Admin extends deadline
        vm.prank(admin);
        pair.setDepositDeadline(block.timestamp + 1 days);

        // Trading works again
        _doSell(pair, seller, 1e18, 100e6);
        assertEq(pair.totalSold(), 1e18);
    }

    // =========================================================================
    // exerciseEarliest
    // =========================================================================

    function test_exerciseEarliest_defaultIs4HoursAfterCreation() public view {
        // block.timestamp at setUp time + 4 hours
        assertEq(pair.exerciseEarliest(), 1 + 4 hours); // block.timestamp starts at 1 in foundry
    }

    function test_exercise_revertsBeforeExerciseEarliest() public {
        _doSell(pair, seller, 1e18, 100e6);
        _fundCallbackForExercise(pair, 1e18);

        // Still before exerciseEarliest
        vm.prank(mm);
        vm.expectRevert(IOPair.ExerciseTooEarly.selector);
        pair.exercise(1e18, address(callback), "");
    }

    function test_exercise_worksAfterExerciseEarliest() public {
        _doSell(pair, seller, 1e18, 100e6);
        _fundCallbackForExercise(pair, 1e18);

        vm.warp(pair.exerciseEarliest());
        vm.prank(mm);
        pair.exercise(1e18, address(callback), "");
        assertEq(pair.totalExercised(), 1e18);
    }

    function test_deposit_allowedBeforeExerciseEarliest() public {
        // Deposits work even though exercise is delayed
        _doSell(pair, seller, 1e18, 100e6);
        assertEq(pair.totalSold(), 1e18);
    }

    function test_setExerciseEarliest_factoryOwnerCanSet() public {
        uint256 newEarliest = block.timestamp + 8 hours;
        vm.prank(admin);
        pair.setExerciseEarliest(newEarliest);
        assertEq(pair.exerciseEarliest(), newEarliest);
    }

    function test_setExerciseEarliest_revertsNotFactoryOwner() public {
        vm.prank(seller);
        vm.expectRevert(IOPair.NotFactoryOwner.selector);
        pair.setExerciseEarliest(block.timestamp + 8 hours);
    }

    function test_setExerciseEarliest_revertsWindowTooNarrow() public {
        // Any value within 3 hours of expiry must be rejected.
        uint256 tooLate = expiryTimestamp - 2 hours;
        vm.prank(admin);
        vm.expectRevert(IOPair.ExerciseWindowTooNarrow.selector);
        pair.setExerciseEarliest(tooLate);
    }

    function test_setExerciseEarliest_exactlyThreeHoursBeforeExpiryAllowed() public {
        uint256 boundary = expiryTimestamp - 3 hours;
        vm.prank(admin);
        pair.setExerciseEarliest(boundary);
        assertEq(pair.exerciseEarliest(), boundary);
    }

    function test_exercise_revertsAfterAdminExtendsDelay() public {
        _doSell(pair, seller, 1e18, 100e6);
        _fundCallbackForExercise(pair, 1e18);

        // Warp past default 4h delay
        vm.warp(pair.exerciseEarliest());

        // Admin extends the delay further
        vm.prank(admin);
        pair.setExerciseEarliest(block.timestamp + 2 hours);

        // Exercise now blocked again
        vm.prank(mm);
        vm.expectRevert(IOPair.ExerciseTooEarly.selector);
        pair.exercise(1e18, address(callback), "");

        // Warp past new delay — exercise works
        vm.warp(pair.exerciseEarliest());
        vm.prank(mm);
        pair.exercise(1e18, address(callback), "");
        assertEq(pair.totalExercised(), 1e18);
    }

    // =========================================================================
    // claimSettled (netting)
    // =========================================================================

    function test_claimSettled_revertsNothingToSettle() public {
        vm.prank(seller);
        vm.expectRevert(IOPair.NothingToSettle.selector);
        pair.claimSettled(seller);
    }

    function test_claimSettled_afterNetFromLong() public {
        // First: mm goes long (via _doSell)
        _doSell(pair, seller, 2e18, 200e6);
        assertEq(pair.netPosition(mm), int256(2e18));

        // Now: a second seller sells to mm again, but mm (buyer) nets down
        // We do another sell so mm goes from +2 back toward 0
        // Actually to trigger netting for the *buyer*, we need the buyer (mm) to already be short.
        // Let's do the opposite: mm goes short first (via _doBuy where mm sells),
        // then a buy netting happens.
        // For simplicity: create a second pair where mm first shorts then longs.
        OPair pair2;
        {
            vm.prank(admin);
            pair2 = OPair(
                factory.createPair(
                    address(weth),
                    address(usdc),
                    STRIKE,
                    expiryTimestamp + 1 days,
                    true,
                    MIN_DEPOSIT,
                    "P2",
                    "P2"
                )
            );
        }

        // mm goes short 1 ETH in pair2 via buyer calling buy
        _doBuy(pair2, buyer, 1e18, 100e6);
        assertEq(pair2.netPosition(mm), -int256(1e18));

        // Now seller calls sell with mm as buyer — mm nets from -1 back toward 0
        // mm as buyerSigner in sell: mm's short is netted when _addLong runs
        weth.mint(seller, 1e18);
        vm.prank(seller);
        weth.approve(address(pair2), 1e18);
        usdc.mint(address(funder), 100e6);

        uint256 nonce = pair2.nonces(mm, 0);
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signQuote(
            address(funder),
            address(pair2),
            mmPrivateKey,
            int256(1e18),
            100e6,
            validTill,
            true,
            0,
            nonce
        );

        vm.prank(seller);
        pair2.sell(address(funder), mm, 1e18, 1e18, 100e6, validTill, true, 0, sig);

        // mm was short 1e18, now netted — settled deposit stored
        assertEq(pair2.netPosition(mm), 0);
        assertGt(pair2.settledDepositToken(mm), 0);

        // mm can claim their settled collateral
        uint256 wethBefore = weth.balanceOf(mm);
        vm.prank(mm);
        pair2.claimSettled(mm);
        assertGt(weth.balanceOf(mm) - wethBefore, 0);
    }

    // =========================================================================
    // Put pair
    // =========================================================================

    function test_sell_putPair_cashTokenCollateral() public {
        OPair putPair = _createPutPair();
        uint128 size = 1e18;
        uint128 premium = 50e6;

        // For puts: depositToken = cashToken (USDC), swapToken = riskToken (WETH)
        uint256 depositAmt = (uint256(size) * STRIKE) / 1e18; // 2000 USDC
        usdc.mint(seller, depositAmt);
        vm.prank(seller);
        usdc.approve(address(putPair), depositAmt);

        usdc.mint(address(funder), premium);

        bytes memory sig = _signQuote(
            address(funder),
            address(putPair),
            mmPrivateKey,
            int256(uint256(size)),
            premium,
            block.timestamp + 1 hours,
            true,
            0,
            0
        );

        vm.prank(seller);
        putPair.sell(
            address(funder),
            mm,
            size,
            size,
            premium,
            block.timestamp + 1 hours,
            true,
            0,
            sig
        );

        assertEq(putPair.netPosition(seller), -int256(uint256(size)));
        assertEq(putPair.netPosition(mm), int256(uint256(size)));
    }

    // =========================================================================
    // bumpNonce
    // =========================================================================

    function test_bumpNonce_invalidatesPriorSignature() public {
        uint128 size = 1e18;
        uint128 premium = 100e6;
        uint256 validTill = block.timestamp + 1 hours;

        weth.mint(seller, size);
        vm.prank(seller);
        weth.approve(address(pair), size);
        usdc.mint(address(funder), premium);

        // Sig valid at nonce 0
        bytes memory sig = _signQuote(address(funder), address(pair), mmPrivateKey, int256(uint256(size)), premium, validTill, true, 0, 0);

        vm.prank(mm);
        pair.bumpNonce(0, 1);
        assertEq(pair.nonces(mm, 0), 1);

        // Nonce-0 sig now rejected
        vm.prank(seller);
        vm.expectRevert(SigVerifier.InvalidSignature.selector);
        pair.sell(address(funder), mm, size, size, premium, validTill, true, 0, sig);
    }

    function test_bumpNonce_skipMultiple_onlyNewNonceWorks() public {
        uint128 size = 1e18;
        uint128 premium = 50e6;
        uint256 validTill = block.timestamp + 1 hours;

        usdc.mint(address(funder), premium);

        // Pre-sign at nonces 0, 1, and 5
        bytes memory sig0 = _signQuote(address(funder), address(pair), mmPrivateKey, int256(uint256(size)), premium, validTill, true, 0, 0);
        bytes memory sig1 = _signQuote(address(funder), address(pair), mmPrivateKey, int256(uint256(size)), premium, validTill, true, 0, 1);
        bytes memory sig5 = _signQuote(address(funder), address(pair), mmPrivateKey, int256(uint256(size)), premium, validTill, true, 0, 5);

        vm.prank(mm);
        pair.bumpNonce(0, 5);
        assertEq(pair.nonces(mm, 0), 5);

        // Nonces 0 and 1 are both skipped — rejected
        weth.mint(seller, size);
        vm.prank(seller);
        weth.approve(address(pair), size);
        vm.expectRevert(SigVerifier.InvalidSignature.selector);
        pair.sell(address(funder), mm, size, size, premium, validTill, true, 0, sig0);

        vm.prank(seller);
        vm.expectRevert(SigVerifier.InvalidSignature.selector);
        pair.sell(address(funder), mm, size, size, premium, validTill, true, 0, sig1);

        // Nonce 5 is current — succeeds
        vm.prank(seller);
        pair.sell(address(funder), mm, size, size, premium, validTill, true, 0, sig5);
        assertEq(pair.nonces(mm, 0), 6);
    }

    function test_bumpNonce_byZero_doesNothing() public {
        uint128 size = 1e18;
        uint128 premium = 100e6;
        uint256 validTill = block.timestamp + 1 hours;

        weth.mint(seller, size);
        vm.prank(seller);
        weth.approve(address(pair), size);
        usdc.mint(address(funder), premium);

        bytes memory sig = _signQuote(address(funder), address(pair), mmPrivateKey, int256(uint256(size)), premium, validTill, true, 0, 0);

        vm.prank(mm);
        pair.bumpNonce(0, 0);
        assertEq(pair.nonces(mm, 0), 0);

        // Nonce-0 sig still valid
        vm.prank(seller);
        pair.sell(address(funder), mm, size, size, premium, validTill, true, 0, sig);
        assertEq(pair.nonces(mm, 0), 1);
    }

    // =========================================================================
    // Put pair
    // =========================================================================

    function test_sell_differentChannels_independentNonces() public {
        uint128 size = 1e18;
        uint128 premium = 100e6;
        uint256 validTill = block.timestamp + 1 hours;

        // Sign two quotes on different channels, both at nonce 0
        bytes memory sigCh0 = _signQuote(address(funder), address(pair), mmPrivateKey, int256(uint256(size)), premium, validTill, true, 0, 0);
        bytes memory sigCh1 = _signQuote(address(funder), address(pair), mmPrivateKey, int256(uint256(size)), premium, validTill, true, 1, 0);

        // Fund seller and funder for two trades
        weth.mint(seller, size * 2);
        vm.prank(seller);
        weth.approve(address(pair), size * 2);
        usdc.mint(address(funder), premium * 2);

        // Fill channel 0 nonce 0
        vm.prank(seller);
        pair.sell(address(funder), mm, size, size, premium, validTill, true, 0, sigCh0);
        assertEq(pair.nonces(mm, 0), 1);
        assertEq(pair.nonces(mm, 1), 0); // channel 1 unaffected

        // Fill channel 1 nonce 0 — still valid
        vm.prank(seller);
        pair.sell(address(funder), mm, size, size, premium, validTill, true, 1, sigCh1);
        assertEq(pair.nonces(mm, 1), 1);
    }

    function test_bumpNonce_onlyAffectsSpecificChannel() public {
        uint128 size = 1e18;
        uint128 premium = 100e6;
        uint256 validTill = block.timestamp + 1 hours;

        // Sign on channel 0 at nonce 0 and channel 1 at nonce 0
        bytes memory sigCh0 = _signQuote(address(funder), address(pair), mmPrivateKey, int256(uint256(size)), premium, validTill, true, 0, 0);
        bytes memory sigCh1 = _signQuote(address(funder), address(pair), mmPrivateKey, int256(uint256(size)), premium, validTill, true, 1, 0);

        // Bump channel 0 — invalidates sigCh0 but not sigCh1
        vm.prank(mm);
        pair.bumpNonce(0, 5);
        assertEq(pair.nonces(mm, 0), 5);
        assertEq(pair.nonces(mm, 1), 0); // channel 1 untouched

        // Channel 0 sig rejected
        weth.mint(seller, size);
        vm.prank(seller);
        weth.approve(address(pair), size);
        vm.expectRevert(SigVerifier.InvalidSignature.selector);
        vm.prank(seller);
        pair.sell(address(funder), mm, size, size, premium, validTill, true, 0, sigCh0);

        // Channel 1 sig still valid
        usdc.mint(address(funder), premium);
        vm.prank(seller);
        pair.sell(address(funder), mm, size, size, premium, validTill, true, 1, sigCh1);
        assertEq(pair.nonces(mm, 1), 1);
    }

    // =========================================================================
    // Put pair
    // =========================================================================

    function test_exercise_putPair_sendsCashReceivesRisk() public {
        OPair putPair = _createPutPair();
        _doSell(putPair, seller, 1e18, 50e6);
        _fundCallbackForExercise(putPair, 1e18);

        vm.warp(putPair.exerciseEarliest());
        vm.prank(mm);
        putPair.exercise(1e18, address(callback), "");

        // For puts: depositToken=cashToken(USDC) sent to callback; swapToken=riskToken(WETH) received.
        // Pair collateral is USDC, so only WETH from exercise proceeds sits in the pair.
        assertEq(
            usdc.balanceOf(address(callback)),
            (uint256(1e18) * STRIKE) / 1e18
        );
        assertEq(weth.balanceOf(address(putPair)), 1e18); // only exercise proceeds (swap token)
    }
}
