#!/usr/bin/env bash
# site 模块单元测试（非 root）。
#
# 设计说明：site/install.sh 的全部配置校验与解析（resolve_all_sites）在
# check_root 之前执行（与 git-github 的结构一致），因此本测试以普通用户身份
# 即可覆盖所有校验失败路径；校验通过后才会要求 root 权限。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$ROOT_DIR/site/install.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# 期望失败并包含指定错误文本。用法: expect_fail <名称> <期望文本> [VAR=value ...]
expect_fail() {
  local name="$1" expect="$2"
  shift 2
  local out
  if out="$(env "$@" bash "$INSTALL_SH" 2>&1)"; then
    echo "FAIL [$name]: 期望非零退出，但命令成功了" >&2
    exit 1
  fi
  if ! grep -qF "$expect" <<<"$out"; then
    echo "FAIL [$name]: 输出未包含期望文本: $expect" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  printf 'ok: %s\n' "$name"
}

# === -h 帮助 ===
bash "$INSTALL_SH" -h >"$TMP_DIR/help" 2>&1
grep -q 'HAO_SITES' "$TMP_DIR/help"
bash "$INSTALL_SH" --help >/dev/null 2>&1
echo "ok: -h/--help"

# === 未知参数 ===
if bash "$INSTALL_SH" --foo >/dev/null 2>&1; then
  echo "FAIL [unknown argument]: 期望非零退出，但命令成功了" >&2
  exit 1
fi
echo "ok: unknown argument"

# === HAO_SITES 未设置 ===
expect_fail "missing HAO_SITES" "HAO_SITES 未设置"

# === 无效站点 ID ===
expect_fail "invalid site id (uppercase)" "无效的站点 ID" \
  HAO_SITES=Blog HAO_SITE_BLOG_REPO=/tmp/x HAO_SITE_BLOG_TYPE=static
expect_fail "empty site id entry" "空条目" \
  HAO_SITES="blog,,tools"
expect_fail "duplicate site id" "站点 ID 重复" \
  HAO_SITES="demo,demo"

# === TYPE ===
expect_fail "missing TYPE" "HAO_SITE_DEMO_TYPE" \
  HAO_SITES=demo HAO_SITE_DEMO_REPO=/tmp/x
expect_fail "invalid TYPE" "static | node" \
  HAO_SITES=demo HAO_SITE_DEMO_REPO=/tmp/x HAO_SITE_DEMO_TYPE=bogus

# === REPO ===
expect_fail "missing REPO" "HAO_SITE_DEMO_REPO" \
  HAO_SITES=demo HAO_SITE_DEMO_TYPE=static

# === DOMAIN ===
expect_fail "invalid domain" "域名格式不正确" \
  HAO_SITES=demo HAO_SITE_DEMO_REPO=/tmp/x HAO_SITE_DEMO_TYPE=static HAO_SITE_DEMO_DOMAIN=bad_domain
expect_fail "duplicate domains" "域名冲突" \
  HAO_SITES="a,b" \
  HAO_SITE_A_REPO=/tmp/x HAO_SITE_A_TYPE=static HAO_SITE_A_DOMAIN=blog.example.com \
  HAO_SITE_B_REPO=/tmp/y HAO_SITE_B_TYPE=static HAO_SITE_B_DOMAIN=blog.example.com
expect_fail "two sites without domain" "默认站点只能有一个" \
  HAO_SITES="a,b" \
  HAO_SITE_A_REPO=/tmp/x HAO_SITE_A_TYPE=static \
  HAO_SITE_B_REPO=/tmp/y HAO_SITE_B_TYPE=static

# === BRANCH ===
expect_fail "invalid branch" "BRANCH 非法" \
  HAO_SITES=demo HAO_SITE_DEMO_REPO=/tmp/x HAO_SITE_DEMO_TYPE=static HAO_SITE_DEMO_BRANCH="bad branch"

# === CERT / REDIRECT 取值 ===
expect_fail "invalid CERT value" "CERT 只能是 yes 或 no" \
  HAO_SITES=demo HAO_SITE_DEMO_REPO=/tmp/x HAO_SITE_DEMO_TYPE=static HAO_SITE_DEMO_CERT=maybe
expect_fail "invalid REDIRECT value" "REDIRECT 只能是 yes 或 no" \
  HAO_SITES=demo HAO_SITE_DEMO_REPO=/tmp/x HAO_SITE_DEMO_TYPE=static HAO_SITE_DEMO_REDIRECT=maybe

# === OUTPUT 路径安全 ===
expect_fail "OUTPUT with dotdot" "OUTPUT 非法" \
  HAO_SITES=demo HAO_SITE_DEMO_REPO=/tmp/x HAO_SITE_DEMO_TYPE=static HAO_SITE_DEMO_OUTPUT="../evil"
expect_fail "OUTPUT absolute" "OUTPUT 非法" \
  HAO_SITES=demo HAO_SITE_DEMO_REPO=/tmp/x HAO_SITE_DEMO_TYPE=static HAO_SITE_DEMO_OUTPUT="/etc"

# === PORT ===
expect_fail "invalid port" "端口必须是 1-65535" \
  HAO_SITES=demo HAO_SITE_DEMO_REPO=/tmp/x HAO_SITE_DEMO_TYPE=node HAO_SITE_DEMO_PORT=abc
expect_fail "duplicate ports" "端口冲突" \
  HAO_SITES="a,b" \
  HAO_SITE_A_REPO=/tmp/x HAO_SITE_A_TYPE=node HAO_SITE_A_PORT=8399 \
  HAO_SITE_B_REPO=/tmp/y HAO_SITE_B_TYPE=node HAO_SITE_B_PORT=8399

# === ENV ===
expect_fail "ENV entry without equals" "ENV 条目无效" \
  HAO_SITES=demo HAO_SITE_DEMO_REPO=/tmp/x HAO_SITE_DEMO_TYPE=node HAO_SITE_DEMO_ENV="FOO"
expect_fail "ENV bad key" "ENV 变量名非法" \
  HAO_SITES=demo HAO_SITE_DEMO_REPO=/tmp/x HAO_SITE_DEMO_TYPE=node HAO_SITE_DEMO_ENV="1FOO=bar"
expect_fail "ENV must not set PORT" "请勿在 ENV 中设置 PORT" \
  HAO_SITES=demo HAO_SITE_DEMO_REPO=/tmp/x HAO_SITE_DEMO_TYPE=node HAO_SITE_DEMO_ENV="PORT=9999"

# === 目标用户 ===
expect_fail "target user missing" "目标用户不存在" \
  HAO_SITES=demo HAO_SITE_DEMO_REPO=/tmp/x HAO_SITE_DEMO_TYPE=static \
  HAO_SITE_DEMO_TARGET_USER=hao_no_such_user_99

# === 校验通过后才会要求 root（仅非 root 时执行，root 下会真正部署） ===
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  expect_fail "valid static config requires root" "必须使用 root" \
    HAO_UNATTENDED=1 \
    HAO_SITES=blog HAO_SITE_BLOG_REPO=/tmp/x HAO_SITE_BLOG_TYPE=static \
    HAO_SITE_BLOG_DOMAIN=blog.example.com

  # 多站点 + node 端口自动分配路径（8100 起）也应通过校验、停在 root 检查
  expect_fail "multi-site node auto-port requires root" "必须使用 root" \
    HAO_UNATTENDED=1 \
    HAO_SITES="api,web" \
    HAO_SITE_API_REPO=/tmp/x HAO_SITE_API_TYPE=node HAO_SITE_API_DOMAIN=api.example.com \
    HAO_SITE_WEB_REPO=/tmp/y HAO_SITE_WEB_TYPE=node HAO_SITE_WEB_DOMAIN=web.example.com
else
  echo "skip: root 环境下跳过「校验通过 -> root 检查」用例"
fi

echo "site validation test passed."
