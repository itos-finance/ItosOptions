// SPDX-License-Identifier: BUSL-1.1
// Change Date: 2030-03-17  (license converts to GPL-2.0-or-later on this date)
pragma solidity ^0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Funder} from "../Funder.sol";
import {IExerciseCallback} from "../interfaces/IExerciseCallback.sol";

/// @title ExercisingFunder
/// @notice Funder that also acts as the exercise callback. A long holder may call
///         `OPair.exercise` / `unexercise` pointing at this contract; the callback
///         pays the vault's required `tokenExpected` out of the shared pool.
///
///         The callback is gated by an EIP-712 signature: `data` must decode to
///         `(address signer, bytes signature)` where `signer` holds `SIGNER_ROLE`
///         and the signature is over `Exercise(address vault, uint256 nonce)`
///         with this contract as the EIP-712 verifyingContract. A per-vault
///         nonce prevents replay.
contract ExercisingFunder is Funder, IExerciseCallback {
    using SafeERC20 for IERC20;

    error InvalidSignature();

    /// @dev Exercise(address vault,uint256 nonce)
    bytes32 public constant EXERCISE_TYPEHASH =
        keccak256("Exercise(address vault,uint256 nonce)");

    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );

    /// @notice Next expected nonce for a vault. Incremented on each successful callback.
    mapping(address vault => uint256) public nonces;

    constructor(address _factory) Funder(_factory) {}

    /// @inheritdoc IExerciseCallback
    function onExercise(
        address /* tokenGiven */,
        address tokenExpected,
        uint256 /* amountGiven */,
        uint256 amountExpected,
        bytes calldata data
    ) external virtual override onlyValidPair {
        _verifyAndConsumeSignature(msg.sender, data);
        IERC20(tokenExpected).safeTransfer(msg.sender, amountExpected);
    }

    /// @dev Decodes `data` as `(signer, signature)`, checks `signer` has
    ///      `SIGNER_ROLE`, verifies the EIP-712 `Exercise(vault, nonce)`
    ///      signature against the vault's current nonce, and advances the
    ///      nonce. Reverts on any failure.
    function _verifyAndConsumeSignature(
        address vault,
        bytes calldata data
    ) internal {
        (address signer, bytes memory signature) = abi.decode(
            data,
            (address, bytes)
        );

        if (!hasRole(SIGNER_ROLE, signer))
            revert AccessControlUnauthorizedAccount(signer, SIGNER_ROLE);

        uint256 nonce = nonces[vault]++;
        bytes32 structHash = keccak256(
            abi.encode(EXERCISE_TYPEHASH, vault, nonce)
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", _domainSeparator(), structHash)
        );
        if (ECDSA.recover(digest, signature) != signer)
            revert InvalidSignature();
    }

    function _domainSeparator() internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    _DOMAIN_TYPEHASH,
                    keccak256("ExercisingFunder"),
                    keccak256("1"),
                    block.chainid,
                    address(this)
                )
            );
    }
}
