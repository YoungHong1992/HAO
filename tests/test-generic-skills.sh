#!/usr/bin/env bash
set -euo pipefail

# skill 必须保持 runtime 中立：它会被分发给多种 AI agent 运行时，
# 不能写成只服务于某一个产品。历史上有过一个 agent 专属的 skill 目录，
# 已归一到 skills/，这份测试防止回退。

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LEGACY_SKILL_DIR="co""dex-skills"
LEGACY_AGENT_NAME_UPPER="Co""dex"
LEGACY_AGENT_NAME_LOWER="co""dex"

if [ -e "$ROOT_DIR/$LEGACY_SKILL_DIR" ]; then
  echo "Legacy agent-specific skill directory should be generalized to skills/" >&2
  exit 1
fi

if [ ! -f "$ROOT_DIR/skills/hao-deploy/SKILL.md" ]; then
  echo "Missing generic HAO deploy skill" >&2
  exit 1
fi

scan_targets=("$ROOT_DIR/skills" "$ROOT_DIR/README.md")
[ -d "$ROOT_DIR/.github/workflows" ] && scan_targets+=("$ROOT_DIR/.github/workflows")

if find "${scan_targets[@]}" \
    -type f \( -name '*.md' -o -name '*.yaml' -o -name '*.yml' -o -name '*.sh' \) -print0 \
    | xargs -0 grep -InE "${LEGACY_SKILL_DIR}|${LEGACY_AGENT_NAME_UPPER}|${LEGACY_AGENT_NAME_LOWER}" \
    >/tmp/hao-generic-skill-grep.txt; then
  cat /tmp/hao-generic-skill-grep.txt >&2
  rm -f /tmp/hao-generic-skill-grep.txt
  echo "Skill still contains agent-specific references" >&2
  exit 1
fi
rm -f /tmp/hao-generic-skill-grep.txt
echo "generic skill 测试通过"
