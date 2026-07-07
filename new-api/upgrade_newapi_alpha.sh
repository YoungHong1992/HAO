#!/bin/bash
# shellcheck disable=SC2034

################################################################################
#
# New-API Docker Alpha 版本升级脚本
# 版本: v4.0.0
#
# 功能说明：
#   1. 自动从 GitHub API 获取最新的 alpha 版本号
#   2. 备份当前配置
#   3. 拉取指定 alpha 版本镜像
#   4. 更新 docker-compose.yml 中的镜像标签
#   5. 重建服务容器（数据自动保留）
#
# 用法:
#   ./upgrade_newapi_alpha.sh        # 升级
#   ./upgrade_newapi_alpha.sh -h     # 显示帮助
#
################################################################################

set -euo pipefail

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
readonly COMMON_VERSION="4.0.0"
readonly DEPLOY_LOG_DIR="/var/log/vps-deploy"

print_header() {
    local title="${1:-部署工具}"
    clear 2>/dev/null || true
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                                                              ║"
    printf  "║           %-51s║\n" "$title"
    echo "║                                                              ║"
    printf  "║               版本: v%-40s║\n" "${COMMON_VERSION}"
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
    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        echo "$ID"
    elif [ -f /etc/redhat-release ]; then
        echo "rhel"
    else
        echo "unknown"
    fi
}

detect_os_version() {
    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        echo "${VERSION_CODENAME:-unknown}"
    else
        echo "unknown"
    fi
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

confirm() {
    local prompt="$1"
    local default="${2:-n}"

    if [ "$default" = "y" ]; then
        printf "%s [Y/n]: " "$prompt"
    else
        printf "%s [y/N]: " "$prompt"
    fi

    read -r response
    response=${response:-$default}

    case "$response" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

wait_key() {
    echo ""
    read -r -p "按 Enter 键继续..." _
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

select_access_mode() {
    echo "" >&2
    echo -e "${CYAN}>>> 请选择访问方式${NC}" >&2
    echo "" >&2
    echo "  1) 使用域名（推荐）- 自动申请 Let's Encrypt 证书" >&2
    echo "  2) 使用 IP 地址   - 自签名证书，无需域名" >&2
    echo "  3) 仅使用 HTTP    - 无 SSL 证书，仅限内网/开发环境" >&2
    echo "" >&2

    local mode
    while true; do
        read -r -p "请选择 [1/2/3]: " mode
        case "$mode" in
            1) echo "domain"; return 0 ;;
            2) echo "ip"; return 0 ;;
            3) echo "http"; return 0 ;;
            *) log_warning "无效选择，请重新输入" >&2 ;;
        esac
    done
}

get_domain_for_mode() {
    local mode="$1"

    case "$mode" in
        domain)
            local domain
            read -r -p "请输入域名 (例如 api.example.com): " domain
            validate_domain "$domain" || exit 1
            echo "$domain"
            ;;
        ip|http)
            local server_ip ip_confirm domain
            server_ip=$(detect_server_ip)
            if [ -z "$server_ip" ] || ! validate_ip "$server_ip"; then
                log_error "无法获取有效服务器 IP，请手动输入。" >&2
                while true; do
                    read -r -p "请输入服务器 IP 地址: " server_ip
                    validate_ip "$server_ip" && break
                done
            fi
            echo "" >&2
            echo -e "检测到服务器 IP: ${GREEN}$server_ip${NC}" >&2

            if [ "$mode" = "http" ]; then
                echo -e "${YELLOW}⚠️  HTTP 模式警告：${NC}" >&2
                echo -e "${YELLOW}   - 数据传输不加密，API Key 可能泄露${NC}" >&2
                echo -e "${YELLOW}   - 仅建议在内网或开发环境使用${NC}" >&2
            fi

            echo "" >&2
            read -r -p "确认使用此 IP？(y/n，或直接输入其他 IP): " ip_confirm

            case "$ip_confirm" in
                [Yy]|"") echo "$server_ip" ;;
                [Nn])
                    while true; do
                        read -r -p "请输入 IP 地址: " domain
                        validate_ip "$domain" && break
                    done
                    echo "$domain"
                    ;;
                *)
                    if validate_ip "$ip_confirm"; then
                        echo "$ip_confirm"
                    else
                        exit 1
                    fi
                    ;;
            esac
            ;;
    esac
}


for arg in "$@"; do
    case "$arg" in
        -h|--help)
            echo "New-API Alpha 升级脚本 v${COMMON_VERSION}"
            echo "用法: ./upgrade_newapi_alpha.sh"
            exit 0
            ;;
    esac
done

# ==================== 全局配置 ====================
DOCKER_ROOT="/opt/docker-services"
SERVICE_DIR="$DOCKER_ROOT/new-api"
COMPOSE_FILE="$SERVICE_DIR/docker-compose.yml"
BACKUP_DIR="$SERVICE_DIR/backups"
GITHUB_API="https://api.github.com/repos/QuantumNous/new-api/releases"
DOCKER_IMAGE="calciumion/new-api"

# ==================== 环境检查 ====================
check_root
setup_logging "newapi-alpha-upgrade"

if [ ! -d "$SERVICE_DIR" ]; then
    log_error "未检测到 New-API 安装目录: $SERVICE_DIR"
    exit 1
fi

if [ ! -f "$COMPOSE_FILE" ]; then
    log_error "未检测到 docker-compose.yml 文件"
    exit 1
fi

COMPOSE_CMD=$(detect_compose_cmd)
if [ -z "$COMPOSE_CMD" ]; then
    log_error "未检测到 docker-compose。"
    exit 1
fi

# ==================== 欢迎 ====================
clear 2>/dev/null || true
echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${MAGENTA}   New-API Alpha 版本升级程序 v${COMMON_VERSION}${NC}"
echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ==================== 获取当前版本 ====================
log_step "[1/6] 检测当前配置..."

cd "$SERVICE_DIR"

CURRENT_IMAGE_TAG=$(grep -E "^\s+image:\s+calciumion/new-api" "$COMPOSE_FILE" | sed 's/.*image:\s*//' | tr -d '[:space:]' || echo "${DOCKER_IMAGE}:latest")
log_info "当前镜像: ${YELLOW}$CURRENT_IMAGE_TAG${NC}"

CURRENT_IMAGE_ID=$(docker images --format "{{.ID}}" "$CURRENT_IMAGE_TAG" 2>/dev/null | head -1 || echo "")
if [ -n "$CURRENT_IMAGE_ID" ]; then
    CURRENT_CREATED=$(docker images --format "{{.CreatedAt}}" "$CURRENT_IMAGE_TAG" 2>/dev/null | head -1 || echo "")
    log_info "镜像 ID: ${CURRENT_IMAGE_ID:0:12}"
    [ -n "$CURRENT_CREATED" ] && log_info "创建时间: $CURRENT_CREATED"
fi

echo ""
echo -e "${YELLOW}⚠️  Alpha 版本包含最新功能，但可能不稳定。${NC}"
echo ""

echo -e "${CYAN}请选择升级方式:${NC}"
echo "  1) 自动升级到最新 Alpha 版本"
echo "  2) 查看可用的 Alpha 版本列表"
echo "  3) 手动输入版本号"
echo "  4) 回滚到稳定版 (latest)"
read -r -p "请选择 [1-4]: " -n 1 -r CHOICE
echo ""

# ==================== 版本选择 ====================
case $CHOICE in
    1)
        log_step "[2/6] 获取最新 Alpha 版本..."
        LATEST_ALPHA=$(curl -s --connect-timeout 15 "$GITHUB_API" | grep -oP '"tag_name":\s*"v[0-9.]+-alpha\.[0-9]+"' | head -1 | grep -oP 'v[0-9.]+-alpha\.[0-9]+' || echo "")
        if [ -z "$LATEST_ALPHA" ]; then
            log_error "无法获取最新 Alpha 版本信息"
            exit 1
        fi
        TARGET_VERSION="$LATEST_ALPHA"
        log_success "最新 Alpha 版本: ${GREEN}$TARGET_VERSION${NC}"
        ;;
    2)
        log_step "[2/6] 获取可用版本列表..."
        echo ""
        echo -e "${CYAN}===== 最近发布的 Alpha 版本 =====${NC}"
        curl -s --connect-timeout 15 "$GITHUB_API" | grep -oP '"tag_name":\s*"v[0-9.]+-(alpha|beta)\.[0-9]+"' | head -10 | while read -r line; do
            VERSION=$(echo "$line" | grep -oP 'v[0-9.]+-(alpha|beta)\.[0-9]+' || echo "")
            echo -e "  - ${GREEN}$VERSION${NC}"
        done || true
        echo ""
        read -r -p "请输入要安装的版本号 (例如 v0.10.6-alpha.2): " TARGET_VERSION
        [ -z "$TARGET_VERSION" ] && { log_error "版本号不能为空"; exit 1; }
        ;;
    3)
        log_step "[2/6] 手动输入版本号..."
        read -r -p "请输入版本号 (例如 v0.10.6-alpha.2): " TARGET_VERSION
        [ -z "$TARGET_VERSION" ] && { log_error "版本号不能为空"; exit 1; }
        ;;
    4)
        log_step "[2/6] 准备回滚到稳定版..."
        TARGET_VERSION="latest"
        log_warning "将回滚到稳定版 (latest)"
        ;;
    *)
        log_error "无效选择"
        exit 1
        ;;
esac

TARGET_IMAGE="${DOCKER_IMAGE}:${TARGET_VERSION}"

echo ""
if ! confirm "是否继续升级到 $TARGET_IMAGE ?"; then
    log_info "升级已取消。"
    exit 0
fi

# ==================== 备份 ====================
log_step "[3/6] 备份当前配置..."

mkdir -p "$BACKUP_DIR"

VERSION_BACKUP="$BACKUP_DIR/docker-compose_before_${TARGET_VERSION//\//_}_$(date +%Y%m%d_%H%M%S).yml"
cp "$COMPOSE_FILE" "$VERSION_BACKUP"
log_success "版本备份: $VERSION_BACKUP"

# ==================== 更新 compose 文件 ====================
log_step "[4/6] 更新 docker-compose.yml..."

sed -i "s|image:.*calciumion/new-api.*|image: ${TARGET_IMAGE}|g" "$COMPOSE_FILE"
log_success "镜像标签已更新为: ${GREEN}$TARGET_IMAGE${NC}"

# ==================== 拉取镜像 ====================
log_step "[5/6] 拉取新镜像..."

log_info "正在拉取 ${TARGET_IMAGE}..."

if docker pull "$TARGET_IMAGE" 2>&1; then
    log_success "镜像拉取完成"
    NEW_IMAGE_ID=$(docker images --format "{{.ID}}" "$TARGET_IMAGE" 2>/dev/null | head -1 || echo "")
    NEW_CREATED=$(docker images --format "{{.CreatedAt}}" "$TARGET_IMAGE" 2>/dev/null | head -1 || echo "")
    log_info "新镜像 ID: ${GREEN}${NEW_IMAGE_ID:0:12}${NC}"
    [ -n "$NEW_CREATED" ] && log_info "创建时间: $NEW_CREATED"
else
    log_error "镜像拉取失败"
    cp "$VERSION_BACKUP" "$COMPOSE_FILE"
    log_warning "配置文件已回滚"
    exit 1
fi

# ==================== 重建服务 ====================
log_step "[6/6] 重建服务容器..."

log_info "正在使用新镜像重建容器..."

if $COMPOSE_CMD down && $COMPOSE_CMD up -d; then
    log_success "容器重建成功"

    log_info "等待服务启动..."
    wait_for_healthy "$COMPOSE_CMD" "$SERVICE_DIR" 60 5 "new-api" || true

    if $COMPOSE_CMD ps 2>/dev/null | grep -q "Up"; then
        log_success "服务运行正常"
    else
        log_error "服务启动失败，正在回滚..."
        cp "$VERSION_BACKUP" "$COMPOSE_FILE"
        $COMPOSE_CMD down 2>/dev/null || true
        $COMPOSE_CMD up -d || true
        log_warning "已回滚到旧版本"
        exit 1
    fi
else
    log_error "容器重建失败"
    cp "$VERSION_BACKUP" "$COMPOSE_FILE"
    log_warning "配置文件已回滚"
    exit 1
fi

# ==================== 清理 ====================
REMOVED_IMAGES=$(docker image prune -f 2>&1 | grep "Total reclaimed space" || echo "")
[ -n "$REMOVED_IMAGES" ] && log_success "清理完成" && echo "$REMOVED_IMAGES"

# ==================== 完成 ====================
clear 2>/dev/null || true
echo -e "${GREEN}"
echo "================================================"
echo "       New-API Alpha 升级完成！(v${COMMON_VERSION})"
echo "================================================"
echo -e "${NC}"
echo -e "原版本: ${YELLOW}$CURRENT_IMAGE_TAG${NC}"
echo -e "新版本: ${GREEN}$TARGET_IMAGE${NC}"
echo ""
$COMPOSE_CMD ps 2>/dev/null || true
echo ""
echo -e "回滚方法: cp $VERSION_BACKUP $COMPOSE_FILE && cd $SERVICE_DIR && $COMPOSE_CMD down && $COMPOSE_CMD up -d"
echo ""
log_success "日志已保存: $DEPLOY_LOG_FILE"
