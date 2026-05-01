// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

// Forces foundry to compile v3-core's Factory + Pool into ./out so tests can
// pick them up via vm.readFile. The =0.7.6 pin matches v3-core; this file is
// in its own compilation unit and is never imported by our codebase.
import "v3-core/contracts/UniswapV3Factory.sol";
import "v3-core/contracts/UniswapV3Pool.sol";
