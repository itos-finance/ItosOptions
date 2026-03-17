// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IExerciseCallback} from "../../src/interfaces/IExerciseCallback.sol";

/// @dev Mock callback that swaps tokens during exercise. Can be configured to underpay.
contract MockExerciseCallback is IExerciseCallback {
    bool public shouldUnderpay;

    function setUnderpay(bool _underpay) external {
        shouldUnderpay = _underpay;
    }

    function onExercise(
        address /* tokenGiven */,
        address tokenExpected,
        uint256 /* amountGiven */,
        uint256 amountExpected,
        bytes calldata /* data */
    ) external override {
        // We received tokenGiven from the vault. Send tokenExpected back.
        uint256 sendAmount = shouldUnderpay ? amountExpected - 1 : amountExpected;
        IERC20(tokenExpected).transfer(msg.sender, sendAmount);
    }
}
