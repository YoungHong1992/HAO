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
if ! grep -q 'calciumion/new-api:v1.0.0-rc.21 (release-candidate)' <<<"$plan_output"; then
  echo "Plan did not include reviewed New-API image candidates" >&2
  exit 1
fi

if "$ROOT_DIR/hao" plan --services new-api --domain api.example.com --newapi-image 'example/new-api:latest;id' >/dev/null 2>&1; then
  echo "Unsafe Docker image reference unexpectedly passed" >&2
  exit 1
fi

# claude-code: plan must never print the token value
CC_PROFILE="$TMP_DIR/cc.env"
cat > "$CC_PROFILE" <<'EOF'
HAO_SERVICES="claude-code"
HAO_CC_BASE_URL="https://gw.example.com"
HAO_CC_AUTH_TOKEN="sk-secret-should-not-appear"
HAO_CC_MODEL="claude-fable-5"
EOF

cc_output="$("$ROOT_DIR/hao" plan --profile "$CC_PROFILE")"
if ! grep -q '  - Claude Code:' <<<"$cc_output"; then
  echo "Plan did not include claude-code service" >&2
  exit 1
fi
if grep -q 'sk-secret-should-not-appear' <<<"$cc_output"; then
  echo "Plan leaked claude-code token value" >&2
  exit 1
fi
if ! grep -q 'token: provided (hidden)' <<<"$cc_output"; then
  echo "Plan did not mark claude-code token as hidden" >&2
  exit 1
fi

# alias resolution
if ! "$ROOT_DIR/hao" plan --services cc >/dev/null; then
  echo "Alias cc did not resolve to claude-code" >&2
  exit 1
fi
