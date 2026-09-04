#!/usr/bin/env bash
# node 模块的非 root 单元测试：-h 帮助、环境变量校验、root 前置检查。
# 说明：根 CLI（plan/preflight/apply）注册在后续批次由其他任务完成，
# 注册后才有 plan 输出可断言，本测试暂不含 plan 相关断言。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT_DIR/node/install.sh"

# --- -h / --help 退出码为 0，且列出全部配置变量 ---
help_out="$("$INSTALL" -h)"
grep -q 'HAO_NODE_VERSION' <<<"$help_out"
grep -q 'HAO_NODE_ACTION' <<<"$help_out"
"$INSTALL" --help >/dev/null

# --- 无效 HAO_NODE_ACTION 必须以非零退出拒绝 ---
bad_action_out=""
if bad_action_out="$(HAO_NODE_ACTION=bogus "$INSTALL" 2>&1)"; then
  echo "Invalid HAO_NODE_ACTION unexpectedly accepted" >&2
  exit 1
fi
grep -q '无效的 HAO_NODE_ACTION' <<<"$bad_action_out"

if HAO_NODE_ACTION=ENSURE "$INSTALL" >/dev/null 2>&1; then
  echo "Uppercase HAO_NODE_ACTION unexpectedly accepted (must be case-sensitive)" >&2
  exit 1
fi

# --- 无效 HAO_NODE_VERSION 必须以非零退出拒绝 ---
for bad_version in abc 22x v22 22.1 '22;id' '-1'; do
  bad_version_out=""
  if bad_version_out="$(HAO_NODE_VERSION="$bad_version" "$INSTALL" 2>&1)"; then
    echo "Invalid HAO_NODE_VERSION '$bad_version' unexpectedly accepted" >&2
    exit 1
  fi
  if ! grep -q '无效的 HAO_NODE_VERSION' <<<"$bad_version_out"; then
    echo "Invalid HAO_NODE_VERSION '$bad_version' rejected without proper message" >&2
    exit 1
  fi
done

# --- 合法参数但非 root：应停在 root 前置检查（证明参数校验已通过）---
# 仅在非 root 下执行该组断言；root 下运行会继续真实安装，跳过。
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  non_root_out=""
  if non_root_out="$(HAO_UNATTENDED=1 "$INSTALL" 2>&1)"; then
    echo "Non-root run unexpectedly succeeded" >&2
    exit 1
  fi
  grep -q '必须使用 root' <<<"$non_root_out"

  # 合法取值组合不得被参数校验误伤
  for action in ensure upgrade; do
    for version in 20 22; do
      out=""
      if out="$(HAO_UNATTENDED=1 HAO_NODE_ACTION="$action" HAO_NODE_VERSION="$version" "$INSTALL" 2>&1)"; then
        echo "Non-root run unexpectedly succeeded" >&2
        exit 1
      fi
      if ! grep -q '必须使用 root' <<<"$out"; then
        echo "Valid env (action=$action version=$version) failed for an unexpected reason:" >&2
        echo "$out" >&2
        exit 1
      fi
    done
  done
fi

echo "node unit test passed."
