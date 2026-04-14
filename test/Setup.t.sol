// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {OPairFactory} from "../src/OPairFactory.sol";
import {OPair} from "../src/OPair.sol";
import {Funder} from "../src/Funder.sol";
import {MultiFunder} from "../src/MultiFunder.sol";
import {Bulletin} from "../src/Bulletin.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockExerciseCallback} from "./mocks/MockExerciseCallback.sol";

/// @dev Shared test setup. Deploys factory, tokens, funders, bulletin, and provides EIP-712 helpers.
abstract contract Setup is Test {
    // --- Actors ---
    address public admin;
    address public seller;  // writes options (takes short position)
    address public buyer;   // buys options (takes long position)
    uint256 public mmPrivateKey;
    address public mm; // market-maker: funder owner and default signer

    // --- Contracts ---
    OPairFactory public factory;
    Funder public funder;           // mm is owner; shared token pool
    MultiFunder public multiFunder; // permissionless multi-user funder
    Bulletin public bulletin;
    MockERC20 public weth;
    MockERC20 public usdc;
    MockExerciseCallback public callback;

    // --- Defaults ---
    uint128 public constant STRIKE = 2000e18;       // 2000 USDC per ETH (18-dec fixed point)
    uint128 public constant MIN_DEPOSIT = 0.01e18;  // 0.01 ETH minimum
    uint256 public constant EXPIRY_OFFSET = 7 days;
    uint256 public expiryTimestamp;

    string constant PAIR_ID  = "WETH-USDC-2000";
    string constant PAIR_SYM = "WETH";

    function setUp() public virtual {
        admin        = makeAddr("admin");
        seller       = makeAddr("seller");
        buyer        = makeAddr("buyer");
        mmPrivateKey = 0xA11CE;
        mm           = vm.addr(mmPrivateKey);

        vm.prank(admin);
        factory = new OPairFactory();

        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin",      "USDC", 6);

        vm.prank(mm);
        funder = new Funder(address(factory));

        multiFunder = new MultiFunder(address(factory));
        bulletin    = new Bulletin(address(factory));
        callback    = new MockExerciseCallback();

        expiryTimestamp = block.timestamp + EXPIRY_OFFSET;
    }

    // =========================================================================
    // Pair creation helpers
    // =========================================================================

    function _createCallPair() internal returns (OPair) {
        vm.prank(admin);
        return OPair(factory.createPair(
            address(weth), address(usdc),
            STRIKE, expiryTimestamp, true, MIN_DEPOSIT,
            PAIR_ID, PAIR_SYM
        ));
    }

    function _createPutPair() internal returns (OPair) {
        vm.prank(admin);
        return OPair(factory.createPair(
            address(weth), address(usdc),
            STRIKE, expiryTimestamp, false, MIN_DEPOSIT,
            PAIR_ID, PAIR_SYM
        ));
    }

    // =========================================================================
    // EIP-712 signing helpers
    // =========================================================================

    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 private constant _QUOTE_TYPEHASH =
        keccak256("Quote(address funder,address vault,int256 size,uint256 premiumPerUnit,uint256 validTillTimestamp,bool allowPartialFill,uint256 channel,uint256 nonce)");

    /// @dev Build an EIP-712 digest matching OPair._verifyAndConsumeQuote.
    ///      The verifyingContract is the vault (OPair), not the funder.
    ///      Positive size = buy intent, negative size = sell intent.
    function _buildDigest(
        address funderAddr,
        address vaultAddr,
        int256 size,
        uint256 premiumPerUnit,
        uint256 validTill,
        bool allowPartialFill,
        uint256 channel,
        uint256 nonce
    ) internal view returns (bytes32) {
        bytes32 domainSeparator = keccak256(abi.encode(
            _DOMAIN_TYPEHASH,
            keccak256("OPair"),
            keccak256("1"),
            block.chainid,
            vaultAddr
        ));
        bytes32 structHash = keccak256(abi.encode(
            _QUOTE_TYPEHASH,
            funderAddr,
            vaultAddr,
            size,
            premiumPerUnit,
            validTill,
            allowPartialFill,
            channel,
            nonce
        ));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    /// @dev Sign a quote with an arbitrary private key.
    ///      Positive size = buy intent, negative size = sell intent.
    ///      `premiumPerUnit` is premium per 1e18 units of size.
    function _signQuote(
        address funderAddr,
        address vaultAddr,
        uint256 signerKey,
        int256 size,
        uint256 premiumPerUnit,
        uint256 validTill,
        bool allowPartialFill,
        uint256 channel,
        uint256 nonce
    ) internal view returns (bytes memory) {
        bytes32 digest = _buildDigest(funderAddr, vaultAddr, size, premiumPerUnit, validTill, allowPartialFill, channel, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    // =========================================================================
    // Trade helpers (sell path: seller shorts, mm longs via funder)
    // =========================================================================

    /// @dev Fund funder's shared pool with cashToken for a premium.
    function _fundFunderWithPremium(uint256 amount) internal {
        usdc.mint(address(funder), amount);
    }

    /// @dev Full sell path: seller approves + calls pair.sell; mm's funder pays premium.
    ///      mm is the buyer (long position). validTill = block.timestamp + 1 hours.
    function _doSell(
        OPair pair,
        address _seller,
        uint128 size,
        uint128 premium
    ) internal {
        bool isCall = pair.isCall();
        uint256 depositAmt = isCall ? size : (uint256(size) * STRIKE / 1e18);
        address depToken = address(pair.depositToken());

        MockERC20(depToken).mint(_seller, depositAmt);
        vm.prank(_seller);
        MockERC20(depToken).approve(address(pair), depositAmt);

        usdc.mint(address(funder), premium);

        uint256 nonce = pair.nonces(mm, 0);
        uint256 validTill = block.timestamp + 1 hours;
        // premiumPerUnit: premium per 1e18 units. For size=1e18 this equals premium.
        uint128 premiumPerUnit = uint128(uint256(premium) * 1e18 / uint256(size));
        // mm is buyer → positive size
        bytes memory sig = _signQuote(address(funder), address(pair), mmPrivateKey, int256(uint256(size)), premiumPerUnit, validTill, true, 0, nonce);

        vm.prank(_seller);
        pair.sell(address(funder), mm, size, size, premiumPerUnit, validTill, true, 0, sig);
    }

    /// @dev Full buy path: buyer pays premium; mm's funder provides collateral.
    ///      mm is the seller (short position). validTill = block.timestamp + 1 hours.
    function _doBuy(
        OPair pair,
        address _buyer,
        uint128 size,
        uint128 premium
    ) internal {
        bool isCall = pair.isCall();
        uint256 depositAmt = isCall ? size : (uint256(size) * STRIKE / 1e18);

        // Fund buyer with cash to pay premium
        usdc.mint(_buyer, premium);
        vm.prank(_buyer);
        usdc.approve(address(pair), premium);

        // Fund funder's pool with the collateral it will transfer
        MockERC20(address(pair.depositToken())).mint(address(funder), depositAmt);

        uint256 nonce = pair.nonces(mm, 0);
        uint256 validTill = block.timestamp + 1 hours;
        // premiumPerUnit: premium per 1e18 units. For size=1e18 this equals premium.
        uint128 premiumPerUnit = uint128(uint256(premium) * 1e18 / uint256(size));
        // mm is seller → negative size
        bytes memory sig = _signQuote(address(funder), address(pair), mmPrivateKey, -int256(uint256(size)), premiumPerUnit, validTill, true, 0, nonce);

        vm.prank(_buyer);
        pair.buy(address(funder), mm, size, size, premiumPerUnit, validTill, true, 0, sig);
    }

    /// @dev Fund callback with swap tokens so exercise can complete.
    function _fundCallbackForExercise(OPair pair, uint128 size) internal {
        if (pair.isCall()) {
            usdc.mint(address(callback), (uint256(size) * STRIKE) / 1e18);
        } else {
            weth.mint(address(callback), size);
        }
    }

    /// @dev Fund callback with deposit tokens so unexercise can complete.
    function _fundCallbackForUnexercise(OPair pair, uint128 size) internal {
        if (pair.isCall()) {
            weth.mint(address(callback), size);
        } else {
            usdc.mint(address(callback), (uint256(size) * STRIKE) / 1e18);
        }
    }
}
