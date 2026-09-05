#!/usr/bin/env bash
# shellcheck shell=bash

# hao-guard.sh —— 「拒绝破坏」检查（全部只读）
#
# 这个脚本存在的唯一理由：部署前判断目标是不是别人的东西。小白用户没有
# 能力审查 agent 下一步要动什么，所以覆盖前的判断不能靠即兴发挥。
# 每个子命令都只读取系统状态，不做任何修改，可以放心反复运行。
#
# 输出一律是「状态词 + 可选细节」，便于 agent 直接判断。
#
# 用法:
#   hao-guard.sh vhost-owner <server_name> [conf_dir]
#   hao-guard.sh managed-file <path>
#   hao-guard.sh cert-issuer <fullchain.pem>
#   hao-guard.sh repo-identity <dir> <expected_remote>
#   hao-guard.sh port-free <port>
#   hao-guard.sh unit-port <unit_file>
#   hao-guard.sh os-supported

set -euo pipefail

die() {
    echo "hao-guard: $*" >&2
    exit 1
}

# ==================== vhost-owner ====================
# 判断某个 server_name 是否已被 Nginx 配置占用，以及占用者是谁。
#   free                     没有配置占用这个 server_name
#   hao-site <id> <path>     被 HAO site 模块的某个站点占用
#   hao <service> <path>     被其他 HAO 管理的配置占用
#   foreign <path>           被非 HAO 管理的配置占用 —— 禁止覆盖
cmd_vhost_owner() {
    local server_name="${1:-}"
    local conf_dir="${2:-/etc/nginx/conf.d}"
    [ -n "$server_name" ] || die "vhost-owner 需要 <server_name>"

    if [ ! -d "$conf_dir" ]; then
        echo "free"
        return 0
    fi

    local conf site_id service
    while IFS= read -r -d '' conf; do
        # 逐 token 扫描 server_name 指令，避免子串误命中
        if awk -v domain="$server_name" '
            {
                for (i = 1; i <= NF; i++) {
                    token = $i
                    gsub(/[{};]/, "", token)

                    if (in_server_name && token == domain) found = 1
                    if (in_server_name && $i ~ /;/) in_server_name = 0
                    if (token == "server_name") in_server_name = 1
                }
            }
            END { exit found ? 0 : 1 }
        ' "$conf"; then
            site_id="$(sed -n 's/^# HAO-SITE: \(.*\)$/\1/p' "$conf" | head -1)"
            if [ -n "$site_id" ]; then
                echo "hao-site $site_id $conf"
                return 0
            fi
            if head -n 12 "$conf" 2>/dev/null | grep -q 'Managed by HAO'; then
                service="$(sed -n 's/^# Service: \(.*\)$/\1/p' "$conf" | head -1)"
                echo "hao ${service:-unknown} $conf"
                return 0
            fi
            echo "foreign $conf"
            return 0
        fi
    done < <(find "$conf_dir" -maxdepth 1 -type f -name '*.conf' -print0 2>/dev/null)

    echo "free"
}

# ==================== managed-file ====================
# 目标文件是否是 HAO 写的（看前 12 行的 "Managed by HAO" 头）
#   missing | managed <service> | foreign
cmd_managed_file() {
    local path="${1:-}"
    [ -n "$path" ] || die "managed-file 需要 <path>"
    if [ ! -e "$path" ]; then
        echo "missing"
        return 0
    fi
    if [ -f "$path" ] && head -n 12 "$path" 2>/dev/null | grep -q 'Managed by HAO'; then
        local service
        service="$(sed -n 's/^# Service: \(.*\)$/\1/p' "$path" | head -1)"
        echo "managed ${service:-unknown}"
        return 0
    fi
    echo "foreign"
}

# ==================== cert-issuer ====================
# 已有证书是真实 Let's Encrypt 证书，还是自签名兜底产物？
# 这决定能否启用 80->443 跳转（见 references/site.md 的 522 教训）。
#   missing | letsencrypt | selfsigned | other <issuer>
cmd_cert_issuer() {
    local pem="${1:-}"
    [ -n "$pem" ] || die "cert-issuer 需要 <fullchain.pem>"
    if [ ! -f "$pem" ]; then
        echo "missing"
        return 0
    fi
    local issuer subject
    issuer="$(openssl x509 -in "$pem" -noout -issuer 2>/dev/null || true)"
    if [ -z "$issuer" ]; then
        echo "other unreadable"
        return 0
    fi
    case "$issuer" in
        *"Let's Encrypt"*)
            echo "letsencrypt"
            return 0
            ;;
    esac
    subject="$(openssl x509 -in "$pem" -noout -subject 2>/dev/null || true)"
    # 自签名：颁发者与主体一致
    if [ "${issuer#issuer=}" = "${subject#subject=}" ]; then
        echo "selfsigned"
        return 0
    fi
    echo "other ${issuer#issuer=}"
}

# ==================== repo-identity ====================
# 目标目录能否安全地作为某个仓库的检出使用。
# 仓库地址可能内嵌凭据（https://user:token@...），输出一律脱敏。
#   absent | ok | not-git | remote-mismatch <sanitized_actual>
cmd_repo_identity() {
    local dir="${1:-}" expected="${2:-}"
    [ -n "$dir" ] && [ -n "$expected" ] || die "repo-identity 需要 <dir> <expected_remote>"

    if [ ! -e "$dir" ]; then
        echo "absent"
        return 0
    fi
    if [ ! -d "$dir/.git" ]; then
        echo "not-git"
        return 0
    fi
    local actual
    actual="$(git -C "$dir" remote get-url origin 2>/dev/null || true)"
    if [ "$actual" = "$expected" ]; then
        echo "ok"
        return 0
    fi
    echo "remote-mismatch $(printf '%s' "$actual" | sed -E 's#(://)[^/@]+@#\1***@#')"
}

# ==================== port-free ====================
#   free | busy
cmd_port_free() {
    local port="${1:-}"
    [ -n "$port" ] || die "port-free 需要 <port>"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] \
        || die "端口必须是 1-65535 的数字: $port"
    # 精确匹配「本地地址以 :port 结尾」，避免 :80 误命中 :8080
    if { ss -tlnH 2>/dev/null || netstat -tln 2>/dev/null; } \
        | awk -v p=":${port}" '{ for (i = 1; i <= NF; i++) if ($i ~ (p "$")) { f = 1; exit } } END { exit(f ? 0 : 1) }'; then
        echo "busy"
    else
        echo "free"
    fi
}

# ==================== unit-port ====================
# 从既有 systemd 单元里读回端口，保证重跑时不换端口（幂等）。
# 输出端口号，或在读不到时输出空行。
cmd_unit_port() {
    local unit="${1:-}"
    [ -n "$unit" ] || die "unit-port 需要 <unit_file>"
    [ -f "$unit" ] || { echo ""; return 0; }
    sed -n 's|^ExecStart=.*[[:space:]]\([0-9]\{1,5\}\)[[:space:]]*$|\1|p' "$unit" | head -1
}

# ==================== os-supported ====================
#   <id> <version_id> supported|unsupported
cmd_os_supported() {
    local os_release="${HAO_OS_RELEASE_FILE:-/etc/os-release}" id="unknown" version="unknown"
    if [ -f "$os_release" ]; then
        id="$(awk -F= '$1 == "ID" { gsub(/"/, "", $2); print $2; exit }' "$os_release")"
        version="$(awk -F= '$1 == "VERSION_ID" { gsub(/"/, "", $2); print $2; exit }' "$os_release")"
    fi
    case "${id}:${version}" in
        debian:12|debian:13|ubuntu:22.04|ubuntu:24.04|ubuntu:26.04)
            echo "${id} ${version} supported"
            ;;
        *)
            echo "${id} ${version} unsupported"
            ;;
    esac
}

# ==================== 分派 ====================
usage() {
    sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
    vhost-owner)   shift; cmd_vhost_owner "$@" ;;
    managed-file)  shift; cmd_managed_file "$@" ;;
    cert-issuer)   shift; cmd_cert_issuer "$@" ;;
    repo-identity) shift; cmd_repo_identity "$@" ;;
    port-free)     shift; cmd_port_free "$@" ;;
    unit-port)     shift; cmd_unit_port "$@" ;;
    os-supported)  shift; cmd_os_supported "$@" ;;
    -h|--help|"")  usage ;;
    *) die "未知子命令: $1" ;;
esac
