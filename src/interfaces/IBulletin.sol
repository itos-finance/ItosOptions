// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title IBulletin
/// @notice On-chain order book where MMs post signed bids/offers for OPairs.
///         Each address may hold at most one bid and one offer per vault.
///
/// @dev The stored signatures can be used directly with OPair.sell / OPair.buy.
///      Signatures commit to the total premium for the entire size.
interface IBulletin {
    // --- Structs ---

    struct Order {
        address funder;          // Funder or MultiFunder contract holding the funds
        address signer;          // Authorised signer on the funder whose quote is stored
        uint128 premium;         // Total premium for the entire size
        int128  size;            // Signed notional size: positive = buy, negative = sell
        uint256 validTillTimestamp;
        uint256 nonce;           // Funder nonce this signature was made for
        bytes   signature;
    }

    // --- Errors ---
    error VaultNotFromFactory();

    // --- Events ---
    /// @param vault   The OPair this order is for.
    /// @param signer  The address whose signature was verified.
    /// @param order   The stored order details.
    event BidPosted(address indexed vault, address indexed signer, Order order);
    event OfferPosted(address indexed vault, address indexed signer, Order order);

    // --- Functions ---

    /// @notice Post a bid (willingness to buy) for a vault on behalf of `signer`.
    ///         Reverts if the signature does not recover to `signer`.
    ///         Replaces any existing bid from `signer` for the same vault.
    /// @param vault              The OPair to bid on.
    /// @param signer             Address whose EIP-712 signature is provided.
    /// @param funder             Funder/MultiFunder holding the premium funds.
    /// @param premium            Total premium for the entire size.
    /// @param size               Signed notional size: positive = buy, negative = sell.
    /// @param validTillTimestamp Quote expiry.
    /// @param nonce              Funder nonce this signature was made for.
    /// @param signature          EIP-712 signature over the quote.
    function postBid(
        address vault,
        address signer,
        address funder,
        uint128 premium,
        int128 size,
        uint256 validTillTimestamp,
        uint256 nonce,
        bytes calldata signature
    ) external;

    /// @notice Post an offer (willingness to sell/write) for a vault on behalf of `signer`.
    ///         Reverts if the signature does not recover to `signer`.
    ///         Replaces any existing offer from `signer` for the same vault.
    /// @param vault              The OPair to offer on.
    /// @param signer             Address whose EIP-712 signature is provided.
    /// @param funder             Funder/MultiFunder holding the collateral funds.
    /// @param premium            Total premium for the entire size.
    /// @param size               Signed notional size: positive = buy, negative = sell.
    /// @param validTillTimestamp Quote expiry.
    /// @param nonce              Funder nonce this signature was made for.
    /// @param signature          EIP-712 signature over the quote.
    function postOffer(
        address vault,
        address signer,
        address funder,
        uint128 premium,
        int128 size,
        uint256 validTillTimestamp,
        uint256 nonce,
        bytes calldata signature
    ) external;

    /// @notice Returns the active bid posted by `poster` for `vault`, or a zeroed struct if none.
    function getBid(address vault, address poster) external view returns (Order memory);

    /// @notice Returns the active offer posted by `poster` for `vault`, or a zeroed struct if none.
    function getOffer(address vault, address poster) external view returns (Order memory);
}
