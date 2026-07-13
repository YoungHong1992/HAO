#!/usr/bin/env bash
# Managed by HAO
# Service: git-github
# shellcheck shell=bash

set -euo pipefail

if [ "$EUID" -eq 0 ]; then
    echo "WARNING: GitHub credentials and SSH keys will belong to root." >&2
    echo "Only continue when root is the intended long-term Git operator for this host." >&2
fi
if ! command -v gh >/dev/null 2>&1; then
    echo "GitHub CLI (gh) is not installed." >&2
    exit 1
fi

echo "GitHub will open a browser or show a device code."
echo "Use the intended GitHub account and review the requested permissions."
gh auth login --hostname github.com --web --git-protocol ssh
credential_file="${XDG_CONFIG_HOME:-$HOME/.config}/gh/hosts.yml"
if [ -f "$credential_file" ]; then
    chmod 600 "$credential_file"
fi
gh auth status --hostname github.com

echo "GitHub authorization completed. Verify repository access with git fetch/push as appropriate."
[ -f "$credential_file" ] && echo "Credential file: $credential_file (mode 600; content not displayed)"
