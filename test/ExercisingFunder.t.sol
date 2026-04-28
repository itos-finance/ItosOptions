// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Setup} from "./Setup.t.sol";
import {ExercisingFunder} from "../src/utilities/ExercisingFunder.sol";
import {OPair} from "../src/OPair.sol";
import {FunderBase} from "../src/FunderBase.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract ExercisingFunderTest is Setup {
    ExercisingFunder public exFunder;
    OPair public pair;

    bytes32 constant SIGNER_ROLE = keccak256("SIGNER_ROLE");

    bytes32 constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 constant _EXERCISE_TYPEHASH =
        keccak256("Exercise(address vault,uint256 nonce)");

    function setUp() public override {
        super.setUp();
        pair = _createCallPair();

        vm.prank(mm);
        exFunder = new ExercisingFunder(address(factory));
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _signExercise(
        uint256 signerKey,
        address exFunderAddr,
        address vault,
        uint256 nonce
    ) internal view returns (bytes memory) {
        bytes32 domainSeparator = keccak256(abi.encode(
            _DOMAIN_TYPEHASH,
            keccak256("ExercisingFunder"),
            keccak256("1"),
            block.chainid,
            exFunderAddr
        ));
        bytes32 structHash = keccak256(abi.encode(_EXERCISE_TYPEHASH, vault, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _data(address signer, bytes memory sig) internal pure returns (bytes memory) {
        return abi.encode(signer, sig);
    }

    // =========================================================================
    // Happy path
    // =========================================================================

    function test_onExercise_transfersExpectedTokenToPair() public {
        uint256 amountGiven = 1e18;
        uint256 amountExpected = 2000e6;

        // Pool holds the tokenExpected it will pay out; tokenGiven arrives from the pair.
        usdc.mint(address(exFunder), amountExpected);
        weth.mint(address(exFunder), amountGiven); // pair would have sent this before the call

        bytes memory sig = _signExercise(mmPrivateKey, address(exFunder), address(pair), 0);
        bytes memory data = _data(mm, sig);

        vm.prank(address(pair));
        exFunder.onExercise(address(weth), address(usdc), amountGiven, amountExpected, data);

        assertEq(usdc.balanceOf(address(pair)), amountExpected);
        // tokenGiven stays in the shared pool
        assertEq(weth.balanceOf(address(exFunder)), amountGiven);
        assertEq(usdc.balanceOf(address(exFunder)), 0);
    }

    function test_onExercise_incrementsNonce() public {
        usdc.mint(address(exFunder), 100e6);

        uint256 nonceBefore = exFunder.nonces(address(pair));
        bytes memory sig = _signExercise(mmPrivateKey, address(exFunder), address(pair), nonceBefore);
        bytes memory data = _data(mm, sig);

        vm.prank(address(pair));
        exFunder.onExercise(address(weth), address(usdc), 0, 100e6, data);

        assertEq(exFunder.nonces(address(pair)), nonceBefore + 1);
    }

    function test_onExercise_grantedSigner_canAuthorize() public {
        uint256 botKey = 0xB0B;
        address bot = vm.addr(botKey);

        vm.prank(mm);
        exFunder.grantRole(SIGNER_ROLE, bot);

        usdc.mint(address(exFunder), 100e6);
        bytes memory sig = _signExercise(botKey, address(exFunder), address(pair), 0);
        bytes memory data = _data(bot, sig);

        vm.prank(address(pair));
        exFunder.onExercise(address(weth), address(usdc), 0, 100e6, data);

        assertEq(usdc.balanceOf(address(pair)), 100e6);
    }

    // =========================================================================
    // Security
    // =========================================================================

    function test_onExercise_revertsIfCallerNotValidPair() public {
        address attacker = makeAddr("attacker");
        usdc.mint(address(exFunder), 100e6);

        bytes memory sig = _signExercise(mmPrivateKey, address(exFunder), attacker, 0);
        bytes memory data = _data(mm, sig);

        vm.prank(attacker);
        vm.expectRevert(FunderBase.NotValidPair.selector);
        exFunder.onExercise(address(weth), address(usdc), 0, 100e6, data);
    }

    function test_onExercise_revertsIfSignerLacksRole() public {
        uint256 strangerKey = 0xDEAD;
        address stranger = vm.addr(strangerKey);

        usdc.mint(address(exFunder), 100e6);
        bytes memory sig = _signExercise(strangerKey, address(exFunder), address(pair), 0);
        bytes memory data = _data(stranger, sig);

        vm.prank(address(pair));
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            stranger,
            SIGNER_ROLE
        ));
        exFunder.onExercise(address(weth), address(usdc), 0, 100e6, data);
    }

    function test_onExercise_revertsIfSignatureByDifferentKey() public {
        // Claimed signer is mm (has role), but the signature was produced by a different key.
        uint256 impostorKey = 0xDEAD;
        usdc.mint(address(exFunder), 100e6);

        bytes memory sig = _signExercise(impostorKey, address(exFunder), address(pair), 0);
        bytes memory data = _data(mm, sig);

        vm.prank(address(pair));
        vm.expectRevert(ExercisingFunder.InvalidSignature.selector);
        exFunder.onExercise(address(weth), address(usdc), 0, 100e6, data);
    }

    function test_onExercise_revertsIfSignatureForDifferentVault() public {
        OPair otherPair = _createPutPair();
        usdc.mint(address(exFunder), 100e6);

        // Signature binds to otherPair but call arrives from pair.
        bytes memory sig = _signExercise(mmPrivateKey, address(exFunder), address(otherPair), 0);
        bytes memory data = _data(mm, sig);

        vm.prank(address(pair));
        vm.expectRevert(ExercisingFunder.InvalidSignature.selector);
        exFunder.onExercise(address(weth), address(usdc), 0, 100e6, data);
    }

    function test_onExercise_revertsOnReplay() public {
        usdc.mint(address(exFunder), 200e6);

        bytes memory sig = _signExercise(mmPrivateKey, address(exFunder), address(pair), 0);
        bytes memory data = _data(mm, sig);

        vm.prank(address(pair));
        exFunder.onExercise(address(weth), address(usdc), 0, 100e6, data);

        // Nonce advanced; same signature is now for a stale nonce.
        vm.prank(address(pair));
        vm.expectRevert(ExercisingFunder.InvalidSignature.selector);
        exFunder.onExercise(address(weth), address(usdc), 0, 100e6, data);
    }

    function test_onExercise_revertsIfSignerRevokedAfterSigning() public {
        uint256 botKey = 0xB0B;
        address bot = vm.addr(botKey);

        vm.prank(mm);
        exFunder.grantRole(SIGNER_ROLE, bot);

        bytes memory sig = _signExercise(botKey, address(exFunder), address(pair), 0);
        bytes memory data = _data(bot, sig);

        vm.prank(mm);
        exFunder.revokeRole(SIGNER_ROLE, bot);

        usdc.mint(address(exFunder), 100e6);
        vm.prank(address(pair));
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            bot,
            SIGNER_ROLE
        ));
        exFunder.onExercise(address(weth), address(usdc), 0, 100e6, data);
    }

    function test_onExercise_noncesAreIsolatedPerVault() public {
        OPair otherPair = _createPutPair();
        usdc.mint(address(exFunder), 400e6);

        // Each vault starts at nonce 0; same logical nonce on each works independently.
        bytes memory sig1 = _signExercise(mmPrivateKey, address(exFunder), address(pair), 0);
        bytes memory sig2 = _signExercise(mmPrivateKey, address(exFunder), address(otherPair), 0);

        vm.prank(address(pair));
        exFunder.onExercise(address(weth), address(usdc), 0, 100e6, _data(mm, sig1));

        vm.prank(address(otherPair));
        exFunder.onExercise(address(weth), address(usdc), 0, 100e6, _data(mm, sig2));

        assertEq(exFunder.nonces(address(pair)), 1);
        assertEq(exFunder.nonces(address(otherPair)), 1);
    }

    function test_onExercise_nonceDoesNotAdvanceOnFailedSignature() public {
        usdc.mint(address(exFunder), 100e6);
        uint256 nonceBefore = exFunder.nonces(address(pair));

        // Signature by wrong key → InvalidSignature; storage changes should roll back.
        uint256 impostorKey = 0xDEAD;
        bytes memory sig = _signExercise(impostorKey, address(exFunder), address(pair), nonceBefore);
        bytes memory data = _data(mm, sig);

        vm.prank(address(pair));
        vm.expectRevert(ExercisingFunder.InvalidSignature.selector);
        exFunder.onExercise(address(weth), address(usdc), 0, 100e6, data);

        assertEq(exFunder.nonces(address(pair)), nonceBefore);
    }
}
