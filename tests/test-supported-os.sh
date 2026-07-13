#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

run_preflight_for_os() {
  local id="$1" version="$2" expected="$3"
  local os_release="$TMP_DIR/${id}-${version}"
  printf 'ID=%s\nVERSION_ID="%s"\n' "$id" "$version" > "$os_release"

  if HAO_OS_RELEASE_FILE="$os_release" "$ROOT_DIR/hao" preflight --services pi >"$TMP_DIR/output" 2>&1; then
    actual=pass
  else
    actual=fail
  fi
  if [ "$actual" != "$expected" ]; then
    echo "Expected $id $version to $expected, got $actual" >&2
    cat "$TMP_DIR/output" >&2
    exit 1
  fi
}

run_preflight_for_os debian 13 pass
run_preflight_for_os debian 12 pass
run_preflight_for_os ubuntu 26.04 pass
run_preflight_for_os ubuntu 24.04 pass
run_preflight_for_os ubuntu 22.04 pass
run_preflight_for_os debian 11 fail
run_preflight_for_os ubuntu 20.04 fail
run_preflight_for_os fedora 42 fail
