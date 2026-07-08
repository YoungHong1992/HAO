#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$ROOT_DIR/install.sh"

if grep -nE '^(main|show_service_panel|select_services|show_review|configure_access_mode|collect_service_configs|show_selected_service_overview|prompt_return_home)\(\)' "$INSTALL_SH"; then
  echo "Root install.sh still contains interactive menu flow functions" >&2
  exit 1
fi

if grep -nE 'read[[:space:]]+-r[[:space:]].*-p' "$INSTALL_SH"; then
  echo "Root install.sh should not prompt for terminal input" >&2
  exit 1
fi

if ! "$ROOT_DIR/hao" >/dev/null; then
  echo "hao without arguments should show CLI usage and exit successfully" >&2
  exit 1
fi
