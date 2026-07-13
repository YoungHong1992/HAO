#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

export HAO_STATE_DIR="$TMP_DIR/state"
# shellcheck source=../lib/state.sh
source "$ROOT_DIR/lib/state.sh"

managed_file="$TMP_DIR/managed.conf"
shared_file="$TMP_DIR/shared.conf"
secret_file="$TMP_DIR/secret.conf"
printf '# Managed by HAO\nvalue=1\n' > "$managed_file"
printf 'external=true\n' > "$shared_file"
printf 'token=never-copy-this\n' > "$secret_file"

hao_record_service test-service success 260713-abcdef0 \
  "managed:$managed_file" "shared:$shared_file" "secret:$secret_file"

grep -q '"managed_by": "HAO"' "$HAO_STATE_DIR/manifest.json"
grep -q '"service": "test-service"' "$HAO_STATE_DIR/services/test-service.json"
grep -q '"sha256": "redacted"' "$HAO_STATE_DIR/services/test-service.json"
if grep -q 'never-copy-this' "$HAO_STATE_DIR/manifest.json"; then
  echo "Secret value leaked into HAO state" >&2
  exit 1
fi

hao_print_drift_report > "$TMP_DIR/clean"
grep -q '\[ok\] test-service' "$TMP_DIR/clean"

printf '# Managed by HAO\nvalue=2\n' > "$managed_file"
if hao_print_drift_report > "$TMP_DIR/drift"; then
  echo "Modified managed resource was not reported as drift" >&2
  exit 1
fi
grep -q '\[drift\].*modified' "$TMP_DIR/drift"

# Shared resources are inventory only and must not be treated as HAO-owned drift.
printf 'external=changed\n' > "$shared_file"
grep -q $'shared\t' "$HAO_STATE_DIR/services/test-service.resources"

# Public deployers must carry both file-level and runtime ownership markers.
grep -q 'Managed by HAO' "$ROOT_DIR/new-api/install.sh"
grep -q 'io.hao.managed' "$ROOT_DIR/new-api/install.sh"
grep -q 'chmod 600.*docker-compose.yml' "$ROOT_DIR/new-api/install.sh"
grep -q 'Managed by HAO' "$ROOT_DIR/cliproxyapi/install.sh"
grep -q 'io.hao.managed' "$ROOT_DIR/cliproxyapi/install.sh"
grep -q '90-hao-nofile.conf' "$ROOT_DIR/nginx/install.sh"
