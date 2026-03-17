// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Setup} from "./Setup.t.sol";
import {OPair} from "../src/OPair.sol";
import {Funder} from "../src/Funder.sol";

contract OPairTest is Setup {
    OPair public pair;

    function setUp() public override {
        super.setUp();
        pair = _createCallPair();
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

    function test_sell_revertsAfterExpiry() public {
        vm.warp(expiryTimestamp);

        uint256 depositAmt = 1e18;
        weth.mint(seller, depositAmt);
        vm.prank(seller);
        weth.approve(address(pair), depositAmt);
        usdc.mint(address(funder), 100e6);

        bytes memory sig = _signQuote(address(funder), address(pair), mmPrivateKey, 1e18, 100e6, expiryTimestamp + 1, 0);

        vm.prank(seller);
        vm.expectRevert(OPair.Expired.selector);
        pair.sell(address(funder), mm, 1e18, 100e6, expiryTimestamp + 1, sig);
    }

    function test_sell_revertsExpiredQuote() public {
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

    function test_sell_revertsZeroSize() public {
        vm.prank(seller);
        vm.expectRevert(OPair.ZeroSize.selector);
        pair.sell(address(funder), mm, 0, 100e6, block.timestamp + 1, hex"");
    }

    function test_sell_revertsBelowMinDeposit() public {
        uint128 tinySize = MIN_DEPOSIT - 1;
        weth.mint(seller, tinySize);
        vm.prank(seller);
        weth.approve(address(pair), tinySize);
        usdc.mint(address(funder), 1e6);

        bytes memory sig = _signQuote(address(funder), address(pair), mmPrivateKey, tinySize, 1e6, block.timestamp + 1, 0);

        vm.prank(seller);
        vm.expectRevert(OPair.BelowMinDeposit.selector);
        pair.sell(address(funder), mm, tinySize, 1e6, block.timestamp + 1, sig);
    }

    function test_sell_emitsSold() public {
        uint128 size = 1e18;
        uint128 premium = 100e6;
        uint256 validTill = block.timestamp + 1 hours;

        weth.mint(seller, size);
        vm.prank(seller);
        weth.approve(address(pair), size);
        usdc.mint(address(funder), premium);

        bytes memory sig = _signQuote(address(funder), address(pair), mmPrivateKey, size, premium, validTill, 0);

        vm.prank(seller);
        vm.expectEmit(true, true, false, true);
        emit OPair.Sold(seller, mm, size, premium, 0, 0);
        pair.sell(address(funder), mm, size, premium, validTill, sig);
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

    function test_buy_revertsAfterExpiry() public {
        vm.warp(expiryTimestamp);

        usdc.mint(buyer, 100e6);
        vm.prank(buyer);
        usdc.approve(address(pair), 100e6);

        bytes memory sig = _signQuote(address(funder), address(pair), mmPrivateKey, 1e18, 1e18, expiryTimestamp + 1, 0);

        vm.prank(buyer);
        vm.expectRevert(OPair.Expired.selector);
        pair.buy(address(funder), mm, 1e18, 100e6, expiryTimestamp + 1, sig);
    }

    function test_buy_revertsZeroSize() public {
        vm.prank(buyer);
        vm.expectRevert(OPair.ZeroSize.selector);
        pair.buy(address(funder), mm, 0, 100e6, block.timestamp + 1, hex"");
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

        bytes memory sig = _signQuote(address(funder), address(pair), mmPrivateKey, size, premium, validTill, 0);

        vm.prank(buyer);
        vm.expectEmit(true, true, false, true);
        emit OPair.Bought(buyer, mm, size, premium, 0, 0);
        pair.buy(address(funder), mm, size, premium, validTill, sig);
    }

    // =========================================================================
    // exercise
    // =========================================================================

    function test_exercise_reducesLongPosition() public {
        _doSell(pair, seller, 1e18, 100e6);
        _fundCallbackForExercise(pair, 1e18);

        vm.prank(mm);
        pair.exercise(1e18, address(callback), "");

        assertEq(pair.netPosition(mm), 0);
        assertEq(pair.totalExercised(), 1e18);
    }

    function test_exercise_callVaultSendsRiskTokenReceivesCash() public {
        _doSell(pair, seller, 1e18, 100e6);
        _fundCallbackForExercise(pair, 1e18);

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

        vm.prank(mm);
        pair.exercise(1e18, address(callback), "");

        assertEq(pair.totalExercised(), 1e18);
        assertEq(pair.netPosition(mm), int256(1e18));
    }

    function test_exercise_revertsInsufficientLongPosition() public {
        _doSell(pair, seller, 1e18, 100e6);

        vm.prank(mm);
        vm.expectRevert(OPair.InsufficientLongPosition.selector);
        pair.exercise(2e18, address(callback), "");
    }

    function test_exercise_revertsZeroSize() public {
        vm.prank(mm);
        vm.expectRevert(OPair.ZeroSize.selector);
        pair.exercise(0, address(callback), "");
    }

    function test_exercise_revertsAfterExpiry() public {
        _doSell(pair, seller, 1e18, 100e6);
        vm.warp(expiryTimestamp);

        vm.prank(mm);
        vm.expectRevert(OPair.Expired.selector);
        pair.exercise(1e18, address(callback), "");
    }

    function test_exercise_revertsCallbackUnderpaid() public {
        _doSell(pair, seller, 1e18, 100e6);
        _fundCallbackForExercise(pair, 1e18);
        callback.setUnderpay(true);

        vm.prank(mm);
        vm.expectRevert(OPair.CallbackUnderpaid.selector);
        pair.exercise(1e18, address(callback), "");
    }

    function test_exercise_emitsExercised() public {
        _doSell(pair, seller, 1e18, 100e6);
        _fundCallbackForExercise(pair, 1e18);

        vm.prank(mm);
        vm.expectEmit(true, false, false, true);
        emit OPair.Exercised(mm, 1e18);
        pair.exercise(1e18, address(callback), "");
    }

    // =========================================================================
    // claim
    // =========================================================================

    function test_claim_fullyUnexercised_getsDepositBack() public {
        _doSell(pair, seller, 1e18, 100e6);
        vm.warp(expiryTimestamp);

        uint256 wethBefore = weth.balanceOf(seller);
        vm.prank(seller);
        pair.claim(1e18, false);
        assertEq(weth.balanceOf(seller) - wethBefore, 1e18);
    }

    function test_claim_fullyExercised_getsSwapToken() public {
        _doSell(pair, seller, 1e18, 100e6);
        _fundCallbackForExercise(pair, 1e18);

        vm.prank(mm);
        pair.exercise(1e18, address(callback), "");

        vm.warp(expiryTimestamp);
        uint256 usdcBefore = usdc.balanceOf(seller);
        vm.prank(seller);
        pair.claim(1e18, false);
        assertEq(usdc.balanceOf(seller) - usdcBefore, (uint256(1e18) * STRIKE) / 1e18);
    }

    function test_claim_revertsBeforeExpiry() public {
        _doSell(pair, seller, 1e18, 100e6);

        vm.prank(seller);
        vm.expectRevert(OPair.NotExpired.selector);
        pair.claim(1e18, false);
    }

    function test_claim_revertsInsufficientShortPosition() public {
        _doSell(pair, seller, 1e18, 100e6);
        vm.warp(expiryTimestamp);

        vm.prank(seller);
        vm.expectRevert(OPair.InsufficientShortPosition.selector);
        pair.claim(2e18, false);
    }

    function test_claim_revertsZeroSize() public {
        vm.warp(expiryTimestamp);
        vm.prank(seller);
        vm.expectRevert(OPair.ZeroSize.selector);
        pair.claim(0, false);
    }

    function test_claim_emitsClaimed() public {
        _doSell(pair, seller, 1e18, 100e6);
        vm.warp(expiryTimestamp);

        vm.prank(seller);
        vm.expectEmit(true, false, false, true);
        emit OPair.Claimed(seller, 1e18, 0); // fully unexercised: fromUnexercised=1e18, fromExercised=0
        pair.claim(1e18, false);
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
        pair.claimFees();
        assertEq(usdc.balanceOf(admin) - adminUsdcBefore, expectedFee);
        assertEq(pair.totalFees(), 0);
    }

    function test_claimFees_revertsNotFactoryOwner() public {
        _doSell(pair, seller, 1e18, 100e6);
        vm.warp(expiryTimestamp);

        vm.prank(seller);
        vm.expectRevert(OPair.NotFactoryOwner.selector);
        pair.claimFees();
    }

    function test_claimFees_revertsBeforeExpiry() public {
        _doSell(pair, seller, 1e18, 100e6);

        vm.prank(admin);
        vm.expectRevert(OPair.NotExpired.selector);
        pair.claimFees();
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
        vm.expectRevert(OPair.NewExpiryNotLater.selector);
        pair.extendExpiry(expiryTimestamp); // same, not strictly later
    }

    function test_extendExpiry_revertsNotFactoryOwner() public {
        vm.prank(seller);
        vm.expectRevert(OPair.NotFactoryOwner.selector);
        pair.extendExpiry(expiryTimestamp + 1 days);
    }

    // =========================================================================
    // claimSettled (netting)
    // =========================================================================

    function test_claimSettled_revertsNothingToSettle() public {
        vm.prank(seller);
        vm.expectRevert(OPair.NothingToSettle.selector);
        pair.claimSettled();
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
            pair2 = OPair(factory.createPair(
                address(weth), address(usdc), STRIKE, expiryTimestamp + 1 days,
                true, MIN_DEPOSIT, "P2", "P2"
            ));
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

        uint256 nonce = funder.nonces(mm, address(pair2));
        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signQuote(address(funder), address(pair2), mmPrivateKey, 1e18, 100e6, validTill, nonce);

        vm.prank(seller);
        pair2.sell(address(funder), mm, 1e18, 100e6, validTill, sig);

        // mm was short 1e18, now netted — settled deposit stored
        assertEq(pair2.netPosition(mm), 0);
        assertGt(pair2.settledDepositToken(mm), 0);

        // mm can claim their settled collateral
        uint256 wethBefore = weth.balanceOf(mm);
        vm.prank(mm);
        pair2.claimSettled();
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

        bytes memory sig = _signQuote(address(funder), address(putPair), mmPrivateKey, size, premium, block.timestamp + 1 hours, 0);

        vm.prank(seller);
        putPair.sell(address(funder), mm, size, premium, block.timestamp + 1 hours, sig);

        assertEq(putPair.netPosition(seller), -int256(uint256(size)));
        assertEq(putPair.netPosition(mm), int256(uint256(size)));
    }

    function test_exercise_putPair_sendsCashReceivesRisk() public {
        OPair putPair = _createPutPair();
        _doSell(putPair, seller, 1e18, 50e6);
        _fundCallbackForExercise(putPair, 1e18);

        vm.prank(mm);
        putPair.exercise(1e18, address(callback), "");

        // For puts: depositToken=cashToken(USDC) sent to callback; swapToken=riskToken(WETH) received.
        // Pair collateral is USDC, so only WETH from exercise proceeds sits in the pair.
        assertEq(usdc.balanceOf(address(callback)), (uint256(1e18) * STRIKE) / 1e18);
        assertEq(weth.balanceOf(address(putPair)), 1e18); // only exercise proceeds (swap token)
    }
}
