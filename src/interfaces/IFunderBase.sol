// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title IFunderBase
/// @notice Shared interface implemented by both Funder and MultiFunder.
///         OPair depends only on this for deposit and requestFunds calls.
///
///         Signature verification and nonce management have moved to OPair.
///         Funders now simply transfer funds when called by a valid vault.
interface IFunderBase {
    // --- Events ---
    event FactoryUpdated(address indexed factory);

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

    // --- Admin ---
    /// @notice Update the factory address. Only callable by DEFAULT_ADMIN_ROLE.
    function setFactory(address _factory) external;

    // --- Token management ---
    /// @notice Deposit `amount` of `token` from msg.sender, crediting `signer`.
    ///         For Funder (shared pool) `signer` is informational; for MultiFunder it
    ///         determines whose balance is credited.
    function deposit(address signer, address token, uint256 amount) external;

    /// @notice Withdraw tokens. For Funder only callable by owner; for MultiFunder
    ///         callable by any user against their own balance.
    function withdraw(address token, uint256 amount) external;

    // --- Vault interface ---
    /// @notice Transfer `acquireAmount` of `token` to the calling vault (msg.sender).
    ///         OPair has already verified the signer's signature and consumed their nonce
    ///         before calling this. Funders only need to check that the caller is a valid
    ///         vault (factory.isPair) and that funds are available.
    ///
    /// @param signer        The signer whose funds are being used. For MultiFunder this
    ///                      determines which per-signer balance to debit.
    /// @param token         Token to transfer.
    /// @param acquireAmount Actual tokens to transfer to the vault. May be zero for a
    ///                      fully-netted trade (no physical collateral movement needed).
    function requestFunds(
        address signer,
        address token,
        uint256 acquireAmount
    ) external;
}
