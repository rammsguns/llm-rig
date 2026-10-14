#!/usr/bin/env bash
set -euo pipefail
STRATA_PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export XDG_CONFIG_HOME="$STRATA_PROJECT_DIR/.config"
export PIP_CACHE_DIR="$STRATA_PROJECT_DIR/.cache/pip"
export HF_HOME="$STRATA_PROJECT_DIR/.cache/huggingface"
export PYTHONUNBUFFERED=1
if [[ -f "$STRATA_PROJECT_DIR/.config/strata/api-key" ]]; then
  export STRATA_API_KEY
  STRATA_API_KEY="$(< "$STRATA_PROJECT_DIR/.config/strata/api-key")"
fi
if [[ ! -f "$STRATA_PROJECT_DIR/engine/run-iq3_s.sh" ]]; then
  printf '%s\n' 'Strata setup is incomplete. Run ./prepare.sh first.' >&2
  exit 1
fi
cd "$STRATA_PROJECT_DIR/engine"
exec bash ./run-iq3_s.sh "$@"
