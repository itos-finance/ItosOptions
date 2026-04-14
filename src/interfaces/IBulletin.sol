// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title IBulletin
/// @notice On-chain order book where MMs post signed orders for OPairs.
///         Orders are indexed by (vault, signer, nonce), so multiple orders
///         per signer per vault can coexist at different nonces.
///
///         Size sign encodes intent: positive = buy (bid), negative = sell (offer).
///
/// @dev The stored signatures can be used directly with OPair.sell / OPair.buy.
///      Signatures commit to premiumPerUnit (rate per 1e18 units of size), not the total premium.
interface IBulletin {
    // --- Structs ---

    struct Order {
        address funder; // Funder or MultiFunder contract holding the funds
        address signer; // Authorised signer on the funder whose quote is stored
        uint128 premiumPerUnit; // Premium per 1e18 units of size (rate, not total)
        int128 size; // Signed notional size: positive = buy (bid), negative = sell (offer)
        uint256 validTillTimestamp;
        uint256 channel; // Nonce channel this signature was made for
        uint256 nonce; // Per-channel nonce this signature was made for
        bool allowPartialFill; // Always false for Bulletin orders
        bytes signature;
    }

    // --- Errors ---
    error VaultNotFromFactory();
    error ZeroSize();

    // --- Events ---
    /// @param vault   The OPair this order is for.
    /// @param signer  The address whose signature was verified.
    /// @param order   The stored order details.
    event OrderPosted(
        address indexed vault,
        address indexed signer,
        Order order
    );

    // --- Functions ---

    /// @notice Post a signed order for a vault on behalf of `signer`.
    ///         Size sign encodes intent: positive = bid (buy), negative = offer (sell).
    ///         Reverts if size is zero or the signature does not recover to `signer`.
    ///         Stored at (vault, signer, nonce) — does not replace orders at other nonces.
    /// @param vault              The OPair to post the order for.
    /// @param signer             Address whose EIP-712 signature is provided.
    /// @param funder             Funder/MultiFunder holding the funds.
    /// @param premiumPerUnit     Premium per 1e18 units of size (rate, not total).
    /// @param size               Signed notional size: positive = bid, negative = offer.
    /// @param validTillTimestamp Quote expiry.
    /// @param channel             Nonce channel this signature was made for.
    /// @param nonce              Per-channel nonce this signature was made for.
    /// @param signature          EIP-712 signature over the quote.
    function post(
        address vault,
        address signer,
        address funder,
        uint128 premiumPerUnit,
        int128 size,
        uint256 validTillTimestamp,
        uint256 channel,
        uint256 nonce,
        bytes calldata signature
    ) external;

    /// @notice Returns the order posted by `signer` for `vault` at `(channel, nonce)`, or a zeroed struct if none.
    function getOrder(
        address vault,
        address signer,
        uint256 channel,
        uint256 nonce
    ) external view returns (Order memory);
}
