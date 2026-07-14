#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB_TYPE="${1:-}"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "This integration test must run as root." >&2
  exit 1
fi
case "$DB_TYPE" in
  postgresql|mysql) ;;
  *) echo "Usage: $0 postgresql|mysql" >&2; exit 1 ;;
esac

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
FAKE_BIN="$TMP_DIR/fake-bin"
DOCKER_ROOT="$TMP_DIR/docker-services"
NGINX_CONF_DIR="$TMP_DIR/nginx/conf.d"
NGINX_SSL_DIR="$TMP_DIR/nginx/ssl"
STATE_DIR="$TMP_DIR/state"
LOG_DIR="$TMP_DIR/logs"
mkdir -p "$FAKE_BIN" "$NGINX_CONF_DIR" "$NGINX_SSL_DIR" "$LOG_DIR"

cat > "$FAKE_BIN/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HAO_FAKE_DOCKER_CALLS"
case "$*" in
  "--version") echo "Docker version 29.0.0, build test" ;;
  "compose version") echo "Docker Compose version v2.0.0" ;;
  "compose ps") echo "new-api Up (healthy)" ;;
  "compose pull"|"compose up -d"|"compose restart"|"compose logs"*) ;;
  *) ;;
esac
EOF

cat > "$FAKE_BIN/nginx" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -t) exit 0 ;;
  -V) echo "nginx version: nginx/test" >&2; exit 0 ;;
  -v) echo "nginx version: nginx/test" >&2; exit 0 ;;
esac
exit 0
EOF

cat > "$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "is-active --quiet docker"|"is-active --quiet nginx") exit 0 ;;
  *) exit 0 ;;
esac
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

write_profile() {
  local path="$1" action="$2" db_type="$3"
  cat > "$path" <<EOF
HAO_SERVICES="new-api"
HAO_ACCESS_MODE="http"
HAO_NEWAPI_DOMAIN="127.0.0.1"
HAO_DB_TYPE="$db_type"
HAO_NEWAPI_ACTION="$action"
HAO_NEWAPI_IMAGE="calciumion/new-api:v1.0.0-rc.21"
EOF
}

run_hao() {
  env \
    PATH="$FAKE_BIN:$PATH" \
    HAO_DOCKER_ROOT="$DOCKER_ROOT" \
    HAO_NGINX_CONF_DIR="$NGINX_CONF_DIR" \
    HAO_NGINX_SSL_DIR="$NGINX_SSL_DIR" \
    HAO_STATE_DIR="$STATE_DIR" \
    HAO_DEPLOY_LOG_DIR="$LOG_DIR" \
    HAO_OS_RELEASE_FILE="$OS_RELEASE" \
    HAO_FAKE_DOCKER_CALLS="$TMP_DIR/docker-calls" \
    "$ROOT_DIR/hao" "$@"
}

secret_fingerprint() {
  local compose_file="$1"
  sed -n \
    -e '/SQL_DSN=/p' \
    -e '/REDIS_CONN_STRING=/p' \
    -e '/SESSION_SECRET=/p' \
    "$compose_file" | sha256sum | awk '{print $1}'
}

ENSURE_PROFILE="$TMP_DIR/ensure.env"
UPGRADE_PROFILE="$TMP_DIR/upgrade.env"
MISMATCH_PROFILE="$TMP_DIR/mismatch.env"
MIGRATE_PROFILE="$TMP_DIR/migrate.env"
write_profile "$ENSURE_PROFILE" ensure "$DB_TYPE"
write_profile "$UPGRADE_PROFILE" upgrade "$DB_TYPE"

run_hao apply --profile "$ENSURE_PROFILE" --yes > "$TMP_DIR/first-apply"
COMPOSE_FILE="$DOCKER_ROOT/new-api/docker-compose.yml"
CREDENTIALS_FILE="$DOCKER_ROOT/new-api/hao-credentials.txt"
test -f "$COMPOSE_FILE"
test -f "$CREDENTIALS_FILE"
FIRST_COMPOSE_HASH="$(sha256sum "$COMPOSE_FILE" | awk '{print $1}')"
FIRST_CREDENTIALS_HASH="$(sha256sum "$CREDENTIALS_FILE" | awk '{print $1}')"
FIRST_SECRETS="$(secret_fingerprint "$COMPOSE_FILE")"

# A second apply with the same desired state must be a true no-op.
run_hao apply --profile "$ENSURE_PROFILE" --yes > "$TMP_DIR/second-apply"
grep -q 'no-op' "$TMP_DIR/second-apply"
test "$FIRST_COMPOSE_HASH" = "$(sha256sum "$COMPOSE_FILE" | awk '{print $1}')"
test "$FIRST_CREDENTIALS_HASH" = "$(sha256sum "$CREDENTIALS_FILE" | awk '{print $1}')"

# An explicit same-engine upgrade may rewrite managed config but must reuse secrets.
run_hao apply --profile "$UPGRADE_PROFILE" --yes > "$TMP_DIR/upgrade-apply"
grep -q 'action: upgrade' "$TMP_DIR/upgrade-apply"
test "$FIRST_SECRETS" = "$(secret_fingerprint "$COMPOSE_FILE")"

# A database-engine change is never smuggled through an upgrade or default ensure.
if [ "$DB_TYPE" = "postgresql" ]; then
  OTHER_DB="mysql"
else
  OTHER_DB="postgresql"
fi
write_profile "$MISMATCH_PROFILE" upgrade "$OTHER_DB"
if run_hao apply --profile "$MISMATCH_PROFILE" --yes > "$TMP_DIR/mismatch-output" 2>&1; then
  echo "Cross-engine change unexpectedly passed as an upgrade" >&2
  exit 1
fi
grep -q '数据库迁移必须使用独立流程' "$TMP_DIR/mismatch-output"
test "$FIRST_SECRETS" = "$(secret_fingerprint "$COMPOSE_FILE")"

write_profile "$MIGRATE_PROFILE" migrate-db "$OTHER_DB"
if run_hao apply --profile "$MIGRATE_PROFILE" --yes > "$TMP_DIR/migrate-output" 2>&1; then
  echo "Unsupported automatic database migration unexpectedly passed" >&2
  exit 1
fi
grep -q '不自动执行 PostgreSQL/MySQL 跨引擎迁移' "$TMP_DIR/migrate-output"

echo "New-API $DB_TYPE two-apply idempotency test passed."
