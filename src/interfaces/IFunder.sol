// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IFunderBase} from "./IFunderBase.sol";

/// @title IFunder
/// @notice Single-owner funding contract. The owner holds one shared token pool and may
///         whitelist additional signers.
interface IFunder is IFunderBase {
    // --- Errors ---
    error NotOwner();
    error NotAuthorizedSigner();

    // --- Events ---
    event FundsWithdrawn(address indexed token, uint256 amount);
    event SignerAdded(address indexed signer);
    event SignerRemoved(address indexed signer);

    // --- Admin ---
    function addSigner(address signer) external;
    function removeSigner(address signer) external;

    // --- Getters ---
    function owner() external view returns (address);
    function authorizedSigners(address signer) external view returns (bool);
}
