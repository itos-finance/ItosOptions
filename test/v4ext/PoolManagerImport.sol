// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Forces foundry to compile v4-core's PoolManager into ./out so tests can
// pick it up via vm.deployCode. The 0.8.26 pin matches v4-core; this file
// stays in its own compilation unit and is never imported by our codebase.
import {PoolManager} from "v4-core/src/PoolManager.sol";

// Re-export to keep the import live.
abstract contract _V4ImportSink {
    PoolManager internal _pm;
}
