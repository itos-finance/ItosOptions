// SPDX-License-Identifier: BUSL-1.1
// Change Date: 2030-03-17  (license converts to GPL-2.0-or-later on this date)
pragma solidity ^0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FundingVerifier} from "./FundingVerifier.sol";
import {IFunder} from "./interfaces/IFunder.sol";
import {IFunderBase} from "./interfaces/IFunderBase.sol";

/// @title Funder
/// @notice Single-owner funding contract. The owner holds one shared token pool and may
///         whitelist additional signers (e.g. trading bots) that can authorise transfers
///         on their behalf. Each signer has an independent nonce per vault.
///
/// @dev Signatures commit to the total premium. Each signer has an independent nonce per vault.
contract Funder is IFunder, FundingVerifier {
    using SafeERC20 for IERC20;

    /// @inheritdoc IFunder
    address public immutable owner;

    /// @inheritdoc IFunder
    mapping(address => bool) public authorizedSigners;

    /// @notice Per-signer per-vault nonce. Incremented on each successful requestFunds.
    mapping(address => mapping(address => uint256)) public nonces;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _factory) FundingVerifier(_factory) {
        owner = msg.sender;
    }

    // --- Admin ---

    /// @inheritdoc IFunder
    function addSigner(address signer) external onlyOwner {
        authorizedSigners[signer] = true;
        emit SignerAdded(signer);
    }

    /// @inheritdoc IFunder
    function removeSigner(address signer) external onlyOwner {
        authorizedSigners[signer] = false;
        emit SignerRemoved(signer);
    }

    // --- Token management ---

    /// @inheritdoc IFunderBase
    /// @dev `signer` is ignored for Funder (shared pool); tokens go to the pool.
    function deposit(address signer, address token, uint256 amount) external {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit FundsDeposited(signer, token, amount);
    }

    /// @inheritdoc IFunderBase
    function withdraw(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner, amount);
        emit FundsWithdrawn(token, amount);
    }

    // --- Nonce management ---

    /// @inheritdoc IFunderBase
    function bumpNonce(address vault) external {
        if (msg.sender != owner && !authorizedSigners[msg.sender])
            revert NotAuthorizedSigner();
        uint256 newNonce = ++nonces[msg.sender][vault];
        emit NonceBumped(msg.sender, vault, newNonce);
    }

    // --- Vault interface ---

    /// @inheritdoc IFunderBase
    function requestFunds(
        address signer,
        address token,
        uint256 premium,
        int256 size,
        uint256 acquireAmount,
        uint256 validTillTimestamp,
        bytes calldata signature
    ) external onlyValidVault {
        if (signer != owner && !authorizedSigners[signer])
            revert NotAuthorizedSigner();

        uint256 currentNonce = nonces[signer][msg.sender];
        _verifyQuote(
            signer,
            currentNonce,
            size,
            premium,
            validTillTimestamp,
            signature
        );
        nonces[signer][msg.sender] = currentNonce + 1;

        if (acquireAmount > 0)
            IERC20(token).safeTransfer(msg.sender, acquireAmount);
        emit FundsRequested(msg.sender, signer, token, acquireAmount);
    }
}
