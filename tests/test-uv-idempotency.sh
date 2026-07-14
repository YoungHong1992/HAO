#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "This integration test must run as root." >&2
  exit 1
fi

export HAO_UNATTENDED=1

# 目标用户使用 root，避免依赖 runner 上的其他账户
export HAO_UV_USER=root
# 通过显式文件模拟四类 agent 指令文件，验证检测覆盖与标记块写入
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
EXISTING_FILE="$WORK_DIR/CLAUDE.md"
NEW_FILE="$WORK_DIR/nested/AGENTS.md"
printf '# 用户已有指令\n\n保持这行不动。\n' > "$EXISTING_FILE"
export HAO_UV_AGENT_FILES="$EXISTING_FILE,$NEW_FILE"

# === 第一次安装 ===
"$ROOT_DIR/uv/install.sh"

command -v uv >/dev/null
command -v uvx >/dev/null
uv --version

# 约定写入：已有文件保留原内容并追加标记块；不存在的文件被创建
grep -q '用户已有指令' "$EXISTING_FILE"
grep -q 'HAO-UV BEGIN' "$EXISTING_FILE"
grep -q 'HAO-UV END' "$EXISTING_FILE"
grep -q 'uv venv' "$EXISTING_FILE"
test -f "$NEW_FILE"
grep -q 'HAO-UV BEGIN' "$NEW_FILE"

FIRST_HASH="$(sha256sum "$EXISTING_FILE" | cut -d' ' -f1)"
UV_BIN="$(command -v uv)"
UV_BIN_HASH="$(sha256sum "$UV_BIN" | cut -d' ' -f1)"

# === 第二次安装（默认 ensure：uv 保持不动，约定原地刷新）===
"$ROOT_DIR/uv/install.sh"

command -v uv >/dev/null
if [ "$(sha256sum "$UV_BIN" | cut -d' ' -f1)" != "$UV_BIN_HASH" ]; then
  echo "uv binary changed under default ensure action (should keep existing version)" >&2
  exit 1
fi

# 标记块必须原地替换而不是重复追加
begin_count="$(grep -c 'HAO-UV BEGIN' "$EXISTING_FILE")"
if [ "$begin_count" -ne 1 ]; then
  echo "Expected exactly 1 HAO-UV block after re-run, got $begin_count" >&2
  exit 1
fi
grep -q '用户已有指令' "$EXISTING_FILE"

SECOND_HASH="$(sha256sum "$EXISTING_FILE" | cut -d' ' -f1)"
if [ "$FIRST_HASH" != "$SECOND_HASH" ]; then
  echo "Convention file changed between identical runs (not idempotent)" >&2
  diff <(echo "$FIRST_HASH") <(echo "$SECOND_HASH") || true
  exit 1
fi

# === 显式升级路径 ===
HAO_UV_ACTION=upgrade HAO_UV_SKIP_AGENT_CONVENTION=1 "$ROOT_DIR/uv/install.sh"
command -v uv >/dev/null

# === Python 预装（小版本，验证 uv python install 路径）===
HAO_UV_SKIP_AGENT_CONVENTION=1 HAO_UV_PYTHON=3.12 "$ROOT_DIR/uv/install.sh"
uv python find 3.12 >/dev/null

echo "uv idempotency test passed."
