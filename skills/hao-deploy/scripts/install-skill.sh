#!/usr/bin/env bash
set -euo pipefail

# Install the hao-deploy Agent Skill into an agent runtime's skill directory.
# Default target is Claude Code (~/.claude/skills). Use --dir for other runtimes.
#
# Default mode is symlink: the skill stays thin and `git pull` in the repo
# updates the capability. Use --copy for runtimes that do not follow symlinks.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_NAME="$(basename "$SKILL_DIR")"

TARGET_BASE="$HOME/.claude/skills"
MODE="symlink"
FORCE=false

usage() {
    cat <<EOF
Usage: install-skill.sh [--dir TARGET_DIR] [--copy] [--force]

Options:
  --dir TARGET_DIR   Skill directory of the agent runtime
                     (default: ~/.claude/skills for Claude Code)
  --copy             Copy the skill instead of symlinking
  --force            Replace an existing ${SKILL_NAME} entry in the target
  -h, --help         Show this help

The skill wraps the hao CLI in this repository. With a symlink install,
updating the repository updates the skill. With --copy, re-run this script
after updating the repository, or set HAO_REPO_DIR so the copied skill can
find the repo.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dir)
            TARGET_BASE="${2:-}"
            [ -n "$TARGET_BASE" ] || { echo "install-skill: --dir requires a value" >&2; exit 1; }
            shift 2
            ;;
        --copy)
            MODE="copy"
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "install-skill: unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [ ! -f "$SKILL_DIR/SKILL.md" ]; then
    echo "install-skill: SKILL.md not found at $SKILL_DIR" >&2
    exit 1
fi

TARGET="$TARGET_BASE/$SKILL_NAME"
mkdir -p "$TARGET_BASE"

if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
    if [ "$FORCE" != true ]; then
        echo "install-skill: $TARGET already exists (use --force to replace)" >&2
        exit 1
    fi
    rm -rf "$TARGET"
fi

if [ "$MODE" = "symlink" ]; then
    ln -s "$SKILL_DIR" "$TARGET"
    echo "Symlinked $SKILL_DIR -> $TARGET"
    echo "Repo updates apply automatically (skill resolves the repo via its own path)."
else
    cp -a "$SKILL_DIR" "$TARGET"
    echo "Copied $SKILL_DIR -> $TARGET"
    echo "Note: a copied skill cannot locate the repo by its own path."
    echo "Set HAO_REPO_DIR=$(cd "$SKILL_DIR/../.." && pwd) in the agent environment."
fi
