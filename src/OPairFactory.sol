// SPDX-License-Identifier: BUSL-1.1
// Change Date: 2030-03-17  (license converts to GPL-2.0-or-later on this date)
pragma solidity ^0.8.34;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {OPair} from "./OPair.sol";

contract OPairFactory is Ownable2Step {
    // All pairs deployed by this factory.
    mapping(address => bool) public isPair;

    // Backward-compatible alias used by Funder.sol (checks isVault(msg.sender)).
    function isVault(address pair) external view returns (bool) {
        return isPair[pair];
    }

    // Lookup: keccak256(riskToken, cashToken, strike, expiry, isCall) → pair address.
    mapping(bytes32 => address) public pairs;

    event PairCreated(
        address indexed pair,
        address indexed riskToken,
        address indexed cashToken,
        uint128 strike,
        uint256 expiry,
        bool isCall,
        uint128 minDepositSize
    );

    error ZeroAddress();
    error SameToken();
    error ExpiryInPast();
    error PairExists();

    constructor() Ownable(msg.sender) {}

    function createPair(
        address riskToken,
        address cashToken,
        uint128 strike,
        uint256 expiry,
        bool isCall,
        uint128 minDepositSize,
        string calldata identifier,
        string calldata symbol
    ) external onlyOwner returns (address pair) {
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

        emit PairCreated(
            pair,
            riskToken,
            cashToken,
            strike,
            expiry,
            isCall,
            minDepositSize
        );
    }
}
