#!/bin/bash
# shellcheck disable=SC2034

################################################################################
#
# New-API Docker 卸载脚本
# 发布标识由 HAO_RELEASE 提供
#
# 功能说明：
#   1. 停止并删除所有 New-API 容器
#   2. 删除 Docker 数据卷（可选备份）
#   3. 删除配置文件和目录
#   4. 删除 Nginx 配置
#   5. 删除 SSL 证书（可选）
#   6. 清理共享网络（如无其他容器使用）
#
# 用法:
#   ./uninstall_newapi_docker.sh       # 交互式卸载
#   ./uninstall_newapi_docker.sh -h    # 显示帮助
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
readonly COMMON_VERSION="${HAO_RELEASE:-dev-standalone}"
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
            echo "New-API Docker 卸载脚本 ${COMMON_VERSION}"
            echo "用法: ./uninstall_newapi_docker.sh"
            exit 0
            ;;
    esac
done

# ==================== 全局配置 ====================
SERVICE_DIR="/opt/docker-services/new-api"
BACKUP_DIR="/backup/newapi-uninstall-$(date +%Y%m%d_%H%M%S)"
DOCKER_NETWORK="ai-services"
DELETE_SSL=""
DELETE_VOLUMES=""

# ==================== 环境检查 ====================
check_root
setup_logging "newapi-uninstall"

COMPOSE_CMD=$(detect_compose_cmd)
if [ -z "$COMPOSE_CMD" ]; then
    log_error "未检测到 docker-compose。"
    exit 1
fi

if [ ! -d "$SERVICE_DIR" ]; then
    log_error "未检测到 New-API 安装目录: $SERVICE_DIR"
    exit 1
fi

# ==================== 欢迎界面 ====================
clear 2>/dev/null || true
echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${RED}   New-API Docker 卸载程序 ${COMMON_VERSION}${NC}"
echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}⚠️  警告：此操作将删除以下内容${NC}"
echo ""
echo "  • 所有 New-API 容器 (new-api, newapi-postgres, newapi-redis)"
echo "  • 所有数据库数据 (PostgreSQL/MySQL)"
echo "  • 所有 Redis 缓存数据"
echo "  • 配置文件和日志"
echo "  • Nginx 配置文件"
echo "  • SSL 证书（可选）"
echo ""
echo -e "${GREEN}✓ 不会影响:${NC} Nginx 主程序 / 其他 Docker 服务 / 其他服务配置"
echo ""
echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

read -r -p "是否继续卸载 New-API？(yes/NO): " CONFIRM

if [[ ! "$CONFIRM" == "yes" ]]; then
    log_info "卸载已取消。"
    exit 0
fi

# ==================== 检测当前状态 ====================
log_step "[1/7] 检测当前服务状态..."

cd "$SERVICE_DIR"

NGINX_CONF=$(find /etc/nginx/conf.d/ -maxdepth 1 -name "*.conf" -exec grep -l "NEW-API-START" {} \; 2>/dev/null | head -1 || echo "")
DOMAIN=""
if [ -n "$NGINX_CONF" ]; then
    DOMAIN=$(grep "server_name" "$NGINX_CONF" 2>/dev/null | head -1 | awk '{print $2}' | sed 's/;//g' || echo "")
fi

if [ -z "$DOMAIN" ]; then
    DOMAIN="unknown"
    log_warning "未检测到域名配置"
else
    log_info "检测到域名: $DOMAIN"
fi

RUNNING_CONTAINERS=$($COMPOSE_CMD ps -q 2>/dev/null | wc -l || echo "0")
if [ "$RUNNING_CONTAINERS" -gt 0 ]; then
    log_info "检测到 $RUNNING_CONTAINERS 个运行中的容器"
    $COMPOSE_CMD ps 2>/dev/null || true
fi

echo ""

# ==================== 备份数据 ====================
log_step "[2/7] 数据备份..."

read -r -p "是否备份数据库和配置？(Y/n): " -n 1 -r BACKUP_CHOICE
echo ""

if [[ ! "$BACKUP_CHOICE" =~ ^[Nn]$ ]]; then
    log_info "正在备份数据到: $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"

    [ -f "$SERVICE_DIR/docker-compose.yml" ] && cp "$SERVICE_DIR/docker-compose.yml" "$BACKUP_DIR/" && log_success "已备份 docker-compose.yml"
    [ -f "$SERVICE_DIR/hao-credentials.txt" ] && cp "$SERVICE_DIR/hao-credentials.txt" "$BACKUP_DIR/" && log_success "已备份 hao-credentials.txt"
    [ -f "$SERVICE_DIR/newapi_info.txt" ] && cp "$SERVICE_DIR/newapi_info.txt" "$BACKUP_DIR/" && log_success "已备份旧版 newapi_info.txt"

    if $COMPOSE_CMD ps 2>/dev/null | grep -q "Up"; then
        log_info "正在导出数据库..."
        if $COMPOSE_CMD ps 2>/dev/null | grep -q "postgres"; then
            if $COMPOSE_CMD exec -T postgres pg_dump -U newapi newapi > "$BACKUP_DIR/database_backup.sql" 2>/dev/null; then
                log_success "PostgreSQL 数据库已备份"
            else
                log_warning "数据库备份失败"
            fi
        elif $COMPOSE_CMD ps 2>/dev/null | grep -q "mysql"; then
            DB_PASSWORD=$(grep "MYSQL_PASSWORD\|MYSQL_ROOT_PASSWORD" "$SERVICE_DIR/docker-compose.yml" 2>/dev/null | head -1 | sed 's/.*: *//' || echo "")
            if $COMPOSE_CMD exec -T mysql mysqldump -u newapi -p"$DB_PASSWORD" newapi > "$BACKUP_DIR/database_backup.sql" 2>/dev/null; then
                log_success "MySQL 数据库已备份"
            else
                log_warning "数据库备份失败"
            fi
        fi
    fi

    if [ -d "$BACKUP_DIR" ] && [ "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
        tar -czf "${BACKUP_DIR}.tar.gz" -C "$(dirname "$BACKUP_DIR")" "$(basename "$BACKUP_DIR")" 2>/dev/null
        rm -rf "$BACKUP_DIR"
        log_success "备份已打包: ${BACKUP_DIR}.tar.gz"
    fi
else
    log_info "跳过数据备份"
fi

echo ""

# ==================== 停止并删除容器 ====================
log_step "[3/7] 停止并删除容器..."

cd "$SERVICE_DIR"

if [ -f docker-compose.yml ]; then
    log_info "正在停止容器..."
    $COMPOSE_CMD down 2>/dev/null || true

    read -r -p "是否删除数据卷（包含数据库数据）？(y/N): " -n 1 -r DELETE_VOLUMES
    echo ""

    if [[ "$DELETE_VOLUMES" =~ ^[Yy]$ ]]; then
        log_info "正在删除数据卷..."
        $COMPOSE_CMD down -v 2>/dev/null || true
        log_success "容器和数据卷已删除"
    else
        log_success "容器已删除（数据卷保留）"
    fi
fi

echo ""

# ==================== 删除配置 ====================
log_step "[4/7] 删除配置文件..."

if [ -d "$SERVICE_DIR" ]; then
    rm -rf "$SERVICE_DIR"
    log_success "服务目录已删除"
fi

echo ""

# ==================== 删除 Nginx 配置 ====================
log_step "[5/7] 删除 Nginx 配置..."

NGINX_CONF=$(find /etc/nginx/conf.d/ -maxdepth 1 -name "*.conf" -exec grep -l "NEW-API-START" {} \; 2>/dev/null | head -1 || echo "")

if [ -n "$NGINX_CONF" ] && [ -f "$NGINX_CONF" ]; then
    rm -f "$NGINX_CONF"
    log_success "Nginx 配置已删除"
    if systemctl is-active --quiet nginx 2>/dev/null; then
        systemctl reload nginx || true
    fi
fi

echo ""

# ==================== 删除 SSL ====================
log_step "[6/7] 删除 SSL 证书..."

if [ "$DOMAIN" != "unknown" ]; then
    SSL_CERT_DIR="/etc/nginx/ssl/$DOMAIN"
    if [ -d "$SSL_CERT_DIR" ]; then
        read -r -p "是否删除 SSL 证书？($DOMAIN) (y/N): " -n 1 -r DELETE_SSL
        echo ""
        if [[ "$DELETE_SSL" =~ ^[Yy]$ ]]; then
            rm -rf "$SSL_CERT_DIR"
            if [ -f ~/.acme.sh/acme.sh ]; then
                ~/.acme.sh/acme.sh --remove -d "$DOMAIN" --ecc 2>/dev/null || true
            fi
            log_success "SSL 证书已删除"
        fi
    fi
fi

echo ""

# ==================== 清理网络 ====================
log_step "[7/7] 清理共享网络..."

if docker network ls 2>/dev/null | grep -q "$DOCKER_NETWORK"; then
    NETWORK_CONTAINERS=$(docker network inspect "$DOCKER_NETWORK" -f '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || echo "")
    if [ -z "$NETWORK_CONTAINERS" ]; then
        read -r -p "是否删除共享网络 $DOCKER_NETWORK？(y/N): " -n 1 -r DELETE_NET
        echo ""
        if [[ "$DELETE_NET" =~ ^[Yy]$ ]]; then
            docker network rm "$DOCKER_NETWORK" 2>/dev/null || true
            log_success "共享网络已删除"
        fi
    else
        log_info "共享网络 $DOCKER_NETWORK 中还有其他容器，已保留"
    fi
fi

echo ""

# ==================== 完成 ====================
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}       New-API 卸载完成！${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo -e "${CYAN}保留:${NC} Docker 主程序 / Nginx 主程序 / 其他服务"
echo ""
log_success "日志已保存: $DEPLOY_LOG_FILE"
