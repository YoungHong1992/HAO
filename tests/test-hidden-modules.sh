#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# science/ may exist in the repository, but it must not be mentioned by public
# docs, root installer, or release packaging.
if find "$ROOT_DIR" \
    -path "$ROOT_DIR/.git" -prune -o \
    -path "$ROOT_DIR/science" -prune -o \
    -path "$ROOT_DIR/tests" -prune -o \
    -type f \( -name '*.md' -o -name '*.sh' -o -name '*.yml' -o -name '*.yaml' \) -print0 \
    | xargs -0 grep -InE 'science|VLESS|Xray|Reality' >/tmp/hao-hidden-module-grep.txt; then
  cat /tmp/hao-hidden-module-grep.txt >&2
  rm -f /tmp/hao-hidden-module-grep.txt
  echo "Hidden module leaked into public files" >&2
  exit 1
fi
rm -f /tmp/hao-hidden-module-grep.txt

if grep -q ' science ' "$ROOT_DIR/.github/workflows/release.yml"; then
  echo "science is included in release bundle" >&2
  exit 1
fi
