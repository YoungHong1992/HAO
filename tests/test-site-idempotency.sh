#!/usr/bin/env bash
# site 模块静态站点幂等集成测试（对标 tests/test-uv-idempotency.sh）。
#
# ⚠️  本测试会修改机器状态（以 root 运行，写 /opt/hao-sites、/var/www/hao-sites、
#     /etc/nginx/conf.d、/usr/local/bin），仅应在 CI 或一次性 VM 中执行；
#     退出时通过 trap 清理全部生成物，重复执行安全。
#
# 覆盖：本地 git 仓库 fixture + static 类型 + 无 BUILD + OUTPUT 默认(".") +
#       DOMAIN 留空（80 端口默认站点）。nginx/git 缺失时优雅跳过（exit 0）。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "This integration test must run as root." >&2
  exit 1
fi

# CI 容器可能未安装 nginx/git：跳过而不是失败（HAO nginx 模块已在验收机器上安装）
if ! command -v nginx >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  echo "SKIP: 需要已安装 nginx 与 git，当前环境缺失，跳过 site 集成测试。" >&2
  exit 0
fi

TMP_DIR="$(mktemp -d)"
FIXTURE="$TMP_DIR/repo"
CONF_FILE="/etc/nginx/conf.d/hao-site-demo.conf"
UPDATE_SCRIPT="/usr/local/bin/hao-site-update-demo"
MARKER="hao-site-demo-ok-$$"

cleanup() {
  rm -f "$UPDATE_SCRIPT" "$CONF_FILE" "$CONF_FILE".bak.*
  rm -rf /opt/hao-sites/demo /var/www/hao-sites/demo "$TMP_DIR"
  systemctl reload nginx >/dev/null 2>&1 || true
}
trap cleanup EXIT

# === 构造本地 git 仓库 fixture（单文件静态站点，main 分支） ===
mkdir -p "$FIXTURE"
git -C "$FIXTURE" init -q
git -C "$FIXTURE" checkout -q -b main
printf '<h1>%s</h1>\n' "$MARKER" > "$FIXTURE/index.html"
git -C "$FIXTURE" add index.html
git -C "$FIXTURE" -c user.name="HAO Test" -c user.email="hao-test@example.com" commit -qm "init"

# === 桩掉 curl：DOMAIN 留空时完成摘要中的 detect_server_ip 需要访问公网 ===
FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"
printf '#!/usr/bin/env bash\nprintf "127.0.0.1\\n"\n' > "$FAKE_BIN/curl"
chmod +x "$FAKE_BIN/curl"

run_install() {
  env \
    PATH="$FAKE_BIN:$PATH" \
    HAO_UNATTENDED=1 \
    HAO_DEPLOY_LOG_DIR="$TMP_DIR/logs" \
    HAO_SITES="demo" \
    HAO_SITE_DEMO_REPO="$FIXTURE" \
    HAO_SITE_DEMO_TYPE="static" \
    HAO_SITE_DEMO_TARGET_USER="root" \
    "$ROOT_DIR/site/install.sh"
}

# === 第一次部署 ===
if ! run_install >"$TMP_DIR/first.log" 2>&1; then
  cat "$TMP_DIR/first.log" >&2
  exit 1
fi

test -x "$UPDATE_SCRIPT"
grep -q 'Managed by HAO' "$CONF_FILE"
grep -q '^# HAO-SITE: demo$' "$CONF_FILE"
grep -q "$MARKER" /var/www/hao-sites/demo/index.html
# OUTPUT="." 发布仓库根目录时必须排除 .git
test ! -e /var/www/hao-sites/demo/.git
FIRST_CONF_HASH="$(sha256sum "$CONF_FILE" | awk '{print $1}')"

# === 更新脚本可独立运行 ===
if ! "$UPDATE_SCRIPT" >"$TMP_DIR/update.log" 2>&1; then
  cat "$TMP_DIR/update.log" >&2
  exit 1
fi
grep -q '完成' "$TMP_DIR/update.log"

# === 第二次部署（幂等） ===
if ! run_install >"$TMP_DIR/second.log" 2>&1; then
  cat "$TMP_DIR/second.log" >&2
  exit 1
fi
test -x "$UPDATE_SCRIPT"
grep -q "$MARKER" /var/www/hao-sites/demo/index.html
if [ "$FIRST_CONF_HASH" != "$(sha256sum "$CONF_FILE" | awk '{print $1}')" ]; then
  echo "vhost conf changed between identical runs (not idempotent)" >&2
  exit 1
fi

echo "site idempotency test passed."
