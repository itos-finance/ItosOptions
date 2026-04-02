// SPDX-License-Identifier: BUSL-1.1
// Change Date: 2030-03-17  (license converts to GPL-2.0-or-later on this date)
pragma solidity ^0.8.34;

import {SigVerifier} from "./SigVerifier.sol";
import {IBulletin} from "./interfaces/IBulletin.sol";
import {IOPairFactory} from "./interfaces/IOPairFactory.sol";

/// @title Bulletin
/// @notice On-chain order book for OPair orders. Inherits SigVerifier so that
///         the EIP-712 signing procedure is identical to the one used in OPair —
///         a signature posted here can be passed directly to OPair.sell / OPair.buy.
///
///         Size sign encodes intent: positive = bid (buy), negative = offer (sell).
///         Orders are stored at (vault, signer, nonce), so a signer can queue orders
///         at future nonces without invalidating earlier ones.
///
/// @dev Fund availability is verified off-chain before posting. No on-chain reservation.
contract Bulletin is IBulletin, SigVerifier {
    IOPairFactory public immutable factory;
    // vault → signer → nonce → Order
    mapping(address => mapping(address => mapping(uint256 => Order))) private _orders;

    constructor(address _factory) {
        factory = IOPairFactory(_factory);
    }

    // ------------------------------------------------------------------ //
    //  Public write functions
    // ------------------------------------------------------------------ //

    /// @inheritdoc IBulletin
    function post(
        address vault,
        address signer,
        address funder,
        uint128 premiumPerUnit,
        int128 size,
        uint256 validTillTimestamp,
        uint256 nonce,
        bytes calldata signature
    ) external {
        if (size == 0) revert ZeroSize();
        if (!factory.isVault(vault)) revert VaultNotFromFactory();
        if (
            signer !=
            _recoverSigner(
                funder,
                vault,
                int256(size),
                premiumPerUnit,
                validTillTimestamp,
                nonce,
                false, // Bulletin orders never allow partial fills
                signature
            )
        ) revert InvalidSignature();

        _orders[vault][signer][nonce] = Order({
            funder: funder,
            signer: signer,
            premiumPerUnit: premiumPerUnit,
            size: size,
            validTillTimestamp: validTillTimestamp,
            nonce: nonce,
            allowPartialFill: false,
            signature: signature
        });

        emit OrderPosted(vault, signer, _orders[vault][signer][nonce]);
    }

    // ------------------------------------------------------------------ //
    //  Views
    // ------------------------------------------------------------------ //

    /// @inheritdoc IBulletin
    function getOrder(
        address vault,
        address signer,
        uint256 nonce
    ) external view returns (Order memory) {
        return _orders[vault][signer][nonce];
    }
}
