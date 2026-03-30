// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IExerciseCallback} from "./interfaces/IExerciseCallback.sol";

/// @notice Minimal interface for MockERC20's permissionless mint.
interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// @title MintExerciseCallback
/// @notice Testnet-only exercise callback that mints the required swap token
///         via MockERC20's permissionless mint, then returns it to the vault.
contract MintExerciseCallback is IExerciseCallback {
    function onExercise(
        address /* tokenGiven */,
        address tokenExpected,
        uint256 /* amountGiven */,
        uint256 amountExpected,
        bytes calldata /* data */
    ) external override {
        IMintable(tokenExpected).mint(address(this), amountExpected);
        IERC20(tokenExpected).transfer(msg.sender, amountExpected);
    }
}
