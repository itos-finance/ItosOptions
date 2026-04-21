// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Setup} from "./Setup.t.sol";
import {OPair} from "../src/OPair.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Reproduces the end-to-end "open a position, then close it" flow the
///      frontend triggers from /portfolio. The goal is to catch any revert
///      (signature, nonce, collateral, netting) under a deterministic harness
///      before it shows up as an opaque "bundle failed" in the UI.
contract CloseRoundtripTest is Setup {
    // =========================================================================
    // Scenario A: open SHORT (sell), then CLOSE by buying back.
    //   - The taker is the same address on both legs.
    //   - mm (maker) is the counterparty on both legs.
    //   - After close: taker.netPosition = 0, taker.collateral refunded.
    // =========================================================================
    function test_openShort_thenCloseByBuyingBack_netsToZero() public {
        OPair pair = _createCallPair();
        uint128 size = 5e18;
        uint128 openPremium = 500e6;   // 100 USDC per ETH
        uint128 closePremium = 520e6;  // slightly higher — maker spread on the close

        // --- Leg 1: OPEN SHORT ------------------------------------------------
        // seller is the taker; mm (via funder) is the buyer / long side.
        _doSell(pair, seller, size, openPremium);
        assertEq(pair.netPosition(seller), -int256(uint256(size)), "seller not short");
        assertEq(pair.netPosition(mm),      int256(uint256(size)), "mm not long");

        uint256 sellerWethAfterOpen = weth.balanceOf(seller);   // 0 — collateral locked
        uint256 sellerUsdcAfterOpen = usdc.balanceOf(seller);   // premium − fee

        // --- Leg 2: CLOSE via buy back ----------------------------------------
        // seller becomes the taker of a buy — pays close premium, contract
        // nets against the existing short. After this: seller.netPosition = 0.

        // maker-side counterparty is still mm. Its funder supplies collateral
        // if the close isn't fully netted on mm's side. With both legs at
        // identical size, mm goes long→flat and no extra collateral moves.

        // Fund the taker with USDC to pay the close premium.
        usdc.mint(seller, closePremium);
        vm.prank(seller);
        usdc.approve(address(pair), closePremium);

        uint256 nonce = pair.nonces(mm, 0);
        uint256 validTill = block.timestamp + 1 hours;
        uint128 premiumPerUnit = uint128(uint256(closePremium) * 1e18 / uint256(size));

        // mm is now the seller on this leg → negative size.
        bytes memory sig = _signQuote(
            address(funder), address(pair), mmPrivateKey,
            -int256(uint256(size)), premiumPerUnit, validTill, true, 0, nonce
        );

        vm.prank(seller);
        pair.buy(address(funder), mm, size, size, premiumPerUnit, validTill, true, 0, sig);

        // --- Assertions -------------------------------------------------------
        assertEq(pair.netPosition(seller), 0, "taker didn't fully net");
        assertEq(pair.netPosition(mm), 0, "mm didn't fully net");

        // The original short-side collateral is now credited to the taker's
        // settledDepositToken balance, claimable via claimSettled(). The
        // vault keeps physical custody until the user claims.
        assertEq(pair.settledDepositToken(seller), size, "settled collateral missing");
        assertEq(weth.balanceOf(address(pair)), size, "collateral should remain in vault pre-claim");

        // claimSettled() should return exactly `size` WETH to the taker.
        vm.prank(seller);
        pair.claimSettled(seller);
        assertEq(weth.balanceOf(seller), sellerWethAfterOpen + size, "claimSettled didn't pay out");
        assertEq(pair.settledDepositToken(seller), 0, "settled balance not zeroed");

        // USDC: taker kept their post-open earnings minus the close premium
        // (they minted closePremium so their net USDC delta is the open
        // premium - fee, captured at sellerUsdcAfterOpen).
        assertApproxEqAbs(
            usdc.balanceOf(seller),
            sellerUsdcAfterOpen,
            1,
            "seller usdc unexpected after close"
        );
    }

    // =========================================================================
    // Scenario B: open LONG (buy), then CLOSE by selling back.
    //   Mirror of Scenario A. After close: taker.netPosition = 0.
    // =========================================================================
    function test_openLong_thenCloseBySellingBack_netsToZero() public {
        OPair pair = _createCallPair();
        uint128 size = 3e18;
        uint128 openPremium = 300e6;
        uint128 closePremium = 280e6;

        // --- Leg 1: OPEN LONG (buyer pays premium, mm sells) ------------------
        _doBuy(pair, buyer, size, openPremium);
        assertEq(pair.netPosition(buyer), int256(uint256(size)), "buyer not long");
        assertEq(pair.netPosition(mm), -int256(uint256(size)), "mm not short");

        // --- Leg 2: CLOSE LONG via sell ---------------------------------------
        // buyer becomes the taker of a sell. With full netting, taker
        // deposits 0 collateral (_depositAmount(0) == 0). mm (via its
        // funder) pays the close premium out of its pool.
        uint256 nonce = pair.nonces(mm, 0);
        uint256 validTill = block.timestamp + 1 hours;
        uint128 premiumPerUnit = uint128(uint256(closePremium) * 1e18 / uint256(size));

        // mm is the buyer on this leg → positive size.
        bytes memory sig = _signQuote(
            address(funder), address(pair), mmPrivateKey,
            int256(uint256(size)), premiumPerUnit, validTill, true, 0, nonce
        );

        // Top up the funder pool so it can pay the close premium.
        usdc.mint(address(funder), closePremium);

        vm.prank(buyer);
        pair.sell(address(funder), mm, size, size, premiumPerUnit, validTill, true, 0, sig);

        // --- Assertions -------------------------------------------------------
        assertEq(pair.netPosition(buyer), 0, "taker didn't fully net");
        assertEq(pair.netPosition(mm), 0, "mm didn't fully net");

        // The maker's short collateral (provided by mm's funder on leg 1)
        // is now credited back to mm's settledDepositToken, reclaimable via
        // claimSettled(). The vault still holds the physical WETH until
        // the claim.
        assertEq(pair.settledDepositToken(mm), size, "mm settled balance missing");
        assertEq(weth.balanceOf(address(pair)), size, "collateral should stay pre-claim");
    }

    // =========================================================================
    // Scenario C: same taker tries to close via a signed quote from a STALE
    //   nonce (what would happen if the frontend passes an expired FillSlice).
    //   Must revert with InvalidSignature so the UI can surface the reason.
    // =========================================================================
    function test_staleNonce_onCloseReverts() public {
        OPair pair = _createCallPair();
        uint128 size = 2e18;
        uint128 premium = 200e6;

        // Open short
        _doSell(pair, seller, size, premium);

        // Capture the nonce BEFORE a second trade advances it, then
        // do an unrelated trade that bumps the nonce.
        uint256 staleNonce = pair.nonces(mm, 0);
        _doSell(pair, buyer, 1e18, 100e6); // bumps mm nonce

        // Build a close quote under the stale nonce.
        uint256 validTill = block.timestamp + 1 hours;
        uint128 ppu = uint128(uint256(premium) * 1e18 / uint256(size));
        bytes memory sig = _signQuote(
            address(funder), address(pair), mmPrivateKey,
            -int256(uint256(size)), ppu, validTill, true, 0, staleNonce
        );

        usdc.mint(seller, premium);
        vm.prank(seller);
        usdc.approve(address(pair), premium);

        vm.prank(seller);
        vm.expectRevert(); // OPair.InvalidSignature
        pair.buy(address(funder), mm, size, size, ppu, validTill, true, 0, sig);
    }
}
