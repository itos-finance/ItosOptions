// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IExerciseCallback} from "../../src/interfaces/IExerciseCallback.sol";

/// @notice Minimal interface for MockERC20's permissionless mint.
interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// @title MintExerciseCallback
/// @notice Testnet-only exercise callback. Mints the required swap token via
///         MockERC20's permissionless mint and returns it to the vault, then
///         best-effort burns the received deposit token (holds it if the token
///         has no `burn(uint256)` function).
contract MintExerciseCallback is IExerciseCallback {
    function onExercise(
        address tokenGiven,
        address tokenExpected,
        uint256 amountGiven,
        uint256 amountExpected,
        bytes calldata /* data */
    ) external override {
        IMintable(tokenExpected).mint(address(this), amountExpected);
        IERC20(tokenExpected).transfer(msg.sender, amountExpected);

        (bool ok, ) = tokenGiven.call(
            abi.encodeWithSignature("burn(uint256)", amountGiven)
        );
        ok; // best-effort: on failure the tokens simply stay in this contract
    }
}
