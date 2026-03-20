// SPDX-License-Identifier: BUSL-1.1
// Change Date: 2030-03-17  (license converts to GPL-2.0-or-later on this date)
pragma solidity ^0.8.34;

import {FundingVerifier} from "./FundingVerifier.sol";
import {IBulletin} from "./interfaces/IBulletin.sol";

/// @title Bulletin
/// @notice On-chain order book for OPair bids and offers. Inherits FundingVerifier so that
///         the EIP-712 signing procedure is identical to the one used in requestFunds — a
///         signature posted here can be passed directly to OPair.sell / OPair.buy.
///
///         The caller supplies the nonce the signature was made for, so orders can be posted
///         for any nonce — including a future one (e.g. preemptively queuing a bid to become
///         active after an existing offer executes and increments the nonce).
///
/// @dev Fund availability is verified off-chain before posting. No on-chain reservation.
contract Bulletin is IBulletin, FundingVerifier {
    // vault → poster → Order
    mapping(address => mapping(address => Order)) private _bids;
    mapping(address => mapping(address => Order)) private _offers;

    constructor(address _factory) FundingVerifier(_factory) {}

    // ------------------------------------------------------------------ //
    //  Public write functions
    // ------------------------------------------------------------------ //

    /// @inheritdoc IBulletin
    function postBid(
        address vault,
        address signer,
        address funder,
        uint128 premium,
        int128 size,
        uint256 validTillTimestamp,
        uint256 nonce,
        bytes calldata signature
    ) external {
        if (!factory.isVault(vault)) revert VaultNotFromFactory();
        if (
            signer !=
            _recoverSigner(
                funder,
                vault,
                int256(size),
                premium,
                validTillTimestamp,
                nonce,
                signature
            )
        ) revert InvalidSignature();

        _bids[vault][signer] = Order({
            funder: funder,
            signer: signer,
            premium: premium,
            size: size,
            validTillTimestamp: validTillTimestamp,
            nonce: nonce,
            signature: signature
        });

        emit BidPosted(vault, signer, _bids[vault][signer]);
    }

    /// @inheritdoc IBulletin
    function postOffer(
        address vault,
        address signer,
        address funder,
        uint128 premium,
        int128 size,
        uint256 validTillTimestamp,
        uint256 nonce,
        bytes calldata signature
    ) external {
        if (!factory.isVault(vault)) revert VaultNotFromFactory();
        if (
            signer !=
            _recoverSigner(
                funder,
                vault,
                int256(size),
                premium,
                validTillTimestamp,
                nonce,
                signature
            )
        ) revert InvalidSignature();

        _offers[vault][signer] = Order({
            funder: funder,
            signer: signer,
            premium: premium,
            size: size,
            validTillTimestamp: validTillTimestamp,
            nonce: nonce,
            signature: signature
        });

        emit OfferPosted(vault, signer, _offers[vault][signer]);
    }

    // ------------------------------------------------------------------ //
    //  Views
    // ------------------------------------------------------------------ //

    /// @inheritdoc IBulletin
    function getBid(
        address vault,
        address poster
    ) external view returns (Order memory) {
        return _bids[vault][poster];
    }

    /// @inheritdoc IBulletin
    function getOffer(
        address vault,
        address poster
    ) external view returns (Order memory) {
        return _offers[vault][poster];
    }
}
