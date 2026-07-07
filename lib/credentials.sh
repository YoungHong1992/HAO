#!/usr/bin/env bash
# shellcheck shell=bash

# Shared credential-file helpers for HAO installers.
# Functions intentionally avoid logging secret values; callers should only log the
# resulting file path.

write_credentials_file() {
    local target="$1"
    local dir tmp

    if [ -z "$target" ]; then
        echo "write_credentials_file: missing target path" >&2
        return 1
    fi

    dir="$(dirname "$target")"
    mkdir -p "$dir"

    tmp="$(mktemp "${target}.tmp.XXXXXX")"
    if ! cat > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi

    chmod 600 "$tmp"
    chown root:root "$tmp" 2>/dev/null || true
    mv "$tmp" "$target"
}

extract_yaml_list_values() {
    local file="$1"
    local key="$2"

    [ -f "$file" ] || return 0
    [ -n "$key" ] || return 0

    awk -v key="$key" '
        $0 ~ "^[[:space:]]*" key ":[[:space:]]*$" { in_list=1; next }
        in_list && /^[^[:space:]]/ { exit }
        in_list && /^[[:space:]]*-[[:space:]]*/ {
            line=$0
            sub(/^[[:space:]]*-[[:space:]]*/, "", line)
            gsub(/"/, "", line)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            if (line != "") print line
        }
    ' "$file"
}
