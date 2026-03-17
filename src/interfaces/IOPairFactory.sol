// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @notice Minimal factory interface used by FundingVerifier to validate vault callers.
interface IOPairFactory {
    function isVault(address pair) external view returns (bool);
}
