#!/usr/bin/env bash
# shellcheck shell=bash

# Machine-readable HAO ownership and drift state. No configuration values or
# credentials are written here; only resource paths, ownership classes, and hashes.

HAO_STATE_DIR="${HAO_STATE_DIR:-/var/lib/hao}"
readonly HAO_STATE_DIR

hao_json_escape() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    printf '%s' "$value"
}

hao_resource_hash() {
    local path="$1" ownership="$2"
    if [ "$ownership" = "secret" ]; then
        printf 'redacted'
    elif [ -f "$path" ]; then
        sha256sum "$path" | awk '{print $1}'
    elif [ -d "$path" ]; then
        printf 'directory'
    else
        printf 'missing'
    fi
}

hao_file_is_managed() {
    local path="$1"
    [ -f "$path" ] && head -n 12 "$path" 2>/dev/null | grep -q 'Managed by HAO'
}

hao_init_state() {
    mkdir -p "$HAO_STATE_DIR/services"
    chmod 755 "$HAO_STATE_DIR" "$HAO_STATE_DIR/services"
    cat > "$HAO_STATE_DIR/NOTICE" <<'EOF'
This directory records resources installed or observed by HAO (HongAgentOps).

Use `hao inventory` to inspect ownership and `hao doctor` to check drift.
Files marked `managed` should be changed through HAO. Files marked `shared` or
`observed` belong to the surrounding system and must not be overwritten merely
because they appear in this inventory. Secret values are never stored here.
EOF
    chmod 644 "$HAO_STATE_DIR/NOTICE"
}

hao_rebuild_manifest() {
    local target="$HAO_STATE_DIR/manifest.json" tmp first=true state_file
    tmp="$(mktemp "$HAO_STATE_DIR/.manifest.json.XXXXXX")"
    {
        printf '{\n'
        printf '  "schema_version": 1,\n'
        printf '  "managed_by": "HAO",\n'
        printf '  "generated_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '  "services": [\n'
        for state_file in "$HAO_STATE_DIR"/services/*.json; do
            [ -f "$state_file" ] || continue
            if [ "$first" = true ]; then
                first=false
            else
                printf ',\n'
            fi
            sed 's/^/    /' "$state_file"
        done
        printf '\n  ]\n}\n'
    } > "$tmp"
    chmod 644 "$tmp"
    mv "$tmp" "$target"
}

# Usage: hao_record_service SERVICE RESULT RELEASE OWNERSHIP:PATH [...]
# Ownership is managed, shared, observed, or secret.
hao_record_service() {
    local service="$1" result="$2" release="$3"
    shift 3
    local state_file resources_file state_tmp resources_tmp entry ownership path hash
    local first=true managed_count=0 overall_ownership="observed"

    if ! [[ "$service" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        echo "Invalid HAO service id for state: $service" >&2
        return 1
    fi

    hao_init_state
    state_file="$HAO_STATE_DIR/services/$service.json"
    resources_file="$HAO_STATE_DIR/services/$service.resources"
    state_tmp="$(mktemp "$HAO_STATE_DIR/services/.${service}.json.XXXXXX")"
    resources_tmp="$(mktemp "$HAO_STATE_DIR/services/.${service}.resources.XXXXXX")"

    for entry in "$@"; do
        ownership="${entry%%:*}"
        path="${entry#*:}"
        case "$ownership" in
            managed|shared|observed|secret) ;;
            *) echo "Invalid HAO resource ownership: $ownership" >&2; rm -f "$state_tmp" "$resources_tmp"; return 1 ;;
        esac
        [ -e "$path" ] || continue
        hash="$(hao_resource_hash "$path" "$ownership")"
        printf '%s\t%s\t%s\n' "$ownership" "$hash" "$path" >> "$resources_tmp"
        if [ "$ownership" = "managed" ]; then
            managed_count=$((managed_count + 1))
        fi
    done
    [ "$managed_count" -gt 0 ] && overall_ownership="managed"

    {
        printf '{\n'
        printf '  "schema_version": 1,\n'
        printf '  "managed_by": "HAO",\n'
        printf '  "service": "%s",\n' "$(hao_json_escape "$service")"
        printf '  "release": "%s",\n' "$(hao_json_escape "$release")"
        printf '  "recorded_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '  "result": "%s",\n' "$(hao_json_escape "$result")"
        printf '  "ownership": "%s",\n' "$overall_ownership"
        printf '  "resources": [\n'
        while IFS=$'\t' read -r ownership hash path; do
            [ -n "$path" ] || continue
            if [ "$first" = true ]; then first=false; else printf ',\n'; fi
            printf '    {"path": "%s", "ownership": "%s", "sha256": "%s"}' \
                "$(hao_json_escape "$path")" "$ownership" "$hash"
        done < "$resources_tmp"
        printf '\n  ]\n}\n'
    } > "$state_tmp"

    chmod 644 "$state_tmp" "$resources_tmp"
    mv "$state_tmp" "$state_file"
    mv "$resources_tmp" "$resources_file"
    hao_rebuild_manifest
}

hao_service_ownership() {
    local service="$1" state_file="$HAO_STATE_DIR/services/$1.json"
    if [ ! -r "$state_file" ]; then
        printf 'untracked'
        return
    fi
    sed -n 's/^[[:space:]]*"ownership": "\([^"]*\)",*$/\1/p' "$state_file" | head -1
}

hao_print_drift_report() {
    local resources_file service ownership expected path actual drift_count=0 service_drift
    echo "HAO ownership and drift"
    if [ ! -d "$HAO_STATE_DIR/services" ]; then
        echo "  No HAO state found at $HAO_STATE_DIR"
        return 0
    fi
    for resources_file in "$HAO_STATE_DIR"/services/*.resources; do
        [ -f "$resources_file" ] || continue
        service="$(basename "$resources_file" .resources)"
        service_drift=0
        while IFS=$'\t' read -r ownership expected path; do
            [ "$ownership" = "managed" ] || continue
            if [ ! -e "$path" ]; then
                echo "  [drift] $service: missing $path"
                service_drift=$((service_drift + 1))
                continue
            fi
            actual="$(hao_resource_hash "$path" "$ownership")"
            if [ "$actual" != "$expected" ]; then
                echo "  [drift] $service: modified $path"
                service_drift=$((service_drift + 1))
            fi
        done < "$resources_file"
        if [ "$service_drift" -eq 0 ]; then
            echo "  [ok] $service: managed resources match recorded state"
        fi
        drift_count=$((drift_count + service_drift))
    done
    echo "Drift summary: $drift_count managed resource(s) changed"
    [ "$drift_count" -eq 0 ]
}
