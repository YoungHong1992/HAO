#!/usr/bin/env bash
# node 模块幂等性测试（需要 root；会经 apt 把 Node.js 安装到系统）。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "This integration test must run as root." >&2
  exit 1
fi

export HAO_UNATTENDED=1

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

SRC_FILE="/etc/apt/sources.list.d/nodesource.list"
PRE_EXISTING=false
if [ -f "$SRC_FILE" ]; then
  PRE_EXISTING=true
fi

# === 第一次安装 ===
"$ROOT_DIR/node/install.sh"

[ -x /usr/bin/node ]
[ -x /usr/bin/npm ]
node --version
npm --version
NODE_V="$(node --version)"
NODE_MAJOR_INSTALLED="${NODE_V#v}"
NODE_MAJOR_INSTALLED="${NODE_MAJOR_INSTALLED%%.*}"
if [ "$NODE_MAJOR_INSTALLED" != "22" ]; then
  echo "Expected Node.js major 22, got: $NODE_V" >&2
  exit 1
fi

# 快照 apt 源文件，用于校验第二次运行为 no-op
SNAPSHOT="$WORK_DIR/nodesource.list.first"
SRC_PRESENT=false
if [ -f "$SRC_FILE" ]; then
  SRC_PRESENT=true
  cp -a "$SRC_FILE" "$SNAPSHOT"
fi

# === 第二次安装（默认 ensure：必须干净 no-op）===
"$ROOT_DIR/node/install.sh"

[ -x /usr/bin/node ]
node --version >/dev/null
npm --version >/dev/null

if [ "$SRC_PRESENT" = true ]; then
  if ! cmp -s "$SNAPSHOT" "$SRC_FILE"; then
    echo "apt source file changed between identical ensure runs (not idempotent)" >&2
    diff "$SNAPSHOT" "$SRC_FILE" >&2 || true
    exit 1
  fi
elif [ -f "$SRC_FILE" ]; then
  echo "apt source file appeared during a no-op ensure run (not idempotent)" >&2
  exit 1
fi

# 源文件若是本模块写入（测试前不存在），必须带 HAO 管理头
if [ "$PRE_EXISTING" = false ] && [ "$SRC_PRESENT" = true ]; then
  grep -q 'Managed by HAO' "$SRC_FILE"
  grep -q 'Service: node' "$SRC_FILE"
  grep -q 'node_22.x' "$SRC_FILE"
fi

# === 显式 upgrade 路径 ===
HAO_NODE_ACTION=upgrade "$ROOT_DIR/node/install.sh"
node --version >/dev/null
npm --version >/dev/null

echo "node idempotency test passed."
