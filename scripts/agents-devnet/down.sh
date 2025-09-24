#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(git rev-parse --show-toplevel)

(cd "$ROOT_DIR/ops-bedrock" && docker compose down)
