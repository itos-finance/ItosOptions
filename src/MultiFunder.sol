// SPDX-License-Identifier: BUSL-1.1
// Change Date: 2030-03-17  (license converts to GPL-2.0-or-later on this date)
pragma solidity ^0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FunderBase} from "./FunderBase.sol";
import {IMultiFunder} from "./interfaces/IMultiFunder.sol";
import {IFunderBase} from "./interfaces/IFunderBase.sol";

/// @title MultiFunder
/// @notice Shared funding contract: multiple wallets each maintain their own per-token balance.
///         All operations are permissionless per-user (each user manages only their own funds).
///
/// @dev OPair verifies signatures and manages nonces. MultiFunder only transfers funds when
///      called by a valid pair (factory.isPair), debiting the signer's balance.
contract MultiFunder is IMultiFunder, FunderBase {
    using SafeERC20 for IERC20;

    /// @inheritdoc IMultiFunder
    mapping(address => mapping(address => uint256)) public balances;

    constructor(address _factory) FunderBase(_factory) {}

    // --- Token management ---

    /// @inheritdoc IFunderBase
    /// @dev Pulls tokens from msg.sender and credits them to `signer`'s balance.
    function deposit(address signer, address token, uint256 amount) external {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        balances[signer][token] += amount;
        emit FundsDeposited(signer, token, amount);
    }

    /// @inheritdoc IFunderBase
    function withdraw(address token, uint256 amount) external {
        if (balances[msg.sender][token] < amount) revert InsufficientBalance();
        balances[msg.sender][token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit FundsWithdrawn(msg.sender, token, amount);
    }

    // --- Pair interface ---

    /// @inheritdoc IFunderBase
    function requestFunds(
        address signer,
        address token,
        uint256 acquireAmount
    ) external onlyValidPair {
        if (balances[signer][token] < acquireAmount)
            revert InsufficientBalance();

        balances[signer][token] -= acquireAmount;
        if (acquireAmount > 0)
            IERC20(token).safeTransfer(msg.sender, acquireAmount);
        emit FundsRequested(msg.sender, signer, token, acquireAmount);
    }
}
