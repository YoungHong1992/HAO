#!/usr/bin/env bash
# shellcheck shell=bash

# Shared random secret generation helpers for HAO installers.
#
# All generators fail loudly (non-zero exit + stderr message) instead of
# silently returning an empty/short secret when openssl is missing or the
# entropy pipeline breaks. Callers run under `set -e`, so a failure aborts
# the install instead of writing an empty credential.

hao_random_alnum() {
    local length="$1" value="" chunk
    while [ "${#value}" -lt "$length" ]; do
        chunk="$(openssl rand -base64 64 2>/dev/null | tr -dc 'a-zA-Z0-9')" || chunk=""
        if [ -z "$chunk" ]; then
            echo "hao_random_alnum: secure random generation failed (is openssl installed?)" >&2
            return 1
        fi
        value="${value}${chunk}"
    done
    printf '%s' "${value:0:length}"
}

generate_password() {
    hao_random_alnum "${1:-32}"
}

generate_session_secret() {
    hao_random_alnum "${1:-48}"
}

generate_api_key() {
    local prefix="${1:-sk-}"
    local key_body
    key_body="$(hao_random_alnum 45)" || return 1
    echo "${prefix}${key_body}"
}
