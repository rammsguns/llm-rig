#!/usr/bin/env bash
set -euo pipefail
STRATA_PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export XDG_CONFIG_HOME="$STRATA_PROJECT_DIR/.config"
export PIP_CACHE_DIR="$STRATA_PROJECT_DIR/.cache/pip"
export HF_HOME="$STRATA_PROJECT_DIR/.cache/huggingface"
export PYTHONUNBUFFERED=1
cd "$STRATA_PROJECT_DIR/engine"
exec ./setup.sh --yes --calibrate --family qwen --model IQ3_S --no-start "$@"
