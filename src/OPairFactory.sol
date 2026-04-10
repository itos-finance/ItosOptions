// SPDX-License-Identifier: BUSL-1.1
// Change Date: 2030-03-17  (license converts to GPL-2.0-or-later on this date)
pragma solidity ^0.8.34;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {OPair} from "./OPair.sol";

contract OPairFactory is AccessControl {
    /// @notice Role that may call createPair. Granted to the deployer by default.
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");

    // All pairs deployed by this factory.
    mapping(address => bool) public isPair;

    // Backward-compatible alias used by Funder.sol (checks isVault(msg.sender)).
    function isVault(address pair) external view returns (bool) {
        return isPair[pair];
    }

    // Lookup: keccak256(riskToken, cashToken, strike, expiry, isCall) → pair address.
    mapping(bytes32 => address) public pairs;
    event PairCreated(address indexed pair);

    error ZeroAddress();
    error SameToken();
    error ExpiryInPast();
    error PairExists();

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ISSUER_ROLE, msg.sender);
    }

    function createPair(
        address riskToken,
        address cashToken,
        uint128 strike,
        uint256 expiry,
        bool isCall,
        uint128 minDepositSize,
        string calldata identifier,
        string calldata symbol
    ) external onlyRole(ISSUER_ROLE) returns (address pair) {
        if (riskToken == address(0) || cashToken == address(0))
            revert ZeroAddress();
        if (riskToken == cashToken) revert SameToken();
        if (expiry <= block.timestamp) revert ExpiryInPast();

        bytes32 key = keccak256(
            abi.encode(riskToken, cashToken, strike, expiry, isCall)
        );
        if (pairs[key] != address(0)) revert PairExists();

        pair = address(
            new OPair(
                riskToken,
                cashToken,
                strike,
                expiry,
                isCall,
                minDepositSize,
                identifier,
                symbol
            )
        );

        pairs[key] = pair;
        isPair[pair] = true;

        emit PairCreated(pair);
    }
}
