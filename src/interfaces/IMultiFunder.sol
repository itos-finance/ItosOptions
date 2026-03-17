// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IFunderBase} from "./IFunderBase.sol";

/// @title IMultiFunder
/// @notice Shared funding contract for multiple wallets. Each user manages their own balance.
interface IMultiFunder is IFunderBase {
    // --- Errors ---
    error InsufficientBalance();

    // --- Events ---
    event FundsWithdrawn(address indexed wallet, address indexed token, uint256 amount);

    // --- Getters ---
    function balances(address wallet, address token) external view returns (uint256);
}
