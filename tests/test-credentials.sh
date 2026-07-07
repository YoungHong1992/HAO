#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/credentials.sh
source "$ROOT_DIR/lib/credentials.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

CREDENTIALS_FILE="$TMP_DIR/hao-credentials.txt"
write_credentials_file "$CREDENTIALS_FILE" <<'EOF'
username=admin
password=secret
EOF

mode="$(stat -c '%a' "$CREDENTIALS_FILE")"
if [ "$mode" != "600" ]; then
  echo "Expected credentials mode 600, got $mode" >&2
  exit 1
fi

content="$(cat "$CREDENTIALS_FILE")"
if ! grep -q 'password=secret' <<<"$content"; then
  echo "Credentials content was not written" >&2
  exit 1
fi

cat > "$TMP_DIR/config.yaml" <<'YAML'
api-keys:
  - "sk-test-1"
  - sk-test-2
remote-management:
  secret-key: "admin-secret"
YAML

extracted="$(extract_yaml_list_values "$TMP_DIR/config.yaml" api-keys | paste -sd, -)"
if [ "$extracted" != "sk-test-1,sk-test-2" ]; then
  echo "Unexpected yaml list extraction: $extracted" >&2
  exit 1
fi
