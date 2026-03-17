// SPDX-License-Identifier: BUSL-1.1
// Change Date: 2030-03-17  (license converts to GPL-2.0-or-later on this date)
pragma solidity ^0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IOPairFactory} from "./interfaces/IOPairFactory.sol";

/// @title FundingVerifier
/// @notice Abstract base for Funder contracts and the Bulletin. Owns the EIP-712 domain
///         setup and quote-digest construction so all signing logic lives in one place.
///
///         Funder contracts (Funder, MultiFunder) inherit this and call _verifyQuote, which
///         fixes funder = address(this) and vault = msg.sender.
///
///         Bulletin also inherits this and calls _buildDigest directly with an arbitrary
///         funder and vault address — producing the identical digest the funder will verify.
abstract contract FundingVerifier {
    using SafeERC20 for IERC20;

    // --- Shared errors ---
    error NotValidVault();
    error InvalidSignature();

    // --- EIP-712 ---
    /// @notice The factory whose pairs are authorised to call requestFunds.
    IOPairFactory public immutable factory;

    /// @notice EIP-712 domain separator for this contract instance (only meaningful on Funder
    ///         deployments; Bulletin uses _buildDigest with the external funder address).
    bytes32 public immutable DOMAIN_SEPARATOR;

    /// @dev Quote(address funder,uint256 size,address vault,uint256 pricePerOption,
    ///           uint256 validTillTimestamp,uint256 nonce)
    bytes32 public constant QUOTE_TYPEHASH =
        keccak256(
            "Quote(address funder,uint256 size,address vault,uint256 pricePerOption,uint256 validTillTimestamp,uint256 nonce)"
        );

    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );

    constructor(address _factory) {
        factory = IOPairFactory(_factory);
        DOMAIN_SEPARATOR = _domainSeparatorFor(address(this));
    }

    /// @dev Reverts if the caller is not a pair created by this factory.
    modifier onlyValidVault() {
        if (!factory.isVault(msg.sender)) revert NotValidVault();
        _;
    }

    // -------------------------------------------------------------------------
    // Internal helpers — shared by Funder subclasses and Bulletin
    // -------------------------------------------------------------------------

    /// @dev Builds the EIP-712 digest for a Quote struct with an explicit funder and vault.
    ///      Funder subclasses call this via _verifyQuote (funder = address(this), vault = msg.sender).
    ///      Bulletin calls this directly with the external funder address and vault parameter.
    function _buildDigest(
        address funder,
        address vault,
        uint256 size,
        uint256 pricePerOption,
        uint256 validTillTimestamp,
        uint256 nonce
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                QUOTE_TYPEHASH,
                funder,
                size,
                vault,
                pricePerOption,
                validTillTimestamp,
                nonce
            )
        );
        return
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    _domainSeparatorFor(funder),
                    structHash
                )
            );
    }

    /// @dev Recovers the signer from a Quote digest with explicit funder, vault, and nonce.
    ///      Bulletin uses this directly; Funder subclasses go through _verifyQuote.
    function _recoverSigner(
        address funder,
        address vault,
        uint256 size,
        uint256 pricePerOption,
        uint256 validTillTimestamp,
        uint256 nonce,
        bytes calldata signature
    ) internal view returns (address) {
        return
            ECDSA.recover(
                _buildDigest(
                    funder,
                    vault,
                    size,
                    pricePerOption,
                    validTillTimestamp,
                    nonce
                ),
                signature
            );
    }

    /// @dev Verifies a Quote signed for this funder contract (funder = address(this),
    ///      vault = msg.sender). Used by Funder and MultiFunder in requestFunds.
    function _verifyQuote(
        address expectedSigner,
        uint256 currentNonce,
        uint256 size,
        uint256 pricePerOption,
        uint256 validTillTimestamp,
        bytes calldata signature
    ) internal view {
        if (
            _recoverSigner(
                address(this),
                msg.sender,
                size,
                pricePerOption,
                validTillTimestamp,
                currentNonce,
                signature
            ) != expectedSigner
        ) revert InvalidSignature();
    }

    /// @dev Computes the EIP-712 domain separator for any verifyingContract address.
    function _domainSeparatorFor(
        address verifyingContract
    ) internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    _DOMAIN_TYPEHASH,
                    keccak256("MonasteryFunder"),
                    keccak256("1"),
                    block.chainid,
                    verifyingContract
                )
            );
    }
}
