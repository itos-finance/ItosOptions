#!/usr/bin/env bash
# Generate frontend funder bytecode TS from forge artifacts. Tiny script; run
# from rfq root after `forge build`.
set -euo pipefail
F=$(jq -r '.bytecode.object' contracts/out/Funder.sol/Funder.json)
M=$(jq -r '.bytecode.object' contracts/out/MultiFunder.sol/MultiFunder.json)
cat > ../../frontend/app/src/lib/funder-bytecode.ts << TS
/* eslint-disable max-len */
// Auto-generated from contracts/out/{Funder,MultiFunder}.sol/*.json after
// \`forge build\`. Regenerate by running \`bash contracts/script/build-funder-bytecode.sh\`.
//
// Both contracts have a single-arg constructor: \`constructor(IOPairFactory _factory)\`.
// To deploy: \`walletClient.deployContract({ abi, bytecode, args: [factoryAddress] })\`.
// The deploying wallet is granted SIGNER_ROLE on Funder (post-deploy step); MultiFunder
// has no role hierarchy so the deployer has no special privileges.

import type { Hex } from 'viem';

export const FUNDER_BYTECODE: Hex = '$F';

export const MULTI_FUNDER_BYTECODE: Hex = '$M';
TS
echo "wrote $(wc -c < ../../frontend/app/src/lib/funder-bytecode.ts) bytes"
