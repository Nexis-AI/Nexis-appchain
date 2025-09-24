#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(git rev-parse --show-toplevel)

abspath() {
  python3 -c "import os,sys; print(os.path.abspath(sys.argv[1]))" "$1"
}

export DEVNET_OUT_DIR=$(abspath "${DEVNET_OUT_DIR:-$ROOT_DIR/.agents-devnet}")
export DEVNET_DEPLOYMENT_DIR=$(abspath "${DEVNET_DEPLOYMENT_DIR:-$ROOT_DIR/packages/contracts-bedrock/deployments/AgentsL3}")
export DEVNET_CONFIG_TEMPLATE=$(abspath "${DEVNET_CONFIG_TEMPLATE:-$ROOT_DIR/packages/contracts-bedrock/deploy-config/AgentsL3.json}")
export DEVNET_CONFIG_PATH=$(abspath "${DEVNET_CONFIG_PATH:-$DEVNET_OUT_DIR/AgentsL3.devnet.json}")
export DEVNET_NO_BUILD=${DEVNET_NO_BUILD:-true}
export DEVNET_FPAC=${DEVNET_FPAC:-true}
export AGENTS_L3_RPC_URL=${AGENTS_L3_RPC_URL:-http://127.0.0.1:9545}
export AGENTS_L3_CHAIN_ID=${AGENTS_L3_CHAIN_ID:-84532}
export AGENTS_STATE_DIR=$(abspath "${AGENTS_STATE_DIR:-$DEVNET_OUT_DIR}")

mkdir -p "$DEVNET_OUT_DIR"
mkdir -p "$DEVNET_DEPLOYMENT_DIR"

PYTHONPATH="$ROOT_DIR/bedrock-devnet" python3 "$ROOT_DIR/bedrock-devnet/main.py" --monorepo-dir "$ROOT_DIR"

pnpm --filter @eth-optimism/contracts-bedrock run deploy:agents --network agentsL3
