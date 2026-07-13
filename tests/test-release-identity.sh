#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source_id="$("$ROOT_DIR/hao" --version)"
if ! [[ "$source_id" =~ ^dev-[0-9a-f]{7}$|^[0-9]{6}-[0-9a-f]{7,12}$ ]]; then
  echo "Unexpected source release identity: $source_id" >&2
  exit 1
fi

override_id="$(HAO_RELEASE=260713-abcdef0 "$ROOT_DIR/hao" --version)"
if [ "$override_id" != "260713-abcdef0" ]; then
  echo "Valid HAO_RELEASE override was not used" >&2
  exit 1
fi

invalid_id="$(HAO_RELEASE=not-a-release "$ROOT_DIR/hao" --version)"
if [ "$invalid_id" = "not-a-release" ]; then
  echo "Invalid HAO_RELEASE override was accepted" >&2
  exit 1
fi
