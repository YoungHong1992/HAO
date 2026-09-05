#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 隐藏模块可以存在于仓库中，但不得被任何公开文件引用，也不得进入分发物。
# 分发现在走插件市场（git 仓库整体），因此"不进 tarball"这条已改为
# "不被公开文件提及" —— 见 README 的分发说明。
if find "$ROOT_DIR" \
    -path "$ROOT_DIR/.git" -prune -o \
    -path "$ROOT_DIR/science" -prune -o \
    -path "$ROOT_DIR/tests" -prune -o \
    -type f \( -name '*.md' -o -name '*.sh' -o -name '*.yml' -o -name '*.yaml' -o -name '*.json' \) -print0 \
    | xargs -0 grep -InE 'science|VLESS|Xray|Reality' >/tmp/hao-hidden-module-grep.txt; then
  cat /tmp/hao-hidden-module-grep.txt >&2
  rm -f /tmp/hao-hidden-module-grep.txt
  echo "Hidden module leaked into public files" >&2
  exit 1
fi
rm -f /tmp/hao-hidden-module-grep.txt
echo "hidden modules 测试通过"
