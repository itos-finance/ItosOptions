// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Setup} from "./Setup.t.sol";
import {OPair} from "../src/OPair.sol";
import {Funder} from "../src/Funder.sol";
import {MultiFunder} from "../src/MultiFunder.sol";
import {IBulletin} from "../src/interfaces/IBulletin.sol";

contract IntegrationTest is Setup {
    // =========================================================================
    // Full call lifecycle: sell → exercise → claim
    // =========================================================================

    function test_callLifecycle_sellExerciseClaim() public {
        OPair pair = _createCallPair();
        uint128 size = 5e18;
        uint128 premium = 500e6;

        // 1. Seller shorts, mm longs via funder
        _doSell(pair, seller, size, premium);
        assertEq(pair.totalSold(), size);
        assertEq(pair.netPosition(mm), int256(uint256(size)));

        // 2. mm exercises all
        _fundCallbackForExercise(pair, size);
        vm.warp(pair.exerciseEarliest());
        vm.prank(mm);
        pair.exercise(size, address(callback), "");
        assertEq(pair.totalExercised(), size);
        assertEq(pair.netPosition(mm), 0);
        assertEq(usdc.balanceOf(address(callback)), 0);
        assertEq(weth.balanceOf(address(callback)), size);

        // 3. Seller claims
        vm.warp(expiryTimestamp);
        uint256 usdcBefore = usdc.balanceOf(seller);
        vm.prank(seller);
        pair.claim(size, false);
        uint256 expectedUsdc = (uint256(size) * STRIKE) / 1e18;
        assertEq(usdc.balanceOf(seller) - usdcBefore, expectedUsdc);

        // 4. Admin claims fees
        uint256 fee = (uint256(premium) * pair.FEE_BPS()) / pair.BPS();
        vm.prank(admin);
        pair.claimFees();
        assertEq(usdc.balanceOf(admin), fee);
    }

    // =========================================================================
    // Full put lifecycle: sell → exercise → claim
    // =========================================================================

    function test_putLifecycle_sellExerciseClaim() public {
        OPair putPair = _createPutPair();
        uint128 size = 2e18;
        uint128 premium = 100e6;

        // For puts: depositToken=cashToken(USDC), swapToken=riskToken(WETH)
        _doSell(putPair, seller, size, premium);
        assertEq(putPair.netPosition(mm), int256(uint256(size)));

        _fundCallbackForExercise(putPair, size);
        vm.warp(putPair.exerciseEarliest());
        vm.prank(mm);
        putPair.exercise(size, address(callback), "");

        vm.warp(expiryTimestamp);
        vm.prank(seller);
        putPair.claim(size, false);

        // Seller gets swap token (WETH) for exercised portion
        assertEq(weth.balanceOf(seller), size);
    }

    // =========================================================================
    // OTM expiry — seller gets collateral back
    // =========================================================================

    function test_callExpiredOTM_sellerGetsCollateralBack() public {
        OPair pair = _createCallPair();
        _doSell(pair, seller, 2e18, 200e6);

        vm.warp(expiryTimestamp);
        uint256 wethBefore = weth.balanceOf(seller);
        vm.prank(seller);
        pair.claim(2e18, false);
        assertEq(weth.balanceOf(seller) - wethBefore, 2e18);
    }

    // =========================================================================
    // Multiple sellers, preferExercised FIFO
    // =========================================================================

    function test_multipleSellers_exerciseClaimPreference() public {
        OPair pair = _createCallPair();
        address seller2 = makeAddr("seller2");

        _doSell(pair, seller, 3e18, 300e6);
        _doSell(pair, seller2, 2e18, 200e6);

        // Exercise 3 ETH — hits seller1's position first (preferExercised)
        _fundCallbackForExercise(pair, 3e18);
        vm.warp(pair.exerciseEarliest());
        vm.prank(mm);
        pair.exercise(3e18, address(callback), "");

        vm.warp(expiryTimestamp);

        // seller1: claim 3e18 preferring exercised
        vm.prank(seller);
        pair.claim(3e18, true);
        assertGt(usdc.balanceOf(seller), 0);

        // seller2: claim 2e18 — fully unexercised (prefer unexercised)
        uint256 wethBefore = weth.balanceOf(seller2);
        vm.prank(seller2);
        pair.claim(2e18, false);
        assertEq(weth.balanceOf(seller2) - wethBefore, 2e18);
    }

    function test_multipleSellers_partialExercise_correctSplit() public {
        OPair pair = _createCallPair();
        address seller2 = makeAddr("seller2");

        _doSell(pair, seller, 3e18, 300e6);
        _doSell(pair, seller2, 2e18, 200e6);

        // Exercise 4 out of 5 total
        _fundCallbackForExercise(pair, 4e18);
        vm.warp(pair.exerciseEarliest());
        vm.prank(mm);
        pair.exercise(4e18, address(callback), "");

        vm.warp(expiryTimestamp);

        // seller1 claims 3e18, preferring exercised → fully exercised
        uint256 usdcBefore1 = usdc.balanceOf(seller);
        vm.prank(seller);
        pair.claim(3e18, true);
        uint256 seller1Usdc = (uint256(3e18) * STRIKE) / 1e18;
        assertEq(usdc.balanceOf(seller) - usdcBefore1, seller1Usdc);

        // seller2 claims 2e18, preferring exercised → 1 exercised, 1 unexercised
        uint256 usdcBefore2 = usdc.balanceOf(seller2);
        uint256 wethBefore2 = weth.balanceOf(seller2);
        vm.prank(seller2);
        pair.claim(2e18, true);
        assertEq(
            usdc.balanceOf(seller2) - usdcBefore2,
            (uint256(1e18) * STRIKE) / 1e18
        );
        assertEq(weth.balanceOf(seller2) - wethBefore2, 1e18);
    }

    // =========================================================================
    // Multiple buyers (multiple mm wallets)
    // =========================================================================

    function test_multipleMMs_independentLongPositions() public {
        OPair pair = _createCallPair();

        uint256 mm2Key = 0xB0B;
        address mm2 = vm.addr(mm2Key);
        vm.prank(mm2);
        Funder funder2 = new Funder(address(factory));

        // mm1 long 2 ETH via _doSell
        _doSell(pair, seller, 2e18, 200e6);
        assertEq(pair.netPosition(mm), int256(2e18));

        // mm2 long 3 ETH: seller2 calls sell with funder2
        address seller2 = makeAddr("seller2");
        {
            uint256 depositAmt = 3e18;
            weth.mint(seller2, depositAmt);
            vm.prank(seller2);
            weth.approve(address(pair), depositAmt);
            usdc.mint(address(funder2), 300e6);

            uint256 validTill = block.timestamp + 1 hours;
            bytes memory sig = _signQuote(
                address(funder2),
                address(pair),
                mm2Key,
                int256(3e18),
                300e6,
                validTill,
                0
            );
            vm.prank(seller2);
            pair.sell(address(funder2), mm2, 3e18, 300e6, validTill, sig);
        }

        assertEq(pair.netPosition(mm), int256(2e18));
        assertEq(pair.netPosition(mm2), int256(3e18));
        assertEq(pair.totalSold(), 5e18);
    }

    // =========================================================================
    // Buy path lifecycle
    // =========================================================================

    function test_buyPath_buyerExercisesAfterFunderSells() public {
        OPair pair = _createCallPair();
        uint128 size = 1e18;
        uint128 premium = 100e6;

        // buyer calls buy, mm (via funder) provides collateral
        _doBuy(pair, buyer, size, premium);

        assertEq(pair.netPosition(buyer), int256(uint256(size)));
        assertEq(pair.netPosition(mm), -int256(uint256(size)));

        // buyer exercises
        _fundCallbackForExercise(pair, size);
        vm.warp(pair.exerciseEarliest());
        vm.prank(buyer);
        pair.exercise(size, address(callback), "");
        assertEq(pair.totalExercised(), size);
        assertEq(pair.netPosition(buyer), 0);

        // mm claims after expiry
        vm.warp(expiryTimestamp);
        vm.prank(mm);
        pair.claim(size, false);
        // mm gets swap token (USDC for call) for exercised portion
        assertGt(usdc.balanceOf(mm), 0);
    }

    // =========================================================================
    // MultiFunder integration
    // =========================================================================

    function test_multiFunder_buyPath_signerProvidesCollateral() public {
        OPair pair = _createCallPair();
        uint128 size = 1e18;
        uint128 premium = 100e6;

        // mm deposits WETH into multiFunder as the sell-side collateral
        uint256 depositAmt = size; // call: collateral = risk token
        weth.mint(mm, depositAmt);
        vm.startPrank(mm);
        weth.approve(address(multiFunder), depositAmt);
        multiFunder.deposit(mm, address(weth), depositAmt);
        vm.stopPrank();

        // buyer pays premium
        usdc.mint(buyer, premium);
        vm.prank(buyer);
        usdc.approve(address(pair), premium);

        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signQuote(
            address(multiFunder),
            address(pair),
            mmPrivateKey,
            -int256(uint256(size)),
            premium,
            validTill,
            pair.nonces(mm)
        );

        vm.prank(buyer);
        pair.buy(address(multiFunder), mm, size, premium, validTill, sig);

        assertEq(pair.netPosition(buyer), int256(uint256(size)));  // buyer is long
        assertEq(pair.netPosition(mm),    -int256(uint256(size))); // mm is short
        assertEq(weth.balanceOf(address(pair)), size);             // collateral locked

        // premium minus fee deposited back to mm's multiFunder balance
        uint256 fee = (uint256(premium) * pair.FEE_BPS()) / pair.BPS();
        assertEq(multiFunder.balances(mm, address(usdc)), premium - fee);
    }

    function test_multiFunder_sellsAndReceivesEarnings() public {
        OPair pair = _createCallPair();
        uint128 size = 1e18;
        uint128 premium = 100e6;

        // mm deposits into multiFunder for themselves as signer
        usdc.mint(mm, premium);
        vm.startPrank(mm);
        usdc.approve(address(multiFunder), premium);
        multiFunder.deposit(mm, address(usdc), premium);
        vm.stopPrank();

        // seller calls sell with multiFunder as the buyer's funder
        uint256 depositAmt = size; // call
        weth.mint(seller, depositAmt);
        vm.prank(seller);
        weth.approve(address(pair), depositAmt);

        uint256 validTill = block.timestamp + 1 hours;
        bytes memory sig = _signQuote(
            address(multiFunder),
            address(pair),
            mmPrivateKey,
            int256(uint256(size)),
            premium,
            validTill,
            0
        );

        vm.prank(seller);
        pair.sell(address(multiFunder), mm, size, premium, validTill, sig);

        assertEq(pair.netPosition(mm), int256(uint256(size)));
        assertEq(multiFunder.balances(mm, address(usdc)), 0); // premium consumed
    }

    // =========================================================================
    // Net position: exercise then sell more
    // =========================================================================

    function test_exerciseThenSellMore_totalSoldUpdatesCorrectly() public {
        OPair pair = _createCallPair();

        _doSell(pair, seller, 2e18, 200e6);

        _fundCallbackForExercise(pair, 1e18);
        vm.warp(pair.exerciseEarliest());
        vm.prank(mm);
        pair.exercise(1e18, address(callback), "");

        address seller2 = makeAddr("seller2");
        _doSell(pair, seller2, 3e18, 300e6);

        // totalSold is decremented only in claim/_settleNetted, not by exercise.
        // sell1: totalSold=2, exercise: unchanged, sell2: totalSold=2+3=5
        assertEq(pair.totalSold(), 5e18);
        assertEq(pair.totalExercised(), 1e18);
    }

    // =========================================================================
    // Bulletin → OPair: bid posted by buyer, filled by seller
    //
    // Flow:
    //   1. MM (buyer) signs a buy quote and posts it to the Bulletin as a bid.
    //   2. A seller sees the bid on-chain, reads the stored signature, and calls
    //      OPair.sell() with it — no separate signing step required.
    //   3. The same EIP-712 signature that Bulletin verified is accepted by the
    //      Funder's requestFunds(), completing the trade.
    // =========================================================================

    function test_bulletinBid_sellerFillsBid() public {
        OPair pair = _createCallPair();
        uint128 size = 2e18;
        uint128 premium = 200e6; // total cashToken the buyer will pay
        uint256 validTill = block.timestamp + 2 hours;
        int256 signedSize = int256(uint256(size)); // positive = buy intent

        // 1. MM signs the quote and posts it to the Bulletin.
        //    nonce=0 since pair.nonces(mm)==0 at this point.
        uint256 nonce = pair.nonces(mm);
        bytes memory sig = _signQuote(
            address(funder),
            address(pair),
            mmPrivateKey,
            signedSize,
            premium,
            validTill,
            nonce
        );
        usdc.mint(address(funder), premium); // ensure funder has funds

        bulletin.post(
            address(pair),
            mm,
            address(funder),
            premium,
            int128(signedSize),
            validTill,
            nonce,
            sig
        );

        // Verify the bid is stored on-chain.
        IBulletin.Order memory bid = bulletin.getOrder(
            address(pair),
            mm,
            nonce
        );
        assertEq(bid.signer, mm);
        assertEq(bid.funder, address(funder));
        assertEq(bid.premium, premium);
        assertEq(bid.size, int128(signedSize));
        assertEq(bid.nonce, nonce);

        // 2. Seller reads the bid off the Bulletin and fills it via OPair.sell().
        //    The exact same `sig` bytes that were posted are passed through.
        //    bid.size is positive (buy intent), safe to cast to uint128.
        uint128 absSize = uint128(bid.size);
        weth.mint(seller, absSize);
        vm.prank(seller);
        weth.approve(address(pair), absSize);

        vm.prank(seller);
        pair.sell(
            bid.funder,
            bid.signer,
            absSize,
            premium,
            bid.validTillTimestamp,
            bid.signature // ← the stored Bulletin signature
        );

        // 3. Verify positions and premium transfer.
        assertEq(pair.netPosition(seller), -int256(uint256(size))); // seller is short
        assertEq(pair.netPosition(mm), int256(uint256(size))); // mm is long

        uint256 fee = (uint256(premium) * pair.FEE_BPS()) / pair.BPS();
        assertEq(usdc.balanceOf(seller), premium - fee); // seller received premium minus fee
        assertEq(usdc.balanceOf(address(funder)), 0); // funder's pool was drained by the trade
    }

    // =========================================================================
    // Bulletin → OPair: offer posted by seller/writer, filled by buyer
    //
    // Flow:
    //   1. MM (seller/writer) signs a sell quote and posts it to the Bulletin
    //      as an offer.
    //   2. A buyer sees the offer on-chain, reads the stored signature, approves
    //      their premium, and calls OPair.buy() — passing the stored signature
    //      directly for the collateral side.
    //   3. The Funder releases collateral using the stored signature; the buyer's
    //      premium transfer is a separate direct transfer (not signed).
    // =========================================================================

    function test_bulletinOffer_buyerFillsOffer() public {
        OPair pair = _createCallPair();
        uint128 size = 1e18;
        uint128 premium = 80e6; // buyer pays this directly; not part of the offer signature
        uint256 validTill = block.timestamp + 2 hours;
        int256 signedSize = -int256(uint256(size)); // negative = sell intent

        // 1. MM signs the offer quote and posts it to the Bulletin.
        uint256 nonce = pair.nonces(mm);
        bytes memory sig = _signQuote(
            address(funder),
            address(pair),
            mmPrivateKey,
            signedSize,
            premium,
            validTill,
            nonce
        );
        weth.mint(address(funder), size); // funder must hold the collateral (1 WETH for a call)

        bulletin.post(
            address(pair),
            mm,
            address(funder),
            premium,
            int128(signedSize),
            validTill,
            nonce,
            sig
        );

        // Verify the offer is stored on-chain.
        IBulletin.Order memory offer = bulletin.getOrder(
            address(pair),
            mm,
            nonce
        );
        assertEq(offer.signer, mm);
        assertEq(offer.funder, address(funder));
        assertEq(offer.premium, premium);
        assertEq(offer.nonce, nonce);

        // 2. Buyer reads the offer and fills it via OPair.buy().
        //    Buyer pays `premium` directly; the stored sig authorises the funder
        //    to release the collateral.
        //    offer.size is negative (sell intent), negate to get the absolute size.
        uint128 absSize = uint128(-offer.size);
        usdc.mint(buyer, premium);
        vm.prank(buyer);
        usdc.approve(address(pair), premium);

        vm.prank(buyer);
        pair.buy(
            offer.funder,
            offer.signer,
            absSize,
            premium, // buyer pays this out-of-pocket
            offer.validTillTimestamp,
            offer.signature // ← the stored Bulletin signature
        );

        // 3. Verify positions and collateral/premium flows.
        assertEq(pair.netPosition(buyer), int256(uint256(size))); // buyer is long
        assertEq(pair.netPosition(mm), -int256(uint256(size))); // mm (seller) is short

        // Funder's pool received the premium minus fee (deposited back by OPair).
        uint256 fee = (uint256(premium) * pair.FEE_BPS()) / pair.BPS();
        assertEq(usdc.balanceOf(address(funder)), premium - fee);

        // Funder's WETH was consumed as collateral.
        assertEq(weth.balanceOf(address(funder)), 0);
    }

    // =========================================================================
    // Bulletin queued orders: two bids pre-signed at nonce 0 and nonce 1
    //
    // MM signs both orders before any trade executes. The first bid is for the
    // current nonce (0); the second is deliberately pre-signed for nonce 1 even
    // though the nonce won't reach 1 until the first trade settles.
    //
    // Because the Bulletin stores orders at (vault, signer, nonce), both can be
    // posted upfront — they coexist at nonce 0 and nonce 1. sellerA fills bid0
    // (advancing the Funder nonce to 1), then sellerB fills bid1.
    // =========================================================================

    function test_bulletinQueuedOrders_twoConsecutiveBids() public {
        OPair pair = _createCallPair();
        uint256 validTill = block.timestamp + 2 hours;

        uint128 size = 1e18;
        uint128 premium0 = 100e6;
        uint128 premium1 = 120e6; // slightly different second order
        int256 signedSize = int256(uint256(size)); // positive = buy intent

        // ── Pre-sign both orders (before any trade executes) ─────────────────
        assertEq(pair.nonces(mm), 0);

        bytes memory sig0 = _signQuote(
            address(funder),
            address(pair),
            mmPrivateKey,
            signedSize,
            premium0,
            validTill,
            0 // nonce 0 — valid right now
        );
        bytes memory sig1 = _signQuote(
            address(funder),
            address(pair),
            mmPrivateKey,
            signedSize,
            premium1,
            validTill,
            1 // nonce 1 — valid only after bid0 fills
        );

        // ── Fund the funder for both premiums ────────────────────────────────
        usdc.mint(address(funder), uint256(premium0) + premium1);

        // ── Post both bids upfront — they coexist at different nonces ────────
        bulletin.post(
            address(pair),
            mm,
            address(funder),
            premium0,
            int128(signedSize),
            validTill,
            0,
            sig0
        );
        bulletin.post(
            address(pair),
            mm,
            address(funder),
            premium1,
            int128(signedSize),
            validTill,
            1,
            sig1
        );
        assertEq(bulletin.getOrder(address(pair), mm, 0).nonce, 0);
        assertEq(bulletin.getOrder(address(pair), mm, 1).nonce, 1);

        // ── sellerA fills bid0 ────────────────────────────────────────────────
        address sellerA = makeAddr("sellerA");
        weth.mint(sellerA, size);
        vm.prank(sellerA);
        weth.approve(address(pair), size);

        IBulletin.Order memory bid0 = bulletin.getOrder(address(pair), mm, 0);
        vm.prank(sellerA);
        pair.sell(
            bid0.funder,
            bid0.signer,
            uint128(bid0.size),
            premium0,
            bid0.validTillTimestamp,
            bid0.signature
        );

        assertEq(pair.nonces(mm), 1); // nonce advanced
        assertEq(pair.netPosition(mm), int256(uint256(size))); // mm is long 1 ETH

        // ── sellerB fills bid1 (already on the Bulletin at nonce 1) ──────────
        address sellerB = makeAddr("sellerB");
        weth.mint(sellerB, size);
        vm.prank(sellerB);
        weth.approve(address(pair), size);

        IBulletin.Order memory bid1 = bulletin.getOrder(address(pair), mm, 1);
        vm.prank(sellerB);
        pair.sell(
            bid1.funder,
            bid1.signer,
            uint128(bid1.size),
            premium1,
            bid1.validTillTimestamp,
            bid1.signature
        );

        assertEq(pair.nonces(mm), 2); // nonce advanced again
        assertEq(pair.netPosition(mm), int256(2 * uint256(size))); // mm is now long 2 ETH

        // Both sellers are short
        assertEq(pair.netPosition(sellerA), -int256(uint256(size)));
        assertEq(pair.netPosition(sellerB), -int256(uint256(size)));

        // Funder paid out both premiums; only fees remain in the pair
        assertEq(usdc.balanceOf(address(funder)), 0);
    }
}
