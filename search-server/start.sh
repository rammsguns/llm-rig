#!/usr/bin/env bash
set -euo pipefail
SEARCH_PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec "$SEARCH_PROJECT_DIR/.venv/bin/python" "$SEARCH_PROJECT_DIR/server.py"
