#!/usr/bin/env bash
# CliproxyAPI 幂等/密钥复用集成测试（对标 tests/test-newapi-idempotency.sh）。
#
# ⚠️  本测试会修改机器状态（以 root 运行、启动本地监听、写入临时目录），
#     仅应在 CI 或一次性 VM 中执行。
#
# 覆盖：
#   docker 模式 —— 通过 `hao apply` 编排：两次 apply 均成功、管理密钥不轮换、
#                    config.yaml 与 compose 内容稳定、凭据/配置文件权限 0600。
#   bare 模式   —— 同版本再次 apply 触发「已是最新，无需升级」早退，
#                    验证升级路径不会重新生成 API 密钥/管理密码（密钥复用）。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "This integration test must run as root." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to open a local readiness listener for this test." >&2
  exit 1
fi

CLIPROXY_PORT=8317

TMP_DIR="$(mktemp -d)"
LISTENER_PID=""
cleanup() {
  [ -n "$LISTENER_PID" ] && kill "$LISTENER_PID" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

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
  "compose ps") echo "cliproxyapi Up (healthy)" ;;
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

# GitHub release API 调用返回固定版本 JSON，其余（如 detect_server_ip）返回本地 IP。
cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    *api.github.com*) printf '{"tag_name": "v9.9.9"}\n'; exit 0 ;;
  esac
done
printf '127.0.0.1\n'
EOF

# 注意：不桩掉 openssl/wget/tar —— 安全密钥生成依赖真实 openssl，
# 且 ensure_commands 仅需它们存在（真实二进制在 PATH 中，位于 FAKE_BIN 之后）。
cat > "$FAKE_BIN/ss" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cp "$FAKE_BIN/ss" "$FAKE_BIN/netstat"
chmod +x "$FAKE_BIN"/*

OS_RELEASE="$TMP_DIR/os-release"
printf 'ID=ubuntu\nVERSION_ID="24.04"\n' > "$OS_RELEASE"

# CliproxyAPI 的真实就绪探测会从宿主机 TCP 连接 127.0.0.1:8317，
# 故开一个真实监听让 wait_for_local_port 通过（伪 ss 使端口在预检时仍显示空闲）。
python3 - "$CLIPROXY_PORT" <<'PY' &
import socket, sys, time
port = int(sys.argv[1])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(16)
time.sleep(3600)
PY
LISTENER_PID=$!
# 等待监听就绪
for _ in $(seq 1 50); do
  if timeout 2 bash -c ">/dev/tcp/127.0.0.1/${CLIPROXY_PORT}" 2>/dev/null; then break; fi
  sleep 0.1
done

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

# config.yaml 内的机密指纹：API 密钥行 + 管理密码行
secret_fingerprint() {
  local config_file="$1"
  grep -E '(- "sk-|secret-key:)' "$config_file" | sha256sum | awk '{print $1}'
}

perms_of() { stat -c '%a' "$1"; }

################################################################################
# 1) docker 模式 —— 通过 hao apply 两次编排
################################################################################
PROFILE="$TMP_DIR/cpa.env"
cat > "$PROFILE" <<EOF
HAO_SERVICES="cliproxyapi"
HAO_ACCESS_MODE="http"
HAO_CLIPROXY_DOMAIN="127.0.0.1"
HAO_CLIPROXY_MODE="docker"
HAO_CLIPROXY_IMAGE="eceasy/cli-proxy-api:v7.2.71"
EOF

run_hao apply --profile "$PROFILE" --yes > "$TMP_DIR/first-apply"
SERVICE_DIR="$DOCKER_ROOT/cliproxyapi"
COMPOSE_FILE="$SERVICE_DIR/docker-compose.yml"
CONFIG_FILE="$SERVICE_DIR/config.yaml"
CREDENTIALS_FILE="$SERVICE_DIR/hao-credentials.txt"

test -f "$COMPOSE_FILE"
test -f "$CONFIG_FILE"
test -f "$CREDENTIALS_FILE"
grep -q 'eceasy/cli-proxy-api:v7.2.71' "$COMPOSE_FILE"

# 机密文件权限必须为 0600
test "$(perms_of "$CONFIG_FILE")" = "600"
test "$(perms_of "$CREDENTIALS_FILE")" = "600"

FIRST_COMPOSE_HASH="$(sha256sum "$COMPOSE_FILE" | awk '{print $1}')"
FIRST_SECRETS="$(secret_fingerprint "$CONFIG_FILE")"
FIRST_CONFIG_HASH="$(sha256sum "$CONFIG_FILE" | awk '{print $1}')"

# 第二次 apply：CPA 检测到既有 compose → 升级路径，须保留配置与密钥。
run_hao apply --profile "$PROFILE" --yes > "$TMP_DIR/second-apply"

test -f "$COMPOSE_FILE"
# 升级不得轮换密钥：config.yaml（含 api-keys / secret-key）保持不变。
test "$FIRST_CONFIG_HASH" = "$(sha256sum "$CONFIG_FILE" | awk '{print $1}')"
test "$FIRST_SECRETS" = "$(secret_fingerprint "$CONFIG_FILE")"
# 托管 compose 内容稳定（相同镜像/发布标识）。
test "$FIRST_COMPOSE_HASH" = "$(sha256sum "$COMPOSE_FILE" | awk '{print $1}')"
# 权限在二次 apply 后仍为 0600。
test "$(perms_of "$CONFIG_FILE")" = "600"
test "$(perms_of "$CREDENTIALS_FILE")" = "600"

echo "CliproxyAPI docker two-apply idempotency test passed."

################################################################################
# 2) bare 模式 —— 同版本再次 apply 触发早退，验证密钥复用（不轮换）
################################################################################
BARE_INSTALL_DIR="/opt/cliproxyapi"
BARE_CONFIG_DIR="/etc/cliproxyapi"

# 安全护栏：绝不触碰真实的裸机安装。
if [ -e "$BARE_INSTALL_DIR" ] || [ -e "$BARE_CONFIG_DIR" ]; then
  echo "SKIP bare-mode secret-reuse: 检测到既有裸机安装路径，跳过以免影响真实环境。" >&2
else
  bare_cleanup() { rm -rf "$BARE_INSTALL_DIR" "$BARE_CONFIG_DIR"; }
  trap 'bare_cleanup; cleanup' EXIT

  mkdir -p "$BARE_INSTALL_DIR" "$BARE_CONFIG_DIR"
  # 与 fake curl 返回的 tag v9.9.9 一致 → 触发「已是最新，无需升级」早退。
  printf '9.9.9\n' > "$BARE_INSTALL_DIR/version.txt"
  install -m 600 /dev/null "$BARE_CONFIG_DIR/config.yaml"
  cat > "$BARE_CONFIG_DIR/config.yaml" <<'YAML'
host: "127.0.0.1"
port: 8317
auth-dir: "/var/lib/cliproxyapi/auth"
api-keys:
  - "sk-existing-key-one"
  - "sk-existing-key-two"
remote-management:
  allow-remote: true
  secret-key: "existing-admin-secret"
YAML
  chmod 600 "$BARE_CONFIG_DIR/config.yaml"
  BARE_SECRETS_BEFORE="$(secret_fingerprint "$BARE_CONFIG_DIR/config.yaml")"

  run_bare() {
    env \
      PATH="$FAKE_BIN:$PATH" \
      HAO_UNATTENDED=1 \
      HAO_CLIPROXY_MODE=bare \
      HAO_NGINX_CONF_DIR="$NGINX_CONF_DIR" \
      HAO_NGINX_SSL_DIR="$NGINX_SSL_DIR" \
      HAO_DEPLOY_LOG_DIR="$LOG_DIR" \
      HAO_OS_RELEASE_FILE="$OS_RELEASE" \
      "$ROOT_DIR/cliproxyapi/install.sh"
  }

  run_bare > "$TMP_DIR/bare-first" 2>&1
  grep -q '已是最新版本' "$TMP_DIR/bare-first"
  test "$BARE_SECRETS_BEFORE" = "$(secret_fingerprint "$BARE_CONFIG_DIR/config.yaml")"

  # 再来一次：仍为早退，密钥依旧不变。
  run_bare > "$TMP_DIR/bare-second" 2>&1
  grep -q '已是最新版本' "$TMP_DIR/bare-second"
  test "$BARE_SECRETS_BEFORE" = "$(secret_fingerprint "$BARE_CONFIG_DIR/config.yaml")"

  bare_cleanup
  trap cleanup EXIT
  echo "CliproxyAPI bare-mode secret-reuse test passed."
fi

echo "CliproxyAPI idempotency test passed."
