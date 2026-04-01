// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IFunderBase} from "./IFunderBase.sol";
import {
    IAccessControl
} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title IFunder
/// @notice Single-owner funding contract using AccessControl.
///         DEFAULT_ADMIN_ROLE: can grant/revoke roles and withdraw funds.
///         SIGNER_ROLE: authorised to have their quotes accepted via requestFunds.
interface IFunder is IFunderBase, IAccessControl {
    // --- Events ---
    event FundsWithdrawn(address indexed token, uint256 amount);

    // --- Roles ---
    function SIGNER_ROLE() external view returns (bytes32);

    // --- Admin ---
    function withdraw(address token, uint256 amount) external;
}
