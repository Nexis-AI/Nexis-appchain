#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(git rev-parse --show-toplevel)
export HARDHAT_NETWORK=${HARDHAT_NETWORK:-agentsL3}

cd "$ROOT_DIR/packages/contracts-bedrock"
pnpm exec hardhat test "$@"
