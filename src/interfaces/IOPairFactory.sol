// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @notice Minimal factory interface used by FunderBase and Bulletin to validate pair callers.
interface IOPairFactory {
    function isPair(address pair) external view returns (bool);
}
