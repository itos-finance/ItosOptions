// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title IFunderBase
/// @notice Shared interface implemented by both Funder and MultiFunder.
///         OPair depends only on this for deposit and requestFunds calls.
interface IFunderBase {
    // --- Events ---
    /// @param signer  The signer credited. For Funder (shared pool) this is informational only.
    event FundsDeposited(
        address indexed signer,
        address indexed token,
        uint256 amount
    );
    /// @param vault   Vault that requested funds.
    /// @param signer  Signer whose quote was consumed.
    /// @param token   Token transferred.
    /// @param amount  Total amount transferred.
    event FundsRequested(
        address indexed vault,
        address indexed signer,
        address indexed token,
        uint256 amount
    );

    // --- Token management ---
    /// @notice Deposit `amount` of `token` from msg.sender, crediting `signer`.
    ///         For Funder (shared pool) `signer` is informational; for MultiFunder it
    ///         determines whose balance is credited.
    function deposit(address signer, address token, uint256 amount) external;

    /// @notice Withdraw tokens. For Funder only callable by owner; for MultiFunder
    ///         callable by any user against their own balance.
    function withdraw(address token, uint256 amount) external;

    // --- Vault interface ---
    /// @notice Verify a Quote signature and transfer `acquireAmount` of `token` to the caller.
    ///
    /// @param amount        Total premium the signer committed to. Part of the signed digest.
    /// @param size          Signed notional trade size (risk-token units). Positive = buy intent,
    ///                      negative = sell intent. Part of the signed digest.
    /// @param acquireAmount Actual tokens to transfer to the vault. May be less than `amount` when
    ///                      netting reduces the physical collateral needed, or zero for a fully-netted
    ///                      trade. The signature is still verified regardless.
    function requestFunds(
        address signer,
        address token,
        uint256 amount,
        int256 size,
        uint256 acquireAmount,
        uint256 validTillTimestamp,
        bytes calldata signature
    ) external;

    // --- Nonce management ---
    /// @notice Advance the caller's own nonce for `vault` by `amount`, invalidating all prior signatures.
    ///         Self-service: only msg.sender's nonce is affected.
    function bumpNonce(address vault, uint256 amount) external;

    event NonceBumped(
        address indexed signer,
        address indexed vault,
        uint256 newNonce
    );

    // --- Getters ---
    /// @notice Per-signer per-vault nonce. Incremented on each successful requestFunds.
    function nonces(
        address signer,
        address vault
    ) external view returns (uint256);
    // DOMAIN_SEPARATOR and QUOTE_TYPEHASH are public state variables on FundingVerifier.
}
