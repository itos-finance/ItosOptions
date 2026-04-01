// SPDX-License-Identifier: BUSL-1.1
// Change Date: 2030-03-17  (license converts to GPL-2.0-or-later on this date)
pragma solidity ^0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FunderBase} from "./FunderBase.sol";
import {IFunder} from "./interfaces/IFunder.sol";
import {IFunderBase} from "./interfaces/IFunderBase.sol";

/// @title Funder
/// @notice Single-owner funding contract. The admin holds one shared token pool and may
///         grant SIGNER_ROLE to additional keys (e.g. trading bots) that can authorise
///         transfers on their behalf.
///
/// @dev OPair verifies signatures and manages nonces. Funder only transfers funds when
///      called by a valid vault (factory.isPair) for an address holding SIGNER_ROLE.
contract Funder is IFunder, FunderBase {
    using SafeERC20 for IERC20;

    bytes32 public constant SIGNER_ROLE = keccak256("SIGNER_ROLE");

    constructor(address _factory) FunderBase(_factory) {
        _grantRole(SIGNER_ROLE, msg.sender);
    }

    // --- Token management ---

    /// @inheritdoc IFunderBase
    /// @dev `signer` is ignored for Funder (shared pool); tokens go to the pool.
    function deposit(address signer, address token, uint256 amount) external override {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit FundsDeposited(signer, token, amount);
    }

    /// @inheritdoc IFunder
    function withdraw(address token, uint256 amount) external override(IFunderBase, IFunder) onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC20(token).safeTransfer(msg.sender, amount);
        emit FundsWithdrawn(token, amount);
    }

    // --- Vault interface ---

    /// @inheritdoc IFunderBase
    function requestFunds(
        address signer,
        address token,
        uint256 acquireAmount
    ) external override onlyValidVault {
        if (!hasRole(SIGNER_ROLE, signer))
            revert AccessControlUnauthorizedAccount(signer, SIGNER_ROLE);

        if (acquireAmount > 0)
            IERC20(token).safeTransfer(msg.sender, acquireAmount);
        emit FundsRequested(msg.sender, signer, token, acquireAmount);
    }
}
