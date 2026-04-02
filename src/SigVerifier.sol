// SPDX-License-Identifier: BUSL-1.1
// Change Date: 2030-03-17  (license converts to GPL-2.0-or-later on this date)
pragma solidity ^0.8.34;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title SigVerifier
/// @notice Pure EIP-712 helpers for the Quote struct. No storage, no constructor.
///         Inherited by OPair (which validates signatures) and Bulletin (which
///         reproduces the same digest to verify posted signatures).
///
///         The verifyingContract in the domain is the OPair (vault) address, since
///         OPair is the contract that validates all signatures.
abstract contract SigVerifier {
    error InvalidSignature();

    /// @dev Quote(address funder,address vault,int256 size,uint256 premiumPerUnit,
    ///           uint256 validTillTimestamp,bool allowPartialFill,uint256 nonce)
    ///      Positive size = buy intent, negative size = sell intent.
    ///      premiumPerUnit is the premium per 1e18 units of size (rate, not total).
    ///      allowPartialFill: if false, the fill must equal size exactly.
    bytes32 public constant QUOTE_TYPEHASH =
        keccak256(
            "Quote(address funder,address vault,int256 size,uint256 premiumPerUnit,uint256 validTillTimestamp,bool allowPartialFill,uint256 nonce)"
        );

    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );

    /// @dev Builds the EIP-712 digest for a Quote struct.
    ///      `vault` is used as the domain verifyingContract.
    function _buildDigest(
        address funder,
        address vault,
        int256 size,
        uint256 premiumPerUnit,
        uint256 validTillTimestamp,
        uint256 nonce,
        bool allowPartialFill
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            QUOTE_TYPEHASH,
            funder,
            vault,
            size,
            premiumPerUnit,
            validTillTimestamp,
            allowPartialFill,
            nonce
        ));
        return keccak256(abi.encodePacked(
            "\x19\x01",
            _domainSeparatorFor(vault),
            structHash
        ));
    }

    /// @dev Recovers the signer of a Quote digest.
    function _recoverSigner(
        address funder,
        address vault,
        int256 size,
        uint256 premiumPerUnit,
        uint256 validTillTimestamp,
        uint256 nonce,
        bool allowPartialFill,
        bytes calldata signature
    ) internal view returns (address) {
        return ECDSA.recover(
            _buildDigest(funder, vault, size, premiumPerUnit, validTillTimestamp, nonce, allowPartialFill),
            signature
        );
    }

    /// @dev Computes the EIP-712 domain separator for a given verifyingContract.
    function _domainSeparatorFor(address verifyingContract) internal view returns (bytes32) {
        return keccak256(abi.encode(
            _DOMAIN_TYPEHASH,
            keccak256("OPair"),
            keccak256("1"),
            block.chainid,
            verifyingContract
        ));
    }
}
