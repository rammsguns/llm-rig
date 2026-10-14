#!/usr/bin/env bash
set -euo pipefail
STRATA_PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export XDG_CONFIG_HOME="$STRATA_PROJECT_DIR/.config"
export PIP_CACHE_DIR="$STRATA_PROJECT_DIR/.cache/pip"
export HF_HOME="$STRATA_PROJECT_DIR/.cache/huggingface"
export PYTHONUNBUFFERED=1
cd "$STRATA_PROJECT_DIR/engine"
exec ./setup.sh --yes --setup --family qwen --model IQ3_S \
  --context 131072 --gpus 0,1 --layer-split auto \
  --kv int8 --kv-streaming on --parallel 1 --vision no --backend cuda \
  --data-dir "$STRATA_PROJECT_DIR/data" --models-dir "$STRATA_PROJECT_DIR/models" \
  --host 127.0.0.1 --port 8080 --no-browser --no-start "$@"
