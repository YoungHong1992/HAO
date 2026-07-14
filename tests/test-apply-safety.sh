#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
FAKE_BIN="$TMP_DIR/fake-bin"
DOCKER_ROOT="$TMP_DIR/docker-services"
NGINX_CONF_DIR="$TMP_DIR/nginx/conf.d"
STATE_DIR="$TMP_DIR/state"
mkdir -p "$FAKE_BIN" "$DOCKER_ROOT/new-api" "$NGINX_CONF_DIR"

cat > "$FAKE_BIN/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "--version") echo "Docker version test" ;;
  "compose version") echo "Docker Compose version test" ;;
esac
exit 0
EOF
cat > "$FAKE_BIN/nginx" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -t) exit 0 ;;
  -v|-V) echo "nginx version: nginx/test" >&2; exit 0 ;;
esac
exit 0
EOF
cat > "$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '127.0.0.1\n'
EOF
cat > "$FAKE_BIN/ss" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cp "$FAKE_BIN/ss" "$FAKE_BIN/netstat"
chmod +x "$FAKE_BIN"/*

OS_RELEASE="$TMP_DIR/os-release"
printf 'ID=ubuntu\nVERSION_ID="24.04"\n' > "$OS_RELEASE"
PROFILE="$TMP_DIR/upgrade.env"
cat > "$PROFILE" <<'EOF'
HAO_SERVICES="new-api"
HAO_ACCESS_MODE="http"
HAO_NEWAPI_DOMAIN="127.0.0.1"
HAO_DB_TYPE="postgresql"
HAO_NEWAPI_ACTION="upgrade"
EOF

COMPOSE_FILE="$DOCKER_ROOT/new-api/docker-compose.yml"
write_compose() {
  cat > "$COMPOSE_FILE" <<'EOF'
services:
  new-api:
    environment:
      - SQL_DSN=postgresql://newapi:dbsecret@postgres:5432/newapi
      - REDIS_CONN_STRING=redis://:redissecret@redis:6379
      - SESSION_SECRET=sessionsecret
  postgres:
    image: postgres:15
EOF
}
write_compose

run_preflight() {
  env \
    PATH="$FAKE_BIN:$PATH" \
    HAO_DOCKER_ROOT="$DOCKER_ROOT" \
    HAO_NGINX_CONF_DIR="$NGINX_CONF_DIR" \
    HAO_STATE_DIR="$STATE_DIR" \
    HAO_OS_RELEASE_FILE="$OS_RELEASE" \
    "$ROOT_DIR/hao" preflight --profile "$PROFILE" "$@"
}

run_apply() {
  env \
    PATH="$FAKE_BIN:$PATH" \
    HAO_DOCKER_ROOT="$DOCKER_ROOT" \
    HAO_NGINX_CONF_DIR="$NGINX_CONF_DIR" \
    HAO_STATE_DIR="$STATE_DIR" \
    HAO_DEPLOY_LOG_DIR="$TMP_DIR/logs" \
    HAO_OS_RELEASE_FILE="$OS_RELEASE" \
    "$ROOT_DIR/hao" apply --profile "$PROFILE" --yes
}

# --yes is not an ownership override: an existing target without state is blocked.
if run_preflight > "$TMP_DIR/untracked" 2>&1; then
  echo "Untracked target unexpectedly passed preflight" >&2
  exit 1
fi
grep -q 'Untracked target' "$TMP_DIR/untracked"

if [ "${EUID:-$(id -u)}" -eq 0 ]; then
  UNTRACKED_HASH="$(sha256sum "$COMPOSE_FILE" | awk '{print $1}')"
  if run_apply > "$TMP_DIR/untracked-apply" 2>&1; then
    echo "Untracked target unexpectedly passed apply --yes" >&2
    exit 1
  fi
  grep -q 'Untracked target' "$TMP_DIR/untracked-apply"
  test "$UNTRACKED_HASH" = "$(sha256sum "$COMPOSE_FILE" | awk '{print $1}')"
fi

# The untracked override is explicit and does not imply a managed-drift override.
run_preflight --allow-untracked-overwrite > "$TMP_DIR/untracked-allowed"
grep -q 'overwrite separately confirmed' "$TMP_DIR/untracked-allowed"
HAO_ALLOW_UNTRACKED_OVERWRITE=yes run_preflight > "$TMP_DIR/untracked-env-allowed"
grep -q 'overwrite separately confirmed' "$TMP_DIR/untracked-env-allowed"

export HAO_STATE_DIR="$STATE_DIR"
# shellcheck source=../lib/state.sh
source "$ROOT_DIR/lib/state.sh"
hao_record_service newapi success test-release "managed:$COMPOSE_FILE"
awk -F '\t' -v path="$COMPOSE_FILE" '$1 == "managed" && $3 == path { found=1 } END { exit found ? 0 : 1 }' \
  "$STATE_DIR/services/newapi.resources"
printf '# operator change\n' >> "$COMPOSE_FILE"
env PATH="$FAKE_BIN:$PATH" HAO_STATE_DIR="$STATE_DIR" "$ROOT_DIR/hao" inventory \
  | grep -q '"service": "newapi"'

if run_preflight > "$TMP_DIR/drift" 2>&1; then
  echo "Managed drift unexpectedly passed preflight" >&2
  exit 1
fi
grep -q 'Managed drift newapi.*modified' "$TMP_DIR/drift" || { cat "$TMP_DIR/drift" >&2; exit 1; }

if [ "${EUID:-$(id -u)}" -eq 0 ]; then
  DRIFT_HASH="$(sha256sum "$COMPOSE_FILE" | awk '{print $1}')"
  if run_apply > "$TMP_DIR/drift-apply" 2>&1; then
    echo "Managed drift unexpectedly passed apply --yes" >&2
    exit 1
  fi
  grep -q 'Managed drift newapi.*modified' "$TMP_DIR/drift-apply"
  test "$DRIFT_HASH" = "$(sha256sum "$COMPOSE_FILE" | awk '{print $1}')"
fi

if run_preflight --newapi-action ensure > "$TMP_DIR/noop-drift" 2>&1; then
  echo "Managed drift was not checked before a no-op apply" >&2
  exit 1
fi
grep -q 'Managed drift newapi.*modified' "$TMP_DIR/noop-drift"

if run_preflight --allow-untracked-overwrite > "$TMP_DIR/wrong-override" 2>&1; then
  echo "Untracked override unexpectedly authorized managed drift" >&2
  exit 1
fi

run_preflight --allow-managed-drift > "$TMP_DIR/drift-allowed"
grep -q 'Managed drift newapi.*modified' "$TMP_DIR/drift-allowed"
grep -q 'Explicit override: reviewed managed drift' "$TMP_DIR/drift-allowed"
HAO_ALLOW_MANAGED_DRIFT=yes run_preflight > "$TMP_DIR/drift-env-allowed"
grep -q 'Managed drift newapi.*modified' "$TMP_DIR/drift-env-allowed"

echo "Apply resource safety gates passed."
