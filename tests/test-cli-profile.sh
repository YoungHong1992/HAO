#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PROFILE="$TMP_DIR/deploy.env"
PWNED="$TMP_DIR/profile-executed"

cat > "$PROFILE" <<EOF
HAO_SERVICES="pi"
HAO_PROFILE_MARKER="\$(touch "$PWNED")"
EOF

"$ROOT_DIR/hao" plan --profile "$PROFILE" >/dev/null

if [ -e "$PWNED" ]; then
  echo "Profile was executed as shell code" >&2
  exit 1
fi

override_output="$(HAO_SERVICES=maintenance "$ROOT_DIR/hao" plan --profile "$PROFILE")"
if ! grep -q '  - Pi:' <<<"$override_output" || grep -q '  - Maintenance:' <<<"$override_output"; then
  echo "Profile did not override ambient HAO_SERVICES" >&2
  exit 1
fi

BAD_PROFILE="$TMP_DIR/bad.env"
cat > "$BAD_PROFILE" <<'EOF'
PATH=/tmp
HAO_SERVICES="pi"
EOF

if "$ROOT_DIR/hao" plan --profile "$BAD_PROFILE" >/dev/null 2>&1; then
  echo "Profile with non-HAO variable unexpectedly passed" >&2
  exit 1
fi

UNCLOSED_PROFILE="$TMP_DIR/unclosed.env"
cat > "$UNCLOSED_PROFILE" <<'EOF'
HAO_SERVICES="pi
EOF

if "$ROOT_DIR/hao" plan --profile "$UNCLOSED_PROFILE" >/dev/null 2>&1; then
  echo "Profile with unclosed quote unexpectedly passed" >&2
  exit 1
fi

plan_output="$("$ROOT_DIR/hao" plan --services new-api --domain api.example.com --newapi-image example/new-api:v1)"
if ! grep -q 'image: example/new-api:v1' <<<"$plan_output"; then
  echo "Plan did not include requested New-API image" >&2
  exit 1
fi
