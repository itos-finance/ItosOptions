// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title IExerciseCallback
/// @notice Callback interface for option exercise. Implementers receive the deposit token
///         and must return the swap token within the same transaction, or the exercise reverts.
/// @dev In practice this callback is used for exercise or unexercises.
/// The given and expected are correct for their respective directions regardless.
interface IExerciseCallback {
    /// @notice Called by an OptionVault during exercise.
    /// @param tokenGiven The token sent to this contract by the vault (the deposit token).
    /// @param tokenExpected The token this contract must send back to the vault (the swap token).
    /// @param amountGiven The amount of tokenGiven transferred to this contract.
    /// @param amountExpected The amount of tokenExpected the vault requires back.
    /// @param data Arbitrary data forwarded from the exercise caller.
    /// @dev OPair:unexercise are still considered exercises, and use this same callback just
    /// with the given and expected tokens and amounts reversed. Therefore the callback contract
    /// always just adhere to the params given.
    function onExercise(
        address tokenGiven,
        address tokenExpected,
        uint256 amountGiven,
        uint256 amountExpected,
        bytes calldata data
    ) external;
}
