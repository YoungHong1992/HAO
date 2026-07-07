#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${HAO_REPO_DIR:-}"

if [ -z "$REPO_DIR" ]; then
    REPO_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
fi

if [ ! -x "$REPO_DIR/hao" ]; then
    echo "hao-run: cannot find executable hao at $REPO_DIR/hao" >&2
    echo "Set HAO_REPO_DIR=/path/to/hao and retry." >&2
    exit 1
fi

exec "$REPO_DIR/hao" "$@"
