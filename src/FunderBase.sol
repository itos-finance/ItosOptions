// SPDX-License-Identifier: BUSL-1.1
// Change Date: 2030-03-17  (license converts to GPL-2.0-or-later on this date)
pragma solidity ^0.8.34;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IOPairFactory} from "./interfaces/IOPairFactory.sol";
import {IFunderBase} from "./interfaces/IFunderBase.sol";

/// @title FunderBase
/// @notice Shared base for Funder and MultiFunder. Holds the factory reference,
///         the onlyValidPair guard, and AccessControl (DEFAULT_ADMIN_ROLE granted
///         to the deployer). The admin may update the factory address via setFactory.
abstract contract FunderBase is IFunderBase, AccessControl {
    error NotValidPair();

    /// @notice The factory whose pairs are authorised to call requestFunds.
    IOPairFactory public factory;

    constructor(address _factory) {
        factory = IOPairFactory(_factory);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @inheritdoc IFunderBase
    function setFactory(
        address _factory
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        factory = IOPairFactory(_factory);
        emit FactoryUpdated(_factory);
    }

    /// @dev Reverts if the caller is not a pair created by this factory.
    modifier onlyValidVault() {
        _onlyValidVault();
        _;
    }

    function _onlyValidVault() internal view {
        if (!factory.isVault(msg.sender)) revert NotValidVault();
    }
}
