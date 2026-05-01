// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {OPair} from "../../src/OPair.sol";
import {SwapExercisingFunder} from "../../src/utilities/SwapExercisingFunder.sol";

/// @notice Exercises a long position against a SwapExercisingFunder. Builds
///         the EIP-712 ExerciseSwap signature on the fly using
///         SIGNER_PRIVATE_KEY — that key must hold SIGNER_ROLE on the funder.
///         The script's broadcaster (`--private-key`) is the long holder.
///
/// Required env:
///   PAIR, FUNDER, SIZE, AMOUNT_IN, AMOUNT_OUT_MIN, POOL_FEE, HOOKS,
///   SIGNER_PRIVATE_KEY
/// Optional env:
///   POOL_TICK_SPACING  (default 1; ignored on the V3 path)
///
/// HOOKS=0x0000000000000000000000000000000000003333 routes via Uniswap V3;
/// any other value is treated as a V4 hooks contract address.
contract ExerciseWithSwapFunder is Script {
    bytes32 constant _DOMAIN_TYPEHASH =
        keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
    bytes32 constant _EXERCISE_SWAP_TYPEHASH =
        keccak256(
            "ExerciseSwap(address vault,uint256 nonce,uint256 amountIn,uint256 amountOutMin,uint24 fee,int24 tickSpacing,address hooks)"
        );

    function run() external {
        OPair pair = OPair(vm.envAddress("PAIR"));
        SwapExercisingFunder funder = SwapExercisingFunder(
            vm.envAddress("FUNDER")
        );
        uint128 size = uint128(vm.envUint("SIZE"));
        uint256 signerKey = vm.envUint("SIGNER_PRIVATE_KEY");
        address signer = vm.addr(signerKey);

        SwapExercisingFunder.SwapData memory sd = SwapExercisingFunder.SwapData({
            amountIn: vm.envUint("AMOUNT_IN"),
            amountOutMin: vm.envUint("AMOUNT_OUT_MIN"),
            fee: uint24(vm.envUint("POOL_FEE")),
            tickSpacing: int24(vm.envOr("POOL_TICK_SPACING", int256(1))),
            hooks: vm.envAddress("HOOKS")
        });

        uint256 nonce = funder.nonces(address(pair));
        bytes32 digest = _digest(address(pair), address(funder), nonce, sd);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);
        bytes memory data = abi.encode(signer, sd, signature);

        vm.startBroadcast();
        pair.exercise(size, address(funder), data);
        vm.stopBroadcast();

        console.log("Exercised:");
        console.log("  pair:        ", address(pair));
        console.log("  funder:      ", address(funder));
        console.log("  size:        ", uint256(size));
        console.log("  amountIn:    ", sd.amountIn);
        console.log("  amountOutMin:", sd.amountOutMin);
        console.log("  fee:         ", uint256(sd.fee));
        console.log("  hooks:       ", sd.hooks);
        console.log("  signer:      ", signer);
        console.log("  nonceUsed:   ", nonce);
    }

    function _digest(
        address vault,
        address funder,
        uint256 nonce,
        SwapExercisingFunder.SwapData memory sd
    ) internal view returns (bytes32) {
        bytes32 domainSep = keccak256(
            abi.encode(
                _DOMAIN_TYPEHASH,
                keccak256("ExercisingFunder"),
                keccak256("1"),
                block.chainid,
                funder
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                _EXERCISE_SWAP_TYPEHASH,
                vault,
                nonce,
                sd.amountIn,
                sd.amountOutMin,
                sd.fee,
                sd.tickSpacing,
                sd.hooks
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
    }
}
