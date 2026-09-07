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
#   hao-guard.sh port-free [--tcp|--udp] <port>
#   hao-guard.sh unit-free <unit_name>
#   hao-guard.sh unit-port <unit_file>
#   hao-guard.sh os-supported

set -euo pipefail

die() {
    echo "hao-guard: $*" >&2
    exit 1
}

# ==================== 归属分类（共用） ====================
# 从文件的注释头判断归属，输出「状态词 + 路径」。nginx 配置和 systemd 单元
# 共用这一套判断 —— 两者都靠模板里的 `# Managed by HAO` / `# HAO-SITE:` 头。
# 靠文件内容而不是文件名，所以主机上的路径和文件名可以是完全通用的形式。
classify_hao_file() {
    local path="$1" site_id service
    site_id="$(sed -n 's/^# HAO-SITE: \(.*\)$/\1/p' "$path" 2>/dev/null | head -1)"
    if [ -n "$site_id" ]; then
        echo "hao-site $site_id $path"
        return 0
    fi
    if head -n 12 "$path" 2>/dev/null | grep -q 'Managed by HAO'; then
        service="$(sed -n 's/^# Service: \(.*\)$/\1/p' "$path" 2>/dev/null | head -1)"
        echo "hao ${service:-unknown} $path"
        return 0
    fi
    echo "foreign $path"
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

    local conf
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
            classify_hao_file "$conf"
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
# 默认查 TCP；--udp 查 UDP（HTTP/3 的 443/udp 用得到）。
#   free | busy | unknown
#
# `unknown` 是刻意区分出来的第三种结果：ss 和 netstat 都不在时，以前会输出
# `free` —— 一个"查不了"被当成"没人占用"，于是后面照样往这个端口写配置。
# 最小化的镜像里 iproute2 不一定在，这不是理论情况。
cmd_port_free() {
    local proto=-t
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --udp) proto=-u; shift ;;
            --tcp) proto=-t; shift ;;
            *) break ;;
        esac
    done
    local port="${1:-}"
    [ -n "$port" ] || die "port-free 需要 <port>"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] \
        || die "端口必须是 1-65535 的数字: $port"

    local listing="" got=false
    # UDP 没有 LISTEN 状态，-l 对 ss 仍然表示「只看服务端 socket」
    if command -v ss >/dev/null 2>&1; then
        listing="$(ss "${proto}lnH" 2>/dev/null)" && got=true
    fi
    if [ "$got" = false ] && command -v netstat >/dev/null 2>&1; then
        listing="$(netstat "${proto}ln" 2>/dev/null)" && got=true
    fi
    if [ "$got" = false ]; then
        echo "unknown"
        return 0
    fi

    # 精确匹配「本地地址以 :port 结尾」，避免 :80 误命中 :8080
    if printf '%s\n' "$listing" \
        | awk -v p=":${port}" '{ for (i = 1; i <= NF; i++) if ($i ~ (p "$")) { f = 1; exit } } END { exit(f ? 0 : 1) }'; then
        echo "busy"
    else
        echo "free"
    fi
}

# ==================== unit-free ====================
# 站点单元用通用命名 `<id>.service`（不带 hao- 前缀），于是多了一个风险：
# /etc/systemd/system/<name>.service 会**静默覆盖**
# /usr/lib/systemd/system/<name>.service。站点 ID 叫 nginx / cron / ssh
# 这类名字就会顶掉发行版的单元，而且不会有任何报错。写单元前必须先问这里。
#   free                     没有同名 unit，可以写
#   hao-site <id> <path>     本站点自己的单元，可原地更新
#   hao <service> <path>     别的 HAO 单元 -> 停
#   foreign <path>           发行版或别人的单元 -> 停，绝不覆盖
cmd_unit_free() {
    local name="${1:-}"
    [ -n "$name" ] || die "unit-free 需要 <unit_name>"
    case "$name" in
        */*) die "unit 名不能包含路径分隔符: $name" ;;
    esac
    case "$name" in
        *.service) ;;
        *) name="${name}.service" ;;
    esac

    # HAO_UNIT_DIRS 供测试覆盖；默认是 systemd 的标准搜索位置，/etc 在最前
    # —— 那既是 override 生效的地方，也是我们要写入的地方。
    local -a dirs=()
    IFS=':' read -ra dirs \
        <<< "${HAO_UNIT_DIRS:-/etc/systemd/system:/run/systemd/system:/usr/lib/systemd/system:/lib/systemd/system}"

    local d path=""
    for d in "${dirs[@]}"; do
        [ -n "$d" ] || continue
        if [ -f "$d/$name" ]; then
            path="$d/$name"
            break
        fi
    done

    # 目录里没找到，再问 systemd：它还知道 alias、generator 生成的单元、
    # 以及被 mask 的单元 —— 这些都不能当成「可用」。
    if [ -z "$path" ] && [ -z "${HAO_UNIT_DIRS:-}" ] && command -v systemctl >/dev/null 2>&1; then
        if [ -n "$(systemctl list-unit-files "$name" --no-legend 2>/dev/null | awk 'NR==1{print $1}')" ]; then
            path="$(systemctl show -p FragmentPath --value "$name" 2>/dev/null)"
            # systemd 说存在，却拿不到可读的单元文件（mask 到 /dev/null、
            # 或由 generator 动态生成）—— 保守起见按「别人的」处理。
            if [ -z "$path" ] || [ ! -f "$path" ]; then
                echo "foreign ${path:-$name}"
                return 0
            fi
        fi
    fi

    if [ -z "$path" ]; then
        echo "free"
        return 0
    fi
    classify_hao_file "$path"
}

# ==================== unit-port ====================
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
    sed -n '4,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
    vhost-owner)   shift; cmd_vhost_owner "$@" ;;
    managed-file)  shift; cmd_managed_file "$@" ;;
    cert-issuer)   shift; cmd_cert_issuer "$@" ;;
    repo-identity) shift; cmd_repo_identity "$@" ;;
    port-free)     shift; cmd_port_free "$@" ;;
    unit-free)     shift; cmd_unit_free "$@" ;;
    unit-port)     shift; cmd_unit_port "$@" ;;
    os-supported)  shift; cmd_os_supported "$@" ;;
    -h|--help|"")  usage ;;
    *) die "未知子命令: $1" ;;
esac
