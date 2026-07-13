#!/bin/bash
# shellcheck shell=bash
# shellcheck disable=SC2034
################################################################################
#
# HAO（HongAgentOps）— AI-native deterministic deployment executor
# 发布标识: YYMMDD-<git-short-hash>（正式发布）或 dev-<git-short-hash>（源码工作树）
#
# 功能说明：
#   通过 plan/preflight/apply/status/doctor 命令部署 AI 工具栈和模型服务
#
# 使用方法：
#   chmod +x install.sh
#   ./install.sh plan --services new-api --domain api.example.com
#   ./install.sh preflight --profile deploy.env
#   sudo ./install.sh apply --profile deploy.env --yes
#   ./install.sh -h                # 显示帮助
#   ./install.sh --version         # 显示版本
#
# 远程自举：
#   curl -fsSL https://.../install.sh | bash
#
# 可用组件：
#   1. Maintenance        - 服务器维护基线：fail2ban / swap / 日志限制
#   2. Nginx (HTTP/3)     - 高性能 Web 服务器 + 反向代理
#   3. Docker 容器环境    - Docker Engine + Compose 插件
#   4. CliproxyAPI        - 轻量 AI API 转发代理（默认 Docker Compose，可选裸机）
#   5. New-API            - AI 模型网关与资产管理系统
#   6. Pi 编程助手       - 终端 AI 编程助手
#
################################################################################

set -euo pipefail

# ==================== 发布标识与仓库信息 ====================
readonly HAO_REPO_SLUG="${HAO_REPO_SLUG:-YoungHong1992/hao}"

resolve_release_id() {
    local script_dir release_file exact_tag short_hash
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"
    release_file="$script_dir/RELEASE"

    if [[ "${HAO_RELEASE:-}" =~ ^[0-9]{6}-[0-9a-f]{7,12}$ ]]; then
        printf '%s' "$HAO_RELEASE"
        return
    fi
    if [ -r "$release_file" ]; then
        read -r exact_tag < "$release_file"
        if [[ "$exact_tag" =~ ^[0-9]{6}-[0-9a-f]{7,12}$ ]]; then
            printf '%s' "$exact_tag"
            return
        fi
    fi
    if [[ "${HAO_REF:-}" =~ ^[0-9]{6}-[0-9a-f]{7,12}$ ]]; then
        printf '%s' "$HAO_REF"
        return
    fi
    if command -v git >/dev/null 2>&1 && git -C "$script_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        exact_tag="$(git -C "$script_dir" tag --points-at HEAD 2>/dev/null | grep -E '^[0-9]{6}-[0-9a-f]{7,12}$' | head -1 || true)"
        if [ -n "$exact_tag" ]; then
            printf '%s' "$exact_tag"
            return
        fi
        short_hash="$(git -C "$script_dir" rev-parse --short=7 HEAD 2>/dev/null || true)"
        if [[ "$short_hash" =~ ^[0-9a-f]{7}$ ]]; then
            printf 'dev-%s' "$short_hash"
            return
        fi
    fi
    printf 'dev-unknown'
}

RELEASE_ID="$(resolve_release_id)"
readonly RELEASE_ID
readonly VERSION="$RELEASE_ID"
export HAO_RELEASE="$RELEASE_ID"
IMAGE_CANDIDATES_FILE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)/config/image-candidates.tsv"
readonly IMAGE_CANDIDATES_FILE

show_bootstrap_help() {
    cat <<EOF
HAO ${RELEASE_ID} — HongAgentOps
AI-native server deployment and model operations toolkit

用法:
  ./hao plan --services new-api --domain api.example.com
  ./hao preflight --profile deploy.env
  sudo ./hao apply --profile deploy.env --yes
  ./hao status
  ./hao doctor --profile deploy.env
  ./hao inventory
  ./hao -h
  ./hao --version

远程安装:
  curl -fsSL https://raw.githubusercontent.com/${HAO_REPO_SLUG}/main/install.sh | bash

说明:
  无参数运行只显示帮助，不进入终端菜单。请让 AI agent 先生成 plan/preflight，
  人工确认后再执行 apply --yes。
EOF
}

# --version/--help 不依赖完整仓库，允许单文件下载后直接查询。
for arg in "$@"; do
    case "$arg" in
        -h|--help) show_bootstrap_help; exit 0 ;;
        --version) echo "${RELEASE_ID}"; exit 0 ;;
    esac
done

# ==================== 路径解析 / 单文件自举 ====================
resolve_install_dir() {
    local source_path="${BASH_SOURCE[0]:-$0}"
    cd "$(dirname "$source_path")" 2>/dev/null && pwd || pwd
}

INSTALL_DIR="$(resolve_install_dir)"

bootstrap_full_repo() {
    local ref="${HAO_REF:-main}"
    local tmp_dir archive_url archive_file root_dir status

    echo "[INFO] 未检测到完整仓库，正在下载 HAO / HongAgentOps (${ref})..." >&2

    if ! command -v tar &>/dev/null; then
        echo "[ERROR] 缺少 tar，无法解压完整安装包。" >&2
        exit 1
    fi

    tmp_dir="$(mktemp -d)"
    archive_file="$tmp_dir/hao.tar.gz"

    if [[ "$ref" =~ ^[0-9]{6}-[0-9a-f]{7,12}$ ]]; then
        archive_url="https://github.com/${HAO_REPO_SLUG}/archive/refs/tags/${ref}.tar.gz"
    else
        archive_url="https://github.com/${HAO_REPO_SLUG}/archive/refs/heads/${ref}.tar.gz"
    fi

    if command -v curl &>/dev/null; then
        curl -fsSL "$archive_url" -o "$archive_file"
    elif command -v wget &>/dev/null; then
        wget -qO "$archive_file" "$archive_url"
    else
        echo "[ERROR] 缺少 curl/wget，无法下载完整安装包。" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi

    tar -xzf "$archive_file" -C "$tmp_dir"
    root_dir="$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | head -1)"

    if [ -z "$root_dir" ] \
        || [ ! -f "$root_dir/install.sh" ] \
        || [ ! -f "$root_dir/maintenance/install.sh" ] \
        || [ ! -f "$root_dir/nginx/install.sh" ] \
        || [ ! -f "$root_dir/docker/install.sh" ] \
        || [ ! -f "$root_dir/git-github/install.sh" ] \
        || [ ! -f "$root_dir/git-github/authorize.sh" ] \
        || [ ! -f "$root_dir/cliproxyapi/install.sh" ] \
        || [ ! -f "$root_dir/new-api/install.sh" ] \
        || [ ! -f "$root_dir/pi-coding-agent/install.sh" ] \
        || [ ! -f "$root_dir/claude-code/install.sh" ] \
        || [ ! -f "$root_dir/lib/common.sh" ] \
        || [ ! -f "$root_dir/lib/crypto.sh" ] \
        || [ ! -f "$root_dir/lib/credentials.sh" ] \
        || [ ! -f "$root_dir/lib/state.sh" ] \
        || [ ! -f "$root_dir/config/image-candidates.tsv" ]; then
        echo "[ERROR] 下载的安装包不完整。" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi

    chmod +x "$root_dir/install.sh"

    set +e
    if [ -r /dev/tty ]; then
        bash "$root_dir/install.sh" "$@" < /dev/tty
    else
        bash "$root_dir/install.sh" "$@"
    fi
    status=$?
    set -e

    rm -rf "$tmp_dir"
    exit "$status"
}

# ==================== 完整仓库检测 ====================
if [ ! -f "$INSTALL_DIR/maintenance/install.sh" ] \
    || [ ! -f "$INSTALL_DIR/nginx/install.sh" ] \
    || [ ! -f "$INSTALL_DIR/docker/install.sh" ] \
    || [ ! -f "$INSTALL_DIR/git-github/install.sh" ] \
    || [ ! -f "$INSTALL_DIR/git-github/authorize.sh" ] \
    || [ ! -f "$INSTALL_DIR/cliproxyapi/install.sh" ] \
    || [ ! -f "$INSTALL_DIR/new-api/install.sh" ] \
    || [ ! -f "$INSTALL_DIR/pi-coding-agent/install.sh" ] \
    || [ ! -f "$INSTALL_DIR/claude-code/install.sh" ] \
    || [ ! -f "$INSTALL_DIR/lib/common.sh" ] \
    || [ ! -f "$INSTALL_DIR/lib/crypto.sh" ] \
    || [ ! -f "$INSTALL_DIR/lib/credentials.sh" ] \
    || [ ! -f "$INSTALL_DIR/lib/state.sh" ] \
    || [ ! -f "$INSTALL_DIR/config/image-candidates.tsv" ]; then
    bootstrap_full_repo "$@"
fi

# shellcheck source=lib/state.sh
source "$INSTALL_DIR/lib/state.sh"

# ==================== 自包含公共函数 ====================
# 本脚本可独立运行，不依赖外部公共库。
# shellcheck disable=SC2034
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
readonly COMMON_VERSION="$RELEASE_ID"
readonly DEPLOY_LOG_DIR="/var/log/vps-deploy"

print_header() {
    local title="${1:-部署工具}"
    clear 2>/dev/null || true
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                                                              ║"
    printf  "║           %-51s║\n" "$title"
    echo "║                                                              ║"
    printf  "║           发布标识: %-40s║\n" "${COMMON_VERSION}"
    echo "║                                                              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_divider() {
    echo -e "${DIM}────────────────────────────────────────────────────────────────${NC}"
}

print_section() {
    echo ""
    echo -e "${BOLD}${BLUE}▶ $1${NC}"
    print_divider
}

setup_logging() {
    local script_name="${1:-deploy}"
    mkdir -p "$DEPLOY_LOG_DIR"
    DEPLOY_LOG_FILE="${DEPLOY_LOG_DIR}/${script_name}-$(date +%Y%m%d-%H%M%S).log"
    exec > >(tee -a "$DEPLOY_LOG_FILE") 2>&1
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] === 日志开始: $DEPLOY_LOG_FILE ==="
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 脚本: $script_name"
}

log_info()    { echo -e "${BLUE}[INFO]${NC} $(date '+%H:%M:%S') $*" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $(date '+%H:%M:%S') $*" >&2; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $(date '+%H:%M:%S') $*" >&2; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*" >&2; }
log_step()    { echo -e "${CYAN}[STEP]${NC} $(date '+%H:%M:%S') $*" >&2; }
log_debug()   { echo -e "${DIM}[DEBUG]${NC} $(date '+%H:%M:%S') $*" >&2; }

generate_password() {
    local length="${1:-32}"
    openssl rand -base64 48 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c "$length"
}

generate_session_secret() {
    local length="${1:-48}"
    openssl rand -base64 64 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c "$length"
}

generate_api_key() {
    local prefix="${1:-sk-}"
    local key_body
    key_body=$(openssl rand -base64 48 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 45)
    echo "${prefix}${key_body}"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[ERROR] 必须使用 root 权限运行此脚本。${NC}"
        echo -e "${YELLOW}请使用: sudo $0${NC}"
        exit 1
    fi
}

detect_os() {
    local os_release_file="${HAO_OS_RELEASE_FILE:-/etc/os-release}"
    if [ -f "$os_release_file" ]; then
        awk -F= '$1 == "ID" { gsub(/"/, "", $2); print $2; exit }' "$os_release_file"
    elif [ -f /etc/redhat-release ]; then
        echo "rhel"
    else
        echo "unknown"
    fi
}

detect_os_version() {
    local os_release_file="${HAO_OS_RELEASE_FILE:-/etc/os-release}"
    if [ -f "$os_release_file" ]; then
        awk -F= '$1 == "VERSION_CODENAME" { gsub(/"/, "", $2); print $2; exit }' "$os_release_file"
    else
        echo "unknown"
    fi
}

detect_os_version_id() {
    local os_release_file="${HAO_OS_RELEASE_FILE:-/etc/os-release}"
    if [ -f "$os_release_file" ]; then
        awk -F= '$1 == "VERSION_ID" { gsub(/"/, "", $2); print $2; exit }' "$os_release_file"
    else
        echo "unknown"
    fi
}

is_supported_os_release() {
    local os="$1" version="$2"
    case "$os:$version" in
        debian:12|debian:13|ubuntu:22.04|ubuntu:24.04|ubuntu:26.04) return 0 ;;
        *) return 1 ;;
    esac
}

supported_os_summary() {
    echo "Debian 13/12; Ubuntu 26.04/24.04/22.04 LTS"
}

detect_server_ip() {
    local ip
    ip=$(curl -s --connect-timeout 5 https://api.ipify.org 2>/dev/null || \
         curl -s --connect-timeout 5 https://ifconfig.me 2>/dev/null || \
         curl -s --connect-timeout 5 https://icanhazip.com 2>/dev/null || \
         hostname -I 2>/dev/null | awk '{print $1}')
    echo "$ip"
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "linux_amd64" ;;
        arm64|aarch64)  echo "linux_arm64" ;;
        *)              echo "unknown" ;;
    esac
}

check_port_available() {
    local port="$1"
    if ss -tlnp 2>/dev/null | grep -q ":${port} " || \
       netstat -tlnp 2>/dev/null | grep -q ":${port} "; then
        return 1
    fi
    return 0
}

ensure_port_available() {
    local port="$1"
    local service_name="${2:-服务}"
    if ! check_port_available "$port"; then
        log_error "端口 $port 已被占用，$service_name 无法使用此端口。"
        log_info "请先释放端口或修改脚本中的端口配置。"
        exit 1
    fi
    log_debug "端口 $port 可用"
}

check_command_available() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        log_error "缺少必要工具: $cmd，请安装后重试。"
        return 1
    fi
    return 0
}

ensure_commands() {
    local missing=""
    for cmd in "$@"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing="$missing $cmd"
        fi
    done
    if [ -n "$missing" ]; then
        log_error "缺少必要工具:${missing}"
        log_info "请运行: apt-get install -y${missing}"
        exit 1
    fi
}

detect_nginx_http3() {
    if command -v nginx &>/dev/null && nginx -V 2>&1 | grep -q "http_v3_module"; then
        return 0
    fi
    return 1
}

get_main_domain_email() {
    local domain="$1"
    local main_domain
    main_domain=$(echo "$domain" | awk -F. '{print $(NF-1)"."$NF}')
    echo "admin@${main_domain}"
}

is_valid_ssl_email() {
    local email="$1"
    [ -z "$email" ] && return 1
    echo "$email" | grep -qE "@(example\.com|localhost|test\.com)" && return 1
    return 0
}

ensure_acme_sh_config() {
    local domain="$1"
    local expected_email
    expected_email=$(get_main_domain_email "$domain")

    if [ ! -f ~/.acme.sh/acme.sh ]; then
        log_info "安装 acme.sh..."
        curl -s --connect-timeout 10 https://get.acme.sh | sh -s email="$expected_email" >/dev/null 2>&1 || true
        return 0
    fi

    if [ -f ~/.acme.sh/account.conf ]; then
        local current_email
        current_email=$(grep "^ACCOUNT_EMAIL=" ~/.acme.sh/account.conf 2>/dev/null | cut -d"'" -f2 || true)

        if ! is_valid_ssl_email "$current_email"; then
            log_info "修正 acme.sh 邮箱配置..."
            sed -i "s/^ACCOUNT_EMAIL=.*/ACCOUNT_EMAIL='$expected_email'/g" ~/.acme.sh/account.conf
            rm -rf ~/.acme.sh/ca/*/account.json 2>/dev/null || true
        fi
    fi
}

apply_ssl_certificate() {
    local domain="$1"
    local ssl_dir="$2"
    local mode="$3"

    mkdir -p "$ssl_dir"

    case "$mode" in
        http)
            log_info "HTTP 模式，跳过 SSL 证书配置。"
            echo "无 (HTTP 模式)"
            return 0
            ;;
        domain)
            log_info "申请 Let's Encrypt ECC-256 证书..."

            ensure_acme_sh_config "$domain"
            local safe_domain temp_conf default_site default_backup default_moved=false
            safe_domain=$(printf '%s' "$domain" | tr -c 'A-Za-z0-9_.-' '_')
            temp_conf="/etc/nginx/conf.d/00-acme-${safe_domain}.conf"
            default_site="/etc/nginx/sites-enabled/default"
            default_backup="/etc/nginx/sites-enabled/default.disabled-by-ssl"

            cat > "$temp_conf" <<NGINX_TEMP
server {
    listen 80;
    server_name $domain;
    location /.well-known/acme-challenge/ {
        root /var/www/acme;
    }
}
NGINX_TEMP

            mkdir -p /var/www/acme
            chmod 755 /var/www/acme
            if [ -f "$default_site" ]; then
                mv "$default_site" "$default_backup" 2>/dev/null && default_moved=true || true
            fi
            systemctl reload nginx >/dev/null 2>&1 || true

            if ~/.acme.sh/acme.sh --issue --server letsencrypt -d "$domain" --webroot /var/www/acme --keylength ec-256 >&2; then
                ~/.acme.sh/acme.sh --install-cert -d "$domain" --ecc \
                    --key-file       "$ssl_dir/key.pem" \
                    --fullchain-file "$ssl_dir/fullchain.pem" \
                    --reloadcmd     "systemctl reload nginx" >/dev/null 2>&1 || true

                if [ -f "$ssl_dir/fullchain.pem" ]; then
                    log_success "SSL 证书申请成功 (Let's Encrypt ECC-256)"
                    rm -f "$temp_conf"
                    if [ "$default_moved" = true ] && [ -f "$default_backup" ]; then
                        mv "$default_backup" "$default_site" 2>/dev/null || true
                    fi
                    systemctl reload nginx >/dev/null 2>&1 || true
                    echo "Let's Encrypt (ECC-256)"
                    return 0
                fi
            fi

            log_warning "Let's Encrypt 申请失败，降级为自签名证书..."
            rm -f "$temp_conf"
            if [ "$default_moved" = true ] && [ -f "$default_backup" ]; then
                mv "$default_backup" "$default_site" 2>/dev/null || true
            fi
            systemctl reload nginx >/dev/null 2>&1 || true
            ;;
        ip)
            log_info "生成自签名证书 (IP 模式)..."
            ;;
    esac

    local san
    if validate_ip "$domain" 2>/dev/null; then
        san="IP:$domain"
    else
        san="DNS:$domain"
    fi

    if openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$ssl_dir/key.pem" \
        -out "$ssl_dir/fullchain.pem" \
        -subj "/CN=$domain" \
        -addext "subjectAltName=$san" >/dev/null 2>&1; then
        log_success "自签名证书生成成功"
        echo "自签名证书"
    else
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "$ssl_dir/key.pem" \
            -out "$ssl_dir/fullchain.pem" \
            -subj "/CN=$domain" >/dev/null 2>&1
        log_success "自签名证书生成成功 (兼容模式)"
        echo "自签名证书"
    fi
}

readonly NGINX_SSL_CONFIG='
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers EECDH+CHACHA20:EECDH+CHACHA20-draft:EECDH+AES128:RSA+AES128:EECDH+AES256:RSA+AES256:EECDH+3DES:RSA+3DES:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_tickets on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    add_header Strict-Transport-Security "max-age=31536000" always;'

readonly NGINX_REDIRECT_LOGIC='
    set $isRedcert 1;
    if ($server_port != 443) {
        set $isRedcert 2;
    }
    if ( $uri ~ /\.well-known/ ) {
        set $isRedcert 1;
    }
    if ($isRedcert != 1) {
        rewrite ^(.*)$ https://$host$1 permanent;
    }'

backup_file() {
    local file="$1"
    if [ -f "$file" ]; then
        local backup
        backup="${file}.bak.$(date +%Y%m%d_%H%M%S)"
        cp -a "$file" "$backup"
        log_info "已备份: $backup"
    fi
}

find_nginx_conf_by_server_name() {
    local domain="$1"
    local conf_dir="${2:-/etc/nginx/conf.d}"
    local conf

    [ -d "$conf_dir" ] || return 1

    while IFS= read -r -d '' conf; do
        if awk -v domain="$domain" '
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
            echo "$conf"
            return 0
        fi
    done < <(find "$conf_dir" -maxdepth 1 -type f -name "*.conf" -print0 2>/dev/null)

    return 1
}

detect_compose_cmd() {
    if docker compose version &>/dev/null 2>&1; then
        echo "docker compose"
    elif command -v docker-compose &>/dev/null; then
        echo "docker-compose"
    else
        echo ""
    fi
}

wait_for_healthy() {
    local compose_cmd="$1"
    local service_dir="$2"
    local max_wait="${3:-60}"
    local interval="${4:-5}"
    shift 4
    local required_services=("$@")

    cd "$service_dir" || { log_error "无法进入目录: $service_dir"; return 1; }

    local waited=0
    while [ "$waited" -lt "$max_wait" ]; do
        local all_healthy=true

        if [ "${#required_services[@]}" -eq 0 ]; then
            if $compose_cmd ps 2>/dev/null | grep -q "(healthy)"; then
                log_success "服务已健康运行 (${waited}s)"
                return 0
            fi
            all_healthy=false
        else
            for svc in "${required_services[@]}"; do
                if ! $compose_cmd ps 2>/dev/null | grep -q "${svc}.*(healthy)"; then
                    all_healthy=false
                    break
                fi
            done
        fi

        if [ "$all_healthy" = true ]; then
            log_success "所有指定服务已健康运行 (${waited}s)"
            return 0
        fi

        if ! $compose_cmd ps 2>/dev/null | grep -q "Up"; then
            log_warning "检测到容器未运行，继续等待..."
        fi

        sleep "$interval"
        waited=$((waited + interval))
    done

    log_warning "等待超时 (${max_wait}s)，请手动检查服务状态"
    $compose_cmd ps 2>/dev/null || true
    return 1
}

is_noninteractive() {
    [ "${HAO_UNATTENDED:-}" = "1" ]
}

validate_domain() {
    local domain="$1"
    if [ -z "$domain" ]; then
        log_error "域名不能为空。"
        return 1
    fi
    if ! [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        log_error "域名格式不正确: $domain"
        return 1
    fi
    return 0
}

validate_ip() {
    local ip="$1"
    local IFS=. octet

    if [ -z "$ip" ]; then
        log_error "IP 不能为空。"
        return 1
    fi

    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        for octet in $ip; do
            if [ "$octet" -gt 255 ]; then
                log_error "IPv4 地址格式不正确: $ip"
                return 1
            fi
        done
        return 0
    fi

    if [[ "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:]+$ ]]; then
        return 0
    fi

    log_error "IP 地址格式不正确: $ip"
    return 1
}

validate_port() {
    local port="$1"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        log_error "端口必须是 1-65535 的数字: $port"
        return 1
    fi
    return 0
}

validate_container_image() {
    local image="$1"
    if [[ ! "$image" =~ ^[A-Za-z0-9][A-Za-z0-9._/:@-]*$ ]] \
        || [[ "$image" == *..* ]] \
        || [[ "$image" == */ ]] \
        || [[ "$image" == *: ]]; then
        log_error "Docker 镜像引用格式不安全或无效: $image"
        return 1
    fi
    return 0
}

validate_sni() {
    local sni="$1"
    validate_domain "$sni"
}

escape_double_quoted() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\t'/\\t}
    printf '%s' "$value"
}

# ==================== 帮助信息 ====================
show_help() {
    cat <<EOF
HAO ${RELEASE_ID} — HongAgentOps
AI-native server deployment and model operations toolkit

用法:
  ./hao plan --services new-api --domain api.example.com
  ./hao preflight --profile deploy.env
  sudo ./hao apply --profile deploy.env --yes
  ./hao status
  ./hao doctor --profile deploy.env
  ./hao inventory
  ./hao -h
  ./hao --version

AI 协作流程:
  1. 在对话中确认服务、域名、数据库和风险项
  2. 生成 .env profile 或明确 CLI 参数
  3. plan 输出部署计划
  4. preflight 检查环境
  5. 用户确认后 apply --yes 非交互执行
  6. status/doctor 检查状态和排障

可用组件:
  Maintenance              服务器维护基线：fail2ban / swap / 日志限制 / Docker 日志轮转
  Nginx (HTTP/3)           高性能 Web 服务器 + 反向代理
  Docker 容器环境          Docker Engine + Compose 插件
  CliproxyAPI              轻量 AI API 转发代理 (默认 Docker Compose，可选裸机)
  New-API                  AI 模型网关与资产管理系统 (需 ≥1GB 内存)
  Pi 编程助手              终端 AI 编程助手 (500MB 磁盘)

注意:
  - 需要 root 权限
  - 域名模式需要 DNS 已解析
  - apply 必须显式 --yes 或 HAO_CONFIRM_APPLY=yes
  - 安装日志保存在 /var/log/vps-deploy/
EOF
    exit 0
}

# ==================== 参数解析 ====================
case "${1:-}" in
    plan|preflight|apply|status|doctor|inventory|help) ;;
    *)
        for arg in "$@"; do
            case "$arg" in
                -h|--help)    show_help ;;
                --version)    echo "${RELEASE_ID}"; exit 0 ;;
                -*)           echo "未知参数: $arg"; echo "使用 -h 查看帮助"; exit 1 ;;
            esac
        done
        ;;
esac

# ==================== 全局状态 ====================

# Service IDs
readonly SVC_MAINTENANCE="maintenance"
readonly SVC_NGINX="nginx"
readonly SVC_DOCKER="docker"
readonly SVC_GITGITHUB="git-github"
readonly SVC_CLIPROXY="cliproxyapi"
readonly SVC_NEWAPI="newapi"
readonly SVC_PI="pi"
readonly SVC_CLAUDECODE="claude-code"

# Service definitions (order = dependency order)
declare -A SVC_NAME SVC_DESC SVC_HINT SVC_SCRIPT SVC_DEPENDS
SVC_NAME[$SVC_MAINTENANCE]="Maintenance"
SVC_DESC[$SVC_MAINTENANCE]="基础维护：fail2ban、swap、日志限制、Docker 日志轮转"
SVC_HINT[$SVC_MAINTENANCE]="基础维护"
SVC_SCRIPT[$SVC_MAINTENANCE]="$INSTALL_DIR/maintenance/install.sh"
SVC_DEPENDS[$SVC_MAINTENANCE]=""

SVC_NAME[$SVC_NGINX]="Nginx (HTTP/3)"
SVC_DESC[$SVC_NGINX]="Nginx 官方主线仓库安装，支持 HTTP/3 (QUIC)、TCP BBR 优化"
SVC_HINT[$SVC_NGINX]="512MB 内存"
SVC_SCRIPT[$SVC_NGINX]="$INSTALL_DIR/nginx/install.sh"
SVC_DEPENDS[$SVC_NGINX]=""

SVC_NAME[$SVC_DOCKER]="Docker 容器环境"
SVC_DESC[$SVC_DOCKER]="Docker Engine + Docker Compose 插件"
SVC_HINT[$SVC_DOCKER]="无额外需求"
SVC_SCRIPT[$SVC_DOCKER]="$INSTALL_DIR/docker/install.sh"
SVC_DEPENDS[$SVC_DOCKER]=""

SVC_NAME[$SVC_GITGITHUB]="Git + GitHub"
SVC_DESC[$SVC_GITGITHUB]="Git 提交身份、GitHub CLI 与 SSH 授权准备（必须显式选择）"
SVC_HINT[$SVC_GITGITHUB]="个人开发机 / 管理型 VPS"
SVC_SCRIPT[$SVC_GITGITHUB]="$INSTALL_DIR/git-github/install.sh"
SVC_DEPENDS[$SVC_GITGITHUB]=""

SVC_NAME[$SVC_CLIPROXY]="CliproxyAPI"
SVC_DESC[$SVC_CLIPROXY]="轻量 AI API 转发代理，默认 Docker Compose，支持裸机 Systemd"
SVC_HINT[$SVC_CLIPROXY]="256MB 内存"
SVC_SCRIPT[$SVC_CLIPROXY]="$INSTALL_DIR/cliproxyapi/install.sh"
SVC_DEPENDS[$SVC_CLIPROXY]="$SVC_NGINX $SVC_DOCKER"

SVC_NAME[$SVC_NEWAPI]="New-API"
SVC_DESC[$SVC_NEWAPI]="AI 模型网关与资产管理系统，支持多模型聚合、计费、用户管理"
SVC_HINT[$SVC_NEWAPI]="≥ 1GB 内存"
SVC_SCRIPT[$SVC_NEWAPI]="$INSTALL_DIR/new-api/install.sh"
SVC_DEPENDS[$SVC_NEWAPI]="$SVC_NGINX $SVC_DOCKER"

SVC_NAME[$SVC_PI]="Pi 编程助手"
SVC_DESC[$SVC_PI]="极简终端 AI 编程助手，支持 Anthropic/OpenAI/Gemini/DeepSeek"
SVC_HINT[$SVC_PI]="500MB 磁盘"
SVC_SCRIPT[$SVC_PI]="$INSTALL_DIR/pi-coding-agent/install.sh"
SVC_DEPENDS[$SVC_PI]=""

SVC_NAME[$SVC_CLAUDECODE]="Claude Code"
SVC_DESC[$SVC_CLAUDECODE]="Anthropic 官方终端 AI 编程助手，可选配置自定义网关/模型"
SVC_HINT[$SVC_CLAUDECODE]="500MB 磁盘"
SVC_SCRIPT[$SVC_CLAUDECODE]="$INSTALL_DIR/claude-code/install.sh"
SVC_DEPENDS[$SVC_CLAUDECODE]=""

# Ordered list for display
readonly ALL_SERVICES=(
    "$SVC_MAINTENANCE" "$SVC_NGINX" "$SVC_DOCKER"
    "$SVC_CLIPROXY" "$SVC_NEWAPI" "$SVC_GITGITHUB" "$SVC_PI" "$SVC_CLAUDECODE"
)
# Personal identity tooling is opt-in and intentionally excluded from `--services all`.
readonly DEFAULT_ALL_SERVICES=(
    "$SVC_MAINTENANCE" "$SVC_NGINX" "$SVC_DOCKER"
    "$SVC_CLIPROXY" "$SVC_NEWAPI" "$SVC_PI" "$SVC_CLAUDECODE"
)

# Runtime state
declare -A ALREADY_INSTALLED   # true if already present on system
declare -A TO_INSTALL          # true if user selected to install
declare -A FORCE_INSTALL       # true if installed service is explicitly selected for reinstall
declare -A SERVICE_DOMAIN      # per Web service domain/IP
declare -A INSTALL_FAILED      # true if service failed/skipped due dependency
INSTALL_ORDER=()               # resolved dependency order
INSTALL_RESULTS=()             # for summary
FAILED=0                       # non-zero when any service failed

# User config
ACCESS_MODE=""
DOMAIN=""                     # single Web service IP/domain fallback
ADMIN_PASSWORD=""              # cliproxyapi
CLIPROXY_DEPLOY_MODE="docker"  # docker | bare
DB_TYPE="postgresql"           # newapi
CLIPROXY_IMAGE=""
NEWAPI_IMAGE=""
GIT_NAME=""
GIT_EMAIL=""
GIT_MACHINE_ROLE=""
GIT_SCOPE=""
GIT_REPO_DIR=""
GIT_TARGET_USER=""
GH_AUTH_MODE=""

# ==================== 单轮状态重置 ====================

reset_iteration_state() {
    TO_INSTALL=()
    FORCE_INSTALL=()
    SERVICE_DOMAIN=()
    INSTALL_FAILED=()
    INSTALL_ORDER=()
    INSTALL_RESULTS=()
    FAILED=0

    ACCESS_MODE=""
    DOMAIN=""
    ADMIN_PASSWORD=""
    CLIPROXY_DEPLOY_MODE="docker"
    DB_TYPE="postgresql"
    CLIPROXY_IMAGE=""
    NEWAPI_IMAGE=""
    GIT_NAME=""
    GIT_EMAIL=""
    GIT_MACHINE_ROLE=""
    GIT_SCOPE=""
    GIT_REPO_DIR=""
    GIT_TARGET_USER=""
    GH_AUTH_MODE=""

    # CliproxyAPI 默认 Docker Compose；裸机选择只在当前轮生效。
    SVC_DEPENDS[$SVC_CLIPROXY]="$SVC_NGINX $SVC_DOCKER"
}

# ==================== 服务检测 ====================

detect_installed_services() {
    ALREADY_INSTALLED=()
    if [ -z "${CLI_COMMAND:-}" ]; then
        echo ""
        echo -e "${CYAN}正在检测已安装的服务...${NC}"
    fi

    for svc in "${ALL_SERVICES[@]}"; do
        case "$svc" in
            "$SVC_MAINTENANCE")
                if [ -f /var/lib/hao/maintenance.installed ]; then
                    ALREADY_INSTALLED[$svc]=true
                fi
                ;;
            "$SVC_NGINX")
                if command -v nginx &>/dev/null \
                    && nginx -t >/dev/null 2>&1 \
                    && systemctl is-active --quiet nginx 2>/dev/null; then
                    ALREADY_INSTALLED[$svc]=true
                fi
                ;;
            "$SVC_DOCKER")
                if command -v docker &>/dev/null \
                    && systemctl is-active --quiet docker 2>/dev/null \
                    && (docker compose version &>/dev/null || command -v docker-compose &>/dev/null); then
                    ALREADY_INSTALLED[$svc]=true
                fi
                ;;
            "$SVC_GITGITHUB")
                if command -v git &>/dev/null && command -v gh &>/dev/null; then
                    ALREADY_INSTALLED[$svc]=true
                fi
                ;;
            "$SVC_CLIPROXY")
                if [ -f /opt/docker-services/cliproxyapi/docker-compose.yml ] \
                    || [ -f /opt/cliproxyapi/version.txt ] \
                    || [ -f /etc/systemd/system/cliproxyapi.service ]; then
                    ALREADY_INSTALLED[$svc]=true
                fi
                ;;
            "$SVC_NEWAPI")
                if [ -f /opt/docker-services/new-api/docker-compose.yml ]; then
                    ALREADY_INSTALLED[$svc]=true
                fi
                ;;
            "$SVC_PI")
                if command -v pi &>/dev/null; then
                    ALREADY_INSTALLED[$svc]=true
                fi
                ;;
            "$SVC_CLAUDECODE")
                if command -v claude &>/dev/null; then
                    ALREADY_INSTALLED[$svc]=true
                fi
                ;;
        esac
    done
}

# ==================== 服务显示工具 ====================

service_short_name() {
    case "$1" in
        "$SVC_MAINTENANCE") echo "Maintenance" ;;
        "$SVC_NGINX")    echo "Nginx" ;;
        "$SVC_DOCKER")   echo "Docker" ;;
        "$SVC_GITGITHUB") echo "Git + GitHub" ;;
        "$SVC_CLIPROXY") echo "CliproxyAPI" ;;
        "$SVC_NEWAPI")   echo "New-API" ;;
        "$SVC_PI")       echo "Pi" ;;
        "$SVC_CLAUDECODE") echo "Claude Code" ;;
        *)                echo "$1" ;;
    esac
}

compose_running_text() {
    local service_dir="$1"
    local compose_cmd
    compose_cmd=$(detect_compose_cmd)

    if [ ! -f "$service_dir/docker-compose.yml" ]; then
        echo "未部署"
        return 0
    fi
    if [ -z "$compose_cmd" ]; then
        echo "已部署，未检测到 Compose 命令"
        return 0
    fi
    if (cd "$service_dir" && $compose_cmd ps 2>/dev/null | grep -q "Up"); then
        echo "运行中"
    else
        echo "已部署，未运行或状态未知"
    fi
}

gh_authenticated_for_user() {
    local user="$1" home
    command -v gh >/dev/null 2>&1 || return 1
    home="$(getent passwd "$user" | awk -F: '{print $6}')"
    [ -n "$home" ] || return 1
    if [ "$user" = "$(id -un)" ]; then
        HOME="$home" gh auth status --hostname github.com >/dev/null 2>&1
    elif [ "$EUID" -eq 0 ] && command -v runuser >/dev/null 2>&1; then
        runuser -u "$user" -- env HOME="$home" gh auth status --hostname github.com >/dev/null 2>&1
    else
        return 1
    fi
}

# ==================== 部署方式选择 ====================

configure_deployment_modes() {
    local requested_mode

    if [ "${TO_INSTALL[$SVC_CLIPROXY]:-}" != "true" ]; then
        CLIPROXY_DEPLOY_MODE="docker"
        SVC_DEPENDS[$SVC_CLIPROXY]="$SVC_NGINX $SVC_DOCKER"
        return
    fi

    requested_mode="${HAO_CLIPROXY_MODE:-$CLIPROXY_DEPLOY_MODE}"
    case "${requested_mode,,}" in
        docker|compose|docker-compose)
            CLIPROXY_DEPLOY_MODE="docker"
            ;;
        bare|binary|systemd|native|host)
            CLIPROXY_DEPLOY_MODE="bare"
            ;;
        *)
            log_error "未知 CliproxyAPI 部署方式: $requested_mode"
            log_info "可用值: docker / bare"
            exit 1
            ;;
    esac

    if [ "$CLIPROXY_DEPLOY_MODE" = "docker" ]; then
        SVC_DEPENDS[$SVC_CLIPROXY]="$SVC_NGINX $SVC_DOCKER"
    else
        SVC_DEPENDS[$SVC_CLIPROXY]="$SVC_NGINX"
    fi
}

# ==================== 依赖解析 ====================

resolve_deps() {
    INSTALL_ORDER=()
    local -A seen

    resolve_one() {
        local svc="$1"
        local include_self="${2:-false}"
        local dep

        if [ "${seen[$svc]:-}" = "1" ]; then
            return
        fi
        seen[$svc]=1

        # 依赖服务仅在未安装时自动补齐；已安装依赖不重复执行。
        for dep in ${SVC_DEPENDS[$svc]}; do
            if [ -n "$dep" ] && [ "${ALREADY_INSTALLED[$dep]:-}" != "true" ]; then
                resolve_one "$dep" true
            fi
        done

        if [ "$include_self" = true ] || [ "${ALREADY_INSTALLED[$svc]:-}" != "true" ]; then
            INSTALL_ORDER+=("$svc")
        fi
    }

    for svc in "${ALL_SERVICES[@]}"; do
        if [ "${TO_INSTALL[$svc]:-}" = "true" ]; then
            resolve_one "$svc" true
        fi
    done
}

# ==================== 是否需要访问模式配置 ====================

is_web_service() {
    case "$1" in
        "$SVC_CLIPROXY"|"$SVC_NEWAPI") return 0 ;;
        *) return 1 ;;
    esac
}

needs_access_mode() {
    local svc
    for svc in "${INSTALL_ORDER[@]}"; do
        if is_web_service "$svc" \
            && { [ "${ALREADY_INSTALLED[$svc]:-}" != "true" ] || [ "${FORCE_INSTALL[$svc]:-}" = "true" ]; }; then
            return 0
        fi
    done
    return 1
}

# ==================== 安装执行 ====================

record_service_management_state() {
    local svc="$1" path domain_value binary target_home public_key
    local -a candidates=() resources=()

    case "$svc" in
        "$SVC_MAINTENANCE")
            candidates+=(
                "auto:/var/lib/hao/maintenance.installed"
                "auto:/etc/fail2ban/jail.d/hao-sshd.local"
                "auto:/etc/sysctl.d/99-hao-swap.conf"
                "auto:/etc/systemd/journald.conf.d/hao.conf"
                "shared:/etc/docker/daemon.json"
                "shared:/etc/fstab"
            )
            ;;
        "$SVC_NGINX")
            candidates+=(
                "auto:/etc/nginx/nginx.conf"
                "auto:/etc/sysctl.d/99-vps-optimize.conf"
                "auto:/etc/systemd/system/nginx.service.d/limits.conf"
                "auto:/etc/apt/preferences.d/99nginx"
                "auto:/etc/apt/sources.list.d/nginx.list"
                "auto:/etc/security/limits.d/90-hao-nofile.conf"
            )
            binary="$(command -v nginx 2>/dev/null || true)"
            [ -n "$binary" ] && candidates+=("observed:$binary")
            ;;
        "$SVC_DOCKER")
            candidates+=(
                "auto:/etc/apt/sources.list.d/docker.list"
                "observed:/etc/apt/keyrings/docker.gpg"
                "shared:/etc/docker/daemon.json"
            )
            binary="$(command -v docker 2>/dev/null || true)"
            [ -n "$binary" ] && candidates+=("observed:$binary")
            ;;
        "$SVC_GITGITHUB")
            candidates+=(
                "auto:/etc/apt/sources.list.d/github-cli.list"
                "observed:/etc/apt/keyrings/githubcli-archive-keyring.gpg"
                "auto:/usr/local/bin/hao-github-authorize"
            )
            binary="$(command -v git 2>/dev/null || true)"
            [ -n "$binary" ] && candidates+=("observed:$binary")
            binary="$(command -v gh 2>/dev/null || true)"
            [ -n "$binary" ] && candidates+=("observed:$binary")
            target_home="$(getent passwd "$GIT_TARGET_USER" | awk -F: '{print $6}')"
            if [ "$GIT_SCOPE" = "repository" ]; then
                candidates+=("shared:$GIT_REPO_DIR/.git/config")
            else
                [ -n "$target_home" ] && candidates+=("shared:$target_home/.gitconfig")
            fi
            if [ -n "${target_home:-}" ] && [ -d "$target_home/.ssh" ]; then
                for public_key in "$target_home"/.ssh/*.pub; do
                    [ -f "$public_key" ] && candidates+=("observed:$public_key")
                done
            fi
            ;;
        "$SVC_CLIPROXY")
            if [ "$CLIPROXY_DEPLOY_MODE" = "docker" ]; then
                candidates+=(
                    "auto:/opt/docker-services/cliproxyapi/docker-compose.yml"
                    "secret:/opt/docker-services/cliproxyapi/config.yaml"
                    "secret:/opt/docker-services/cliproxyapi/hao-credentials.txt"
                )
            else
                candidates+=(
                    "secret:/etc/cliproxyapi/config.yaml"
                    "auto:/etc/systemd/system/cliproxyapi.service"
                    "secret:/opt/cliproxyapi/hao-credentials.txt"
                )
            fi
            domain_value="${SERVICE_DOMAIN[$svc]:-}"
            [ -n "$domain_value" ] && candidates+=("auto:/etc/nginx/conf.d/${domain_value}.conf")
            ;;
        "$SVC_NEWAPI")
            candidates+=(
                "auto:/opt/docker-services/new-api/docker-compose.yml"
                "secret:/opt/docker-services/new-api/hao-credentials.txt"
            )
            domain_value="${SERVICE_DOMAIN[$svc]:-}"
            [ -n "$domain_value" ] && candidates+=("auto:/etc/nginx/conf.d/${domain_value}.conf")
            ;;
        "$SVC_PI")
            binary="$(command -v pi 2>/dev/null || true)"
            [ -n "$binary" ] && candidates+=("managed:$binary")
            ;;
        "$SVC_CLAUDECODE")
            binary="$(command -v claude 2>/dev/null || true)"
            [ -n "$binary" ] && candidates+=("managed:$binary")
            ;;
    esac

    for path in "${candidates[@]}"; do
        local ownership="${path%%:*}"
        local resource_path="${path#*:}"
        [ -e "$resource_path" ] || continue
        if [ "$ownership" = "auto" ]; then
            if hao_file_is_managed "$resource_path"; then
                ownership="managed"
            else
                ownership="observed"
            fi
        fi
        resources+=("$ownership:$resource_path")
    done

    hao_record_service "$svc" success "$RELEASE_ID" "${resources[@]}"
}

run_install() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         🚀 正在安装服务...           ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo ""

    local total=${#INSTALL_ORDER[@]}
    local current=0

    for svc in "${INSTALL_ORDER[@]}"; do
        ((current+=1))
        local script="${SVC_SCRIPT[$svc]}"
        local name="${SVC_NAME[$svc]}"

        print_section "[$current/$total] 安装 $name"

        local dep dep_failed=false
        for dep in ${SVC_DEPENDS[$svc]}; do
            if [ "${INSTALL_FAILED[$dep]:-}" = "true" ]; then
                dep_failed=true
                break
            fi
        done
        if [ "$dep_failed" = true ]; then
            log_error "$name 依赖安装失败，已跳过"
            INSTALL_RESULTS+=("✗ $name — 依赖失败，已跳过")
            INSTALL_FAILED[$svc]=true
            FAILED=1
            echo ""
            continue
        fi

        if [ ! -f "$script" ]; then
            log_error "安装脚本不存在: $script"
            INSTALL_RESULTS+=("✗ $name — 脚本缺失")
            INSTALL_FAILED[$svc]=true
            FAILED=1
            continue
        fi

        chmod +x "$script"

        # Build env vars
        local -a extra_env=()
        extra_env+=("HAO_UNATTENDED=1")

        local svc_domain="${SERVICE_DOMAIN[$svc]:-}"
        if is_web_service "$svc"; then
            [ -n "$ACCESS_MODE" ] && extra_env+=("HAO_ACCESS_MODE=$ACCESS_MODE")
            [ -z "$svc_domain" ] && svc_domain="$DOMAIN"
            [ -n "$svc_domain" ] && extra_env+=("HAO_DOMAIN=$svc_domain")
        fi

        case "$svc" in
            "$SVC_CLIPROXY")
                extra_env+=("HAO_CLIPROXY_MODE=$CLIPROXY_DEPLOY_MODE")
                if [ "$CLIPROXY_DEPLOY_MODE" = "docker" ]; then
                    extra_env+=("HAO_CLIPROXY_IMAGE=$CLIPROXY_IMAGE")
                fi
                [ -n "$ADMIN_PASSWORD" ] && extra_env+=("HAO_ADMIN_PASSWORD=$ADMIN_PASSWORD")
                ;;
            "$SVC_NEWAPI")
                extra_env+=("HAO_DB_TYPE=$DB_TYPE")
                extra_env+=("HAO_NEWAPI_IMAGE=$NEWAPI_IMAGE")
                ;;
            "$SVC_GITGITHUB")
                extra_env+=(
                    "HAO_GIT_NAME=$GIT_NAME"
                    "HAO_GIT_EMAIL=$GIT_EMAIL"
                    "HAO_GIT_MACHINE_ROLE=$GIT_MACHINE_ROLE"
                    "HAO_GIT_SCOPE=$GIT_SCOPE"
                    "HAO_GIT_TARGET_USER=$GIT_TARGET_USER"
                    "HAO_GH_AUTH_MODE=$GH_AUTH_MODE"
                )
                [ -n "$GIT_REPO_DIR" ] && extra_env+=("HAO_GIT_REPO_DIR=$GIT_REPO_DIR")
                ;;
            "$SVC_PI")
                extra_env+=("HAO_NO_PROMPT=1")
                ;;
            "$SVC_CLAUDECODE")
                # HAO_CC_* 配置变量由 profile 导出后随环境继承，无需逐个转发。
                extra_env+=("HAO_NO_PROMPT=1")
                ;;
        esac

        # Component install.sh owns idempotency/repair/skip behavior.
        # The root installer only resolves order and passes collected config.
        # Execute component install.sh directly (not via 'bash') to preserve $0
        # for scripts that use BASH_SOURCE==$0 guards.
        if env "${extra_env[@]}" "$script"; then
            log_success "$name 安装成功"
            INSTALL_RESULTS+=("✓ $name")
            ALREADY_INSTALLED[$svc]=true
            if ! record_service_management_state "$svc"; then
                log_error "$name 已安装，但 HAO 管理状态记录失败"
                INSTALL_RESULTS+=("✗ $name — 管理状态记录失败")
                INSTALL_FAILED[$svc]=true
                FAILED=1
            fi
        else
            log_error "$name 安装失败"
            INSTALL_RESULTS+=("✗ $name — 失败")
            INSTALL_FAILED[$svc]=true
            FAILED=1
        fi

        echo ""
    done
}

# ==================== 总结 ====================

print_summary() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         部署完成总结                 ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo ""

    for result in "${INSTALL_RESULTS[@]}"; do
        if [[ "$result" == ✓* ]]; then
            echo -e "  ${GREEN}$result${NC}"
        else
            echo -e "  ${RED}$result${NC}"
        fi
    done

    echo ""
    print_divider
    echo ""
    echo -e "${WHITE}常用管理命令:${NC}"
    echo ""

    for svc in "${INSTALL_ORDER[@]}"; do
        case "$svc" in
            "$SVC_MAINTENANCE")
                echo "  Maintenance:"
                echo "    fail2ban-client status sshd  |  swapon --show"
                echo "    journalctl --disk-usage"
                echo ""
                ;;
            "$SVC_NGINX")
                echo "  Nginx:"
                echo "    systemctl status nginx  |  nginx -t  |  systemctl reload nginx"
                echo ""
                ;;
            "$SVC_DOCKER")
                echo "  Docker:"
                echo "    docker info  |  docker compose version"
                echo ""
                ;;
            "$SVC_GITGITHUB")
                echo "  Git + GitHub:"
                echo "    git --version  |  gh --version"
                if [ "$GH_AUTH_MODE" = "web" ]; then
                    if gh_authenticated_for_user "$GIT_TARGET_USER"; then
                        echo "    GitHub 授权: 已为 $GIT_TARGET_USER 配置"
                    else
                        echo "    以 $GIT_TARGET_USER 身份运行: hao-github-authorize"
                    fi
                else
                    echo "    GitHub 个人账号授权已按 profile 跳过"
                fi
                echo ""
                ;;
            "$SVC_NEWAPI")
                echo "  New-API:"
                echo "    cd /opt/docker-services/new-api && docker compose ps"
                echo "    docker compose logs -f new-api"
                echo ""
                ;;
            "$SVC_CLIPROXY")
                echo "  CliproxyAPI:"
                if [ "$CLIPROXY_DEPLOY_MODE" = "docker" ]; then
                    echo "    cd /opt/docker-services/cliproxyapi && docker compose ps"
                    echo "    docker compose logs -f cliproxyapi"
                else
                    echo "    systemctl status cliproxyapi"
                    echo "    journalctl -u cliproxyapi -f"
                fi
                echo ""
                ;;
            "$SVC_PI")
                echo "  Pi:"
                echo "    pi --help  |  pi -p \"你的问题\""
                echo ""
                ;;
            "$SVC_CLAUDECODE")
                echo "  Claude Code:"
                echo "    claude --version  |  claude"
                echo "    配置文件: ~/.claude/settings.json（修改后需重启 claude）"
                echo ""
                ;;
        esac
    done

    print_divider
    echo ""
    echo -e "${CYAN}感谢使用 HAO（HongAgentOps）${RELEASE_ID}！${NC}"
    echo -e "${DIM}日志文件: $DEPLOY_LOG_FILE${NC}"
    echo ""
}

# ==================== AI/CLI 子命令 ====================

cli_usage() {
    cat <<EOF
HAO ${RELEASE_ID} — HongAgentOps
AI-native server deployment and model operations toolkit

用法:
  ./hao plan --services new-api --domain api.example.com
  ./hao preflight --profile deploy.env
  sudo ./hao apply --profile deploy.env --yes
  ./hao status [--services all|new-api,cliproxyapi]
  ./hao doctor [--profile deploy.env]
  ./hao inventory

通用参数:
  --profile FILE                  读取 .env 风格部署配置
  --services LIST                 逗号分隔服务: maintenance,nginx,docker,cliproxyapi,new-api,git-github,pi,claude-code
  --access-mode MODE              domain | ip | http
  --domain VALUE                  单个 Web 服务域名/IP
  --cliproxy-domain VALUE         CliproxyAPI 专用域名
  --newapi-domain VALUE           New-API 专用域名
  --cliproxy-mode MODE            docker | bare
  --cliproxy-image IMAGE          CliproxyAPI Docker 镜像
  --db-type TYPE                  postgresql | mysql
  --newapi-image IMAGE            New-API Docker 镜像
  --git-name NAME                 用户明确确认的 Git 提交名称
  --git-email EMAIL               用户明确确认的 Git 提交邮箱
  --git-machine-role ROLE         workstation | server
  --git-scope SCOPE               global | repository
  --git-repo-dir DIR              repository 作用域的仓库目录
  --git-target-user USER          Git/gh 所属的系统用户
  --gh-auth-mode MODE             web | skip
  --admin-password VALUE          CliproxyAPI 管理密码；省略则自动生成
  --yes                           apply 时确认执行计划

Profile 示例:
  HAO_SERVICES="maintenance,nginx,docker,new-api"
  HAO_ACCESS_MODE="domain"
  HAO_NEWAPI_DOMAIN="api.example.com"
  HAO_DB_TYPE="postgresql"
  HAO_CONFIRM_APPLY="yes"

说明:
  git-github 必须显式选择，不包含在 --services all 中；姓名和邮箱永不自动推导。
  plan/preflight/status/doctor/inventory 不执行安装。apply 只接受明确参数或 profile，
  并且需要 --yes 或 HAO_CONFIRM_APPLY=yes 才会真正修改系统。
EOF
}

trim_value() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

normalize_service_id() {
    local svc
    svc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    svc="${svc//_/-}"
    case "$svc" in
        all) echo "all" ;;
        maintenance|maint|baseline) echo "$SVC_MAINTENANCE" ;;
        nginx) echo "$SVC_NGINX" ;;
        docker|compose) echo "$SVC_DOCKER" ;;
        git-github|gitgithub|git-gh|github|gh|git) echo "$SVC_GITGITHUB" ;;
        cliproxy|cliproxyapi|cpa|cli-proxy-api) echo "$SVC_CLIPROXY" ;;
        newapi|new-api) echo "$SVC_NEWAPI" ;;
        pi|pi-coding-agent|coding-agent) echo "$SVC_PI" ;;
        claude-code|claudecode|claude|cc) echo "$SVC_CLAUDECODE" ;;
        *)
            echo "未知服务: $1" >&2
            return 1
            ;;
    esac
}

service_env_prefix() {
    case "$1" in
        "$SVC_CLIPROXY") echo "CLIPROXY" ;;
        "$SVC_NEWAPI")   echo "NEWAPI" ;;
        *)               echo "" ;;
    esac
}

print_image_candidates() {
    local service="$1" row catalog_service default_image candidate_one candidate_two maturity checked_at
    [ -r "$IMAGE_CANDIDATES_FILE" ] || return 0
    row="$(awk -F '\t' -v service="$service" '$1 == service { print; exit }' "$IMAGE_CANDIDATES_FILE")"
    [ -n "$row" ] || return 0
    IFS=$'\t' read -r catalog_service default_image candidate_one candidate_two maturity checked_at <<< "$row"
    echo "    image_candidates:"
    echo "      - $default_image (rolling default)"
    echo "      - $candidate_one ($maturity)"
    echo "      - $candidate_two ($maturity)"
    echo "    candidates_checked: $checked_at"
}

load_profile_file() {
    local profile="$1"
    local line key value line_no=0

    if [ ! -r "$profile" ]; then
        echo "[ERROR] profile 不存在或不可读: $profile" >&2
        exit 1
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        line_no=$((line_no + 1))
        line="${line%$'\r'}"
        line="$(trim_value "$line")"

        [ -z "$line" ] && continue
        [[ "$line" == \#* ]] && continue

        if [[ "$line" == export[[:space:]]* ]]; then
            line="$(trim_value "${line#export}")"
        fi

        if [[ "$line" != *=* ]]; then
            echo "[ERROR] profile 第 ${line_no} 行格式无效，应为 HAO_KEY=value。" >&2
            exit 1
        fi

        key="$(trim_value "${line%%=*}")"
        value="$(trim_value "${line#*=}")"

        if ! [[ "$key" =~ ^HAO_[A-Z0-9_]+$ ]]; then
            echo "[ERROR] profile 第 ${line_no} 行包含不支持的变量: $key。仅允许 HAO_* 变量。" >&2
            exit 1
        fi

        if [[ "$value" == \"* && "$value" != *\" ]]; then
            echo "[ERROR] profile 第 ${line_no} 行双引号未闭合。" >&2
            exit 1
        fi
        if [[ "$value" == \'* && "$value" != *\' ]]; then
            echo "[ERROR] profile 第 ${line_no} 行单引号未闭合。" >&2
            exit 1
        fi

        case "$value" in
            \"*\")
                value="${value:1:${#value}-2}"
                value="${value//\\\"/\"}"
                value="${value//\\\\/\\}"
                ;;
            \'*\')
                value="${value:1:${#value}-2}"
                ;;
            *)
                value="${value%%#*}"
                value="$(trim_value "$value")"
                ;;
        esac

        printf -v "$key" '%s' "$value"
        export "${key?}"
    done < "$profile"
}

CLI_COMMAND=""
CLI_PROFILE=""
CLI_SERVICES=""
CLI_ASSUME_YES=false
CLI_STATUS_SERVICES=""
CLI_CLIPROXY_DOMAIN=""
CLI_NEWAPI_DOMAIN=""

parse_cli_args() {
    CLI_COMMAND="$1"
    shift || true

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                cli_usage
                exit 0
                ;;
            --profile)
                CLI_PROFILE="${2:-}"
                shift 2
                ;;
            --services|--service)
                CLI_SERVICES="${2:-}"
                CLI_STATUS_SERVICES="$CLI_SERVICES"
                shift 2
                ;;
            --access-mode)
                ACCESS_MODE="${2:-}"
                shift 2
                ;;
            --domain)
                DOMAIN="${2:-}"
                shift 2
                ;;
            --cliproxy-domain)
                CLI_CLIPROXY_DOMAIN="${2:-}"
                shift 2
                ;;
            --newapi-domain|--new-api-domain)
                CLI_NEWAPI_DOMAIN="${2:-}"
                shift 2
                ;;
            --cliproxy-mode)
                CLIPROXY_DEPLOY_MODE="${2:-}"
                shift 2
                ;;
            --cliproxy-image)
                CLIPROXY_IMAGE="${2:-}"
                shift 2
                ;;
            --db-type)
                DB_TYPE="${2:-}"
                shift 2
                ;;
            --newapi-image)
                NEWAPI_IMAGE="${2:-}"
                shift 2
                ;;
            --git-name)
                GIT_NAME="${2:-}"
                shift 2
                ;;
            --git-email)
                GIT_EMAIL="${2:-}"
                shift 2
                ;;
            --git-machine-role)
                GIT_MACHINE_ROLE="${2:-}"
                shift 2
                ;;
            --git-scope)
                GIT_SCOPE="${2:-}"
                shift 2
                ;;
            --git-repo-dir)
                GIT_REPO_DIR="${2:-}"
                shift 2
                ;;
            --git-target-user)
                GIT_TARGET_USER="${2:-}"
                shift 2
                ;;
            --gh-auth-mode)
                GH_AUTH_MODE="${2:-}"
                shift 2
                ;;
            --admin-password)
                ADMIN_PASSWORD="${2:-}"
                shift 2
                ;;
            --yes|-y)
                CLI_ASSUME_YES=true
                shift
                ;;
            *)
                echo "[ERROR] 未知参数: $1" >&2
                cli_usage >&2
                exit 1
                ;;
        esac
    done

    if [ -n "$CLI_PROFILE" ]; then
        load_profile_file "$CLI_PROFILE"
    fi

    CLI_SERVICES="${CLI_SERVICES:-${HAO_SERVICES:-}}"
    ACCESS_MODE="${ACCESS_MODE:-${HAO_ACCESS_MODE:-}}"
    DOMAIN="${DOMAIN:-${HAO_DOMAIN:-}}"
    CLIPROXY_DEPLOY_MODE="${CLIPROXY_DEPLOY_MODE:-${HAO_CLIPROXY_MODE:-docker}}"
    DB_TYPE="${DB_TYPE:-${HAO_DB_TYPE:-postgresql}}"
    CLIPROXY_IMAGE="${CLIPROXY_IMAGE:-${HAO_CLIPROXY_IMAGE:-eceasy/cli-proxy-api:latest}}"
    NEWAPI_IMAGE="${NEWAPI_IMAGE:-${HAO_NEWAPI_IMAGE:-calciumion/new-api:latest}}"
    ADMIN_PASSWORD="${ADMIN_PASSWORD:-${HAO_ADMIN_PASSWORD:-}}"
    CLI_CLIPROXY_DOMAIN="${CLI_CLIPROXY_DOMAIN:-${HAO_CLIPROXY_DOMAIN:-}}"
    CLI_NEWAPI_DOMAIN="${CLI_NEWAPI_DOMAIN:-${HAO_NEWAPI_DOMAIN:-}}"
    GIT_NAME="${GIT_NAME:-${HAO_GIT_NAME:-}}"
    GIT_EMAIL="${GIT_EMAIL:-${HAO_GIT_EMAIL:-}}"
    GIT_MACHINE_ROLE="${GIT_MACHINE_ROLE:-${HAO_GIT_MACHINE_ROLE:-}}"
    GIT_SCOPE="${GIT_SCOPE:-${HAO_GIT_SCOPE:-}}"
    GIT_REPO_DIR="${GIT_REPO_DIR:-${HAO_GIT_REPO_DIR:-}}"
    GIT_TARGET_USER="${GIT_TARGET_USER:-${HAO_GIT_TARGET_USER:-}}"
    GH_AUTH_MODE="${GH_AUTH_MODE:-${HAO_GH_AUTH_MODE:-web}}"

    if [ "${HAO_CONFIRM_APPLY:-}" = "yes" ]; then
        CLI_ASSUME_YES=true
    fi
}

select_cli_services() {
    local raw="$1"
    local item svc

    if [ -z "$raw" ]; then
        echo "[ERROR] 缺少服务列表。请使用 --services 或在 profile 中设置 HAO_SERVICES。" >&2
        exit 1
    fi

    raw="${raw// /}"
    IFS=',' read -r -a requested_services <<< "$raw"

    for item in "${requested_services[@]}"; do
        [ -z "$item" ] && continue
        svc="$(normalize_service_id "$item")" || exit 1
        if [ "$svc" = "all" ]; then
            for svc in "${DEFAULT_ALL_SERVICES[@]}"; do
                TO_INSTALL[$svc]=true
            done
            return 0
        fi
        TO_INSTALL[$svc]=true
    done
}

validate_cli_config() {
    local svc web_count=0

    case "$ACCESS_MODE" in
        ""|domain|ip|http) ;;
        *)
            echo "[ERROR] --access-mode 只能是 domain、ip 或 http，当前: $ACCESS_MODE" >&2
            exit 1
            ;;
    esac

    case "$CLIPROXY_DEPLOY_MODE" in
        docker|compose|docker-compose) CLIPROXY_DEPLOY_MODE="docker" ;;
        bare|binary|systemd|native|host) CLIPROXY_DEPLOY_MODE="bare" ;;
        *)
            echo "[ERROR] --cliproxy-mode 只能是 docker 或 bare，当前: $CLIPROXY_DEPLOY_MODE" >&2
            exit 1
            ;;
    esac

    case "$DB_TYPE" in
        postgresql|postgres|pg) DB_TYPE="postgresql" ;;
        mysql) DB_TYPE="mysql" ;;
        *)
            echo "[ERROR] --db-type 只能是 postgresql 或 mysql，当前: $DB_TYPE" >&2
            exit 1
            ;;
    esac

    if [ "${TO_INSTALL[$SVC_GITGITHUB]:-}" = "true" ]; then
        [ -n "$GIT_NAME" ] || { echo "[ERROR] git-github 需要 --git-name 或 HAO_GIT_NAME；不会自动推导姓名。" >&2; exit 1; }
        [ -n "$GIT_EMAIL" ] || { echo "[ERROR] git-github 需要 --git-email 或 HAO_GIT_EMAIL；不会自动推导邮箱。" >&2; exit 1; }
        [[ "$GIT_NAME" != *$'\n'* && "$GIT_NAME" != *$'\r'* ]] \
            || { echo "[ERROR] Git 姓名不能包含换行。" >&2; exit 1; }
        [[ "$GIT_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] \
            || { echo "[ERROR] Git 邮箱格式无效。" >&2; exit 1; }
        case "$GIT_MACHINE_ROLE" in
            workstation|server) ;;
            *) echo "[ERROR] git-github 需要 --git-machine-role workstation|server。" >&2; exit 1 ;;
        esac
        case "$GIT_SCOPE" in
            global) ;;
            repository)
                [ -n "$GIT_REPO_DIR" ] && [ -d "$GIT_REPO_DIR/.git" ] \
                    || { echo "[ERROR] repository 作用域需要有效的 --git-repo-dir。" >&2; exit 1; }
                GIT_REPO_DIR="$(cd "$GIT_REPO_DIR" && pwd -P)"
                ;;
            *) echo "[ERROR] git-github 需要 --git-scope global|repository。" >&2; exit 1 ;;
        esac
        case "$GH_AUTH_MODE" in
            web|skip) ;;
            *) echo "[ERROR] --gh-auth-mode 只能是 web 或 skip。" >&2; exit 1 ;;
        esac
        if [ -z "$GIT_TARGET_USER" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
            GIT_TARGET_USER="$SUDO_USER"
        fi
        [ -n "$GIT_TARGET_USER" ] && id "$GIT_TARGET_USER" >/dev/null 2>&1 \
            || { echo "[ERROR] 需要有效的 --git-target-user；root 环境不会猜测目标用户。" >&2; exit 1; }
        if [ "$GIT_MACHINE_ROLE" = "server" ] && [ "$GH_AUTH_MODE" = "web" ] \
            && [ "${HAO_GIT_ALLOW_SERVER_AUTH:-}" != "yes" ]; then
            echo "[ERROR] 生产/管理服务器上的个人 GitHub 授权需要 HAO_GIT_ALLOW_SERVER_AUTH=yes。" >&2
            exit 1
        fi
    fi

    if [ -z "$CLIPROXY_IMAGE" ] || [ -z "$NEWAPI_IMAGE" ]; then
        echo "[ERROR] Docker 镜像名称不能为空。" >&2
        exit 1
    fi
    validate_container_image "$CLIPROXY_IMAGE" >/dev/null || exit 1
    validate_container_image "$NEWAPI_IMAGE" >/dev/null || exit 1

    if [ "${TO_INSTALL[$SVC_CLIPROXY]:-}" = "true" ] && [ -n "$CLI_CLIPROXY_DOMAIN" ]; then
        SERVICE_DOMAIN[$SVC_CLIPROXY]="$CLI_CLIPROXY_DOMAIN"
    fi
    if [ "${TO_INSTALL[$SVC_NEWAPI]:-}" = "true" ] && [ -n "$CLI_NEWAPI_DOMAIN" ]; then
        SERVICE_DOMAIN[$SVC_NEWAPI]="$CLI_NEWAPI_DOMAIN"
    fi

    for svc in "${ALL_SERVICES[@]}"; do
        if [ "${TO_INSTALL[$svc]:-}" = "true" ] && is_web_service "$svc"; then
            web_count=$((web_count + 1))
        fi
    done

    if [ "$web_count" -gt 0 ] && [ -z "$ACCESS_MODE" ]; then
        ACCESS_MODE="domain"
    fi

    if [ "$web_count" -eq 1 ] && [ -n "$DOMAIN" ]; then
        for svc in "$SVC_CLIPROXY" "$SVC_NEWAPI"; do
            if [ "${TO_INSTALL[$svc]:-}" = "true" ] && [ -z "${SERVICE_DOMAIN[$svc]:-}" ]; then
                SERVICE_DOMAIN[$svc]="$DOMAIN"
            fi
        done
    fi

    if [ "$web_count" -gt 1 ] && [ "$ACCESS_MODE" != "domain" ]; then
        echo "[ERROR] 同时部署多个 Web 服务时必须使用 domain 模式并为每个服务提供独立域名。" >&2
        exit 1
    fi

    for svc in "${ALL_SERVICES[@]}"; do
        if [ "${TO_INSTALL[$svc]:-}" != "true" ] || ! is_web_service "$svc"; then
            continue
        fi

        if [ "$ACCESS_MODE" = "domain" ] && [ -z "${SERVICE_DOMAIN[$svc]:-}" ]; then
            echo "[ERROR] 缺少 ${SVC_NAME[$svc]} 域名。请提供 --domain、--$(service_env_prefix "$svc" | tr '[:upper:]' '[:lower:]')-domain 或 profile 变量。" >&2
            exit 1
        fi

        if [ "$ACCESS_MODE" = "domain" ]; then
            validate_domain "${SERVICE_DOMAIN[$svc]}" >/dev/null || exit 1
        elif [ "$ACCESS_MODE" = "ip" ] || [ "$ACCESS_MODE" = "http" ]; then
            if [ -z "${SERVICE_DOMAIN[$svc]:-}" ]; then
                SERVICE_DOMAIN[$svc]="$(detect_server_ip)"
            fi
            validate_ip "${SERVICE_DOMAIN[$svc]}" >/dev/null || exit 1
        fi
    done
}

prepare_cli_plan() {
    reset_iteration_state
    parse_cli_args "$@"
    detect_installed_services
    select_cli_services "$CLI_SERVICES"
    validate_cli_config
    HAO_CLIPROXY_MODE="$CLIPROXY_DEPLOY_MODE"
    configure_deployment_modes
    resolve_deps
}

print_cli_plan() {
    local svc dep domain_value

    echo "HAO deployment plan"
    echo "Release: ${RELEASE_ID}"
    echo "Profile: ${CLI_PROFILE:-inline arguments/env}"
    echo ""
    echo "Requested services:"
    for svc in "${ALL_SERVICES[@]}"; do
        if [ "${TO_INSTALL[$svc]:-}" = "true" ]; then
            echo "  - $(service_short_name "$svc"): ${SVC_DESC[$svc]}"
        fi
    done

    echo ""
    echo "Install order:"
    if [ "${#INSTALL_ORDER[@]}" -eq 0 ]; then
        echo "  - Nothing to install"
    else
        for svc in "${INSTALL_ORDER[@]}"; do
            dep="${SVC_DEPENDS[$svc]}"
            [ -z "$dep" ] && dep="none"
            echo "  - $(service_short_name "$svc")"
            echo "    status: ${ALREADY_INSTALLED[$svc]:-false}"
            echo "    script: ${SVC_SCRIPT[$svc]}"
            echo "    dependencies: $dep"
            if is_web_service "$svc"; then
                domain_value="${SERVICE_DOMAIN[$svc]:-}"
                echo "    access_mode: ${ACCESS_MODE:-none}"
                echo "    endpoint: ${domain_value:-not set}"
            fi
            case "$svc" in
                "$SVC_CLIPROXY")
                    echo "    deploy_mode: $CLIPROXY_DEPLOY_MODE"
                    if [ "$CLIPROXY_DEPLOY_MODE" = "docker" ]; then
                        echo "    image: $CLIPROXY_IMAGE"
                        print_image_candidates "cliproxyapi"
                    fi
                    if [ -n "$ADMIN_PASSWORD" ]; then
                        echo "    admin_password: provided (hidden)"
                    else
                        echo "    admin_password: auto-generated"
                    fi
                    ;;
                "$SVC_NEWAPI")
                    echo "    database: $DB_TYPE"
                    echo "    image: $NEWAPI_IMAGE"
                    print_image_candidates "new-api"
                    ;;
                "$SVC_GITGITHUB")
                    echo "    target_user: $GIT_TARGET_USER"
                    echo "    machine_role: $GIT_MACHINE_ROLE"
                    echo "    scope: $GIT_SCOPE"
                    [ "$GIT_SCOPE" = "repository" ] && echo "    repository: $GIT_REPO_DIR"
                    echo "    git_name: $GIT_NAME"
                    echo "    git_email: $GIT_EMAIL"
                    echo "    github_auth: $GH_AUTH_MODE"
                    if [ "$GIT_TARGET_USER" = "root" ] && [ "$GH_AUTH_MODE" = "web" ]; then
                        echo "    warning: GitHub credentials and SSH keys will belong to root"
                    fi
                    if [ "$GIT_MACHINE_ROLE" = "server" ] && [ "$GH_AUTH_MODE" = "web" ]; then
                        echo "    risk: personal GitHub credentials will be stored for a user on this server"
                    fi
                    ;;
                "$SVC_CLAUDECODE")
                    echo "    gateway: ${HAO_CC_BASE_URL:-default (api.anthropic.com)}"
                    echo "    model: ${HAO_CC_MODEL:-default}"
                    if [ -n "${HAO_CC_AUTH_TOKEN:-}" ] || [ -n "${HAO_CC_TOKEN_FILE:-}" ]; then
                        echo "    token: provided (hidden)"
                    else
                        echo "    token: not provided"
                    fi
                    echo "    settings_user: ${HAO_CC_USER:-${SUDO_USER:-root}}"
                    ;;
            esac
        done
    fi

    echo ""
    echo "System changes expected:"
    echo "  - May install OS packages and enable systemd services"
    echo "  - May write files under /opt, /etc/nginx, /etc/docker, /var/log/vps-deploy, /var/lib/hao"
    echo "  - Records HAO ownership and resource hashes in /var/lib/hao/manifest.json"
    echo "  - Nginx configs are backed up before overwrite where supported"
    echo "  - Secret values are written to credential files and are not printed"
    if [ "${TO_INSTALL[$SVC_GITGITHUB]:-}" = "true" ]; then
        echo "  - Installs Git and gh; Git identity config remains a shared user/repository resource"
        echo "  - Does not log in to GitHub; web/SSH authorization is a separate target-user action"
    fi
}

report_check() {
    local status="$1"
    local label="$2"
    local detail="${3:-}"
    printf '  [%s] %s' "$status" "$label"
    [ -n "$detail" ] && printf ' — %s' "$detail"
    printf '\n'
}

run_preflight_checks() {
    local failures=0 warnings=0 svc domain_value server_ip resolved_ips required
    local os os_version arch target_home git_config_file current_name current_email

    os="$(detect_os)"
    os_version="$(detect_os_version_id)"
    arch="$(detect_arch)"
    echo "HAO preflight"
    echo ""

    if is_supported_os_release "$os" "$os_version"; then
        report_check "ok" "OS" "$os $os_version (supported)"
    else
        report_check "fail" "OS" "$os $os_version; supported: $(supported_os_summary)"
        failures=$((failures + 1))
    fi

    case "$arch" in
        linux_amd64|linux_arm64) report_check "ok" "Architecture" "$arch" ;;
        *)
            report_check "warn" "Architecture" "$arch"
            warnings=$((warnings + 1))
            ;;
    esac

    if [ "$EUID" -eq 0 ]; then
        report_check "ok" "Root privileges"
    else
        report_check "warn" "Root privileges" "apply must run with sudo/root"
        warnings=$((warnings + 1))
    fi

    for required in bash sed awk grep find xargs; do
        if command -v "$required" >/dev/null 2>&1; then
            report_check "ok" "Command $required"
        else
            report_check "fail" "Command $required" "missing"
            failures=$((failures + 1))
        fi
    done

    if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
        report_check "ok" "Downloader" "curl/wget available"
    else
        report_check "fail" "Downloader" "curl or wget required"
        failures=$((failures + 1))
    fi

    for svc in "${INSTALL_ORDER[@]}"; do
        if [ ! -x "${SVC_SCRIPT[$svc]}" ]; then
            if [ -f "${SVC_SCRIPT[$svc]}" ]; then
                report_check "warn" "$(service_short_name "$svc") script" "not executable; apply will chmod +x"
                warnings=$((warnings + 1))
            else
                report_check "fail" "$(service_short_name "$svc") script" "missing: ${SVC_SCRIPT[$svc]}"
                failures=$((failures + 1))
            fi
        else
            report_check "ok" "$(service_short_name "$svc") script" "${SVC_SCRIPT[$svc]}"
        fi
    done

    if [ "${TO_INSTALL[$SVC_GITGITHUB]:-}" = "true" ]; then
        if command -v git >/dev/null 2>&1; then
            report_check "ok" "Git" "$(git --version)"
        else
            report_check "ok" "Git" "will be installed from the OS repository"
        fi
        if command -v gh >/dev/null 2>&1; then
            report_check "ok" "GitHub CLI" "$(gh --version | head -1)"
        else
            report_check "ok" "GitHub CLI" "will be installed from the official GitHub CLI repository"
        fi
        report_check "ok" "Git target user" "$GIT_TARGET_USER"
        if [ "$GIT_SCOPE" = "repository" ]; then
            report_check "ok" "Git repository scope" "$GIT_REPO_DIR"
            git_config_file="$GIT_REPO_DIR/.git/config"
        else
            report_check "ok" "Git configuration scope" "global for $GIT_TARGET_USER"
            target_home="$(getent passwd "$GIT_TARGET_USER" | awk -F: '{print $6}')"
            git_config_file="$target_home/.gitconfig"
        fi
        if command -v git >/dev/null 2>&1 && [ -r "$git_config_file" ]; then
            current_name="$(git config --file "$git_config_file" --get user.name 2>/dev/null || true)"
            current_email="$(git config --file "$git_config_file" --get user.email 2>/dev/null || true)"
            if { [ -n "$current_name" ] && [ "$current_name" != "$GIT_NAME" ]; } \
                || { [ -n "$current_email" ] && [ "$current_email" != "$GIT_EMAIL" ]; }; then
                if [ "${HAO_GIT_ALLOW_IDENTITY_CHANGE:-}" = "yes" ]; then
                    report_check "warn" "Existing Git identity" "different values will be replaced after explicit confirmation"
                    warnings=$((warnings + 1))
                else
                    report_check "fail" "Existing Git identity" "different values; review and set HAO_GIT_ALLOW_IDENTITY_CHANGE=yes"
                    failures=$((failures + 1))
                fi
            else
                report_check "ok" "Existing Git identity" "empty or matches the confirmed values"
            fi
        else
            report_check "ok" "Existing Git identity" "no readable identity file; apply performs the final conflict check"
        fi
        if [ -e /etc/apt/sources.list.d/github-cli.list ] \
            && ! hao_file_is_managed /etc/apt/sources.list.d/github-cli.list; then
            report_check "warn" "Existing GitHub CLI apt source" "untracked; apply preserves it only if it exactly matches the official entry"
            warnings=$((warnings + 1))
        fi
        if [ -e /usr/local/bin/hao-github-authorize ] \
            && ! hao_file_is_managed /usr/local/bin/hao-github-authorize; then
            report_check "fail" "Authorization helper path" "untracked file exists and will not be overwritten"
            failures=$((failures + 1))
        fi
        if [ "$GH_AUTH_MODE" = "web" ]; then
            if [ "$GIT_TARGET_USER" = "root" ]; then
                report_check "warn" "Root GitHub authorization" "credentials and SSH keys will be owned by root"
                warnings=$((warnings + 1))
            fi
            if gh_authenticated_for_user "$GIT_TARGET_USER"; then
                report_check "ok" "GitHub authorization" "already configured for $GIT_TARGET_USER"
            else
                report_check "warn" "GitHub authorization" "requires a separate interactive hao-github-authorize run as $GIT_TARGET_USER"
                warnings=$((warnings + 1))
            fi
        else
            report_check "ok" "GitHub authorization" "skipped by profile"
        fi
    fi

    if [ "${TO_INSTALL[$SVC_CLAUDECODE]:-}" = "true" ] && [ -n "${HAO_CC_TOKEN_FILE:-}" ]; then
        if [ -r "$HAO_CC_TOKEN_FILE" ]; then
            report_check "ok" "Claude Code token file" "$HAO_CC_TOKEN_FILE"
        else
            report_check "fail" "Claude Code token file" "not readable: $HAO_CC_TOKEN_FILE"
            failures=$((failures + 1))
        fi
    fi

    if needs_access_mode; then
        server_ip="$(detect_server_ip)"
        [ -n "$server_ip" ] && report_check "ok" "Detected server IP" "$server_ip" || report_check "warn" "Detected server IP" "not available"
        if [ -z "$server_ip" ]; then
            warnings=$((warnings + 1))
        fi

        for svc in "${INSTALL_ORDER[@]}"; do
            if ! is_web_service "$svc"; then
                continue
            fi
            domain_value="${SERVICE_DOMAIN[$svc]:-}"
            [ -z "$domain_value" ] && continue

            if [ "$ACCESS_MODE" = "domain" ]; then
                resolved_ips="$(getent ahosts "$domain_value" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd, - || true)"
                if [ -z "$resolved_ips" ]; then
                    report_check "warn" "DNS $domain_value" "no A/AAAA records found from this host"
                    warnings=$((warnings + 1))
                elif [ -n "$server_ip" ] && ! printf '%s\n' "$resolved_ips" | tr ',' '\n' | grep -qx "$server_ip"; then
                    report_check "warn" "DNS $domain_value" "resolves to $resolved_ips, detected server IP is $server_ip"
                    warnings=$((warnings + 1))
                else
                    report_check "ok" "DNS $domain_value" "$resolved_ips"
                fi
            fi
        done

        for required in 80 443; do
            if check_port_available "$required"; then
                report_check "ok" "Port $required" "available"
            else
                report_check "warn" "Port $required" "currently in use; this can be normal if Nginx is already installed"
                warnings=$((warnings + 1))
            fi
        done
    fi

    echo ""
    echo "Preflight summary: $failures failure(s), $warnings warning(s)"
    [ "$failures" -eq 0 ]
}

print_cli_status() {
    local svc selected_filter="$1" ownership

    detect_installed_services
    echo "HAO status"
    echo ""
    printf '%-16s %-10s %-10s %s\n' "Service" "Installed" "Ownership" "Details"
    printf '%-16s %-10s %-10s %s\n' "-------" "---------" "---------" "-------"
    for svc in "${ALL_SERVICES[@]}"; do
        if [ -n "$selected_filter" ] && [ "$selected_filter" != "all" ] && ! [[ ",$selected_filter," == *",$svc,"* ]]; then
            continue
        fi
        ownership="$(hao_service_ownership "$svc")"
        printf '%-16s %-10s %-10s ' "$(service_short_name "$svc")" "${ALREADY_INSTALLED[$svc]:-false}" "$ownership"
        case "$svc" in
            "$SVC_MAINTENANCE") echo "marker: $([ -f /var/lib/hao/maintenance.installed ] && echo present || echo missing)" ;;
            "$SVC_NGINX")       echo "$(nginx -v 2>&1 | sed 's/^nginx version: //' || echo unavailable)" ;;
            "$SVC_DOCKER")      echo "$(docker --version 2>/dev/null || echo unavailable)" ;;
            "$SVC_GITGITHUB")   echo "$(git --version 2>/dev/null || echo 'git unavailable'); $(gh --version 2>/dev/null | head -1 || echo 'gh unavailable')" ;;
            "$SVC_CLIPROXY")    echo "$(compose_running_text /opt/docker-services/cliproxyapi)" ;;
            "$SVC_NEWAPI")      echo "$(compose_running_text /opt/docker-services/new-api)" ;;
            "$SVC_PI")          echo "$(command -v pi 2>/dev/null || echo unavailable)" ;;
            "$SVC_CLAUDECODE")  echo "$(command -v claude 2>/dev/null || echo unavailable)" ;;
        esac
    done
}

print_hao_inventory() {
    if [ -r "$HAO_STATE_DIR/manifest.json" ]; then
        cat "$HAO_STATE_DIR/manifest.json"
    else
        echo "No HAO inventory found at $HAO_STATE_DIR/manifest.json"
    fi
}

run_cli_command() {
    local command="$1"
    shift || true

    case "$command" in
        help)
            cli_usage
            ;;
        plan)
            prepare_cli_plan "$command" "$@"
            print_cli_plan
            ;;
        preflight)
            prepare_cli_plan "$command" "$@"
            print_cli_plan
            echo ""
            run_preflight_checks
            ;;
        apply)
            prepare_cli_plan "$command" "$@"
            if [ "$CLI_ASSUME_YES" != "true" ]; then
                print_cli_plan
                echo ""
                echo "[ERROR] apply 需要显式确认。请在人工确认计划后追加 --yes，或设置 HAO_CONFIRM_APPLY=yes。" >&2
                exit 1
            fi
            check_root
            setup_logging "hao"
            print_cli_plan
            echo ""
            if ! run_preflight_checks; then
                echo ""
                echo "[ERROR] preflight 存在失败项，已停止 apply。请修复后重试。" >&2
                exit 1
            fi
            echo ""
            run_install
            print_summary
            exit "$FAILED"
            ;;
        status)
            parse_cli_args "$command" "$@"
            local status_filter="" normalized item
            if [ -n "${CLI_STATUS_SERVICES:-$CLI_SERVICES}" ]; then
                local raw_services="${CLI_STATUS_SERVICES:-$CLI_SERVICES}"
                raw_services="${raw_services// /}"
                IFS=',' read -r -a status_items <<< "$raw_services"
                for item in "${status_items[@]}"; do
                    normalized="$(normalize_service_id "$item")" || exit 1
                    if [ "$normalized" = "all" ]; then
                        status_filter="all"
                        break
                    fi
                    status_filter="${status_filter}${status_filter:+,}${normalized}"
                done
            fi
            print_cli_status "$status_filter"
            ;;
        doctor)
            parse_cli_args "$command" "$@"
            if [ -z "${CLI_SERVICES:-}" ]; then
                print_cli_status "all"
                echo ""
                hao_print_drift_report
                exit $?
            fi
            prepare_cli_plan "$command" "$@"
            print_cli_status "all"
            echo ""
            run_preflight_checks
            echo ""
            hao_print_drift_report
            ;;
        inventory)
            parse_cli_args "$command" "$@"
            print_hao_inventory
            ;;
        *)
            echo "[ERROR] 未知命令: $command" >&2
            cli_usage >&2
            exit 1
            ;;
    esac
}

# ==================== 执行 ====================
case "${1:-}" in
    plan|preflight|apply|status|doctor|inventory|help)
        run_cli_command "$@"
        ;;
    *)
        if [ "$#" -eq 0 ]; then
            cli_usage
            exit 0
        fi
        echo "[ERROR] 未知命令: $1" >&2
        cli_usage >&2
        exit 1
        ;;
esac
