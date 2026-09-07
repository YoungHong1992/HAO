#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 隐藏模块可以存在于仓库中，但不得被任何公开文件引用，也不得进入分发物。
# 分发现在走插件市场（git 仓库整体），因此"不进 tarball"这条已改为
# "不被公开文件提及" —— 见 README 的分发说明。
HITS="$(mktemp)"
trap 'rm -f "$HITS"' EXIT

# 扫的是**所有跟踪中的文本文件**，不再按扩展名挑。按扩展名挑会漏掉无扩展名的
# 文件（.gitignore、LICENSE、apt preferences 之类），而那类文件一样会被分发出去。
# -I 让 grep 跳过二进制文件。
if git -C "$ROOT_DIR" ls-files -z \
    ':!:science/*' ':!:tests/*' \
    | xargs -0 grep -InE 'science|VLESS|Xray|Reality' >"$HITS"; then
  cat "$HITS" >&2
  echo "Hidden module leaked into public files" >&2
  exit 1
fi

# 兜底：未跟踪但存在于工作区的文件也不该提及（比如本地的 deploy.env）。
# 这些文件不会被分发，所以只告警不失败。
if untracked="$(git -C "$ROOT_DIR" ls-files -z --others --exclude-standard \
    ':!:science/*' ':!:tests/*' | xargs -0 -r grep -IlE 'science|VLESS|Xray|Reality' 2>/dev/null)" \
    && [ -n "$untracked" ]; then
  echo "warning: 未跟踪文件里提到了隐藏模块（不影响分发，但注意别提交）:" >&2
  printf '  %s\n' "$untracked" >&2
fi

echo "hidden modules 测试通过"
