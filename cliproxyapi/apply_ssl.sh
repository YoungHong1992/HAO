#!/bin/bash
# shellcheck disable=SC2034

################################################################################
#
# 通用 SSL 证书申请工具
# 版本: v4.0.0
#
# 功能说明：
#   - 为任意域名申请 Let's Encrypt ECC-256 证书
#   - 自动配置 Nginx（可选）
#   - 支持交互式和非交互式使用
#   - 失败时自动降级为自签名证书
#
# 使用方法：
#   交互式:   ./apply_ssl.sh
#   非交互式: ./apply_ssl.sh -d api.example.com [-s cliproxyapi] [-p 8317]
#   帮助:     ./apply_ssl.sh -h
#
# 参数说明：
#   -d DOMAIN   域名（必填）
#   -s SERVICE  服务名称（用于生成 Nginx 配置文件名，可选）
#   -p PORT     后端服务端口（可选）
#   -h          显示帮助信息
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


# ==================== 帮助信息 ====================
show_help() {
    cat <<'EOF'
通用 SSL 证书申请工具

用法:
  交互式:   ./apply_ssl.sh
  非交互式: ./apply_ssl.sh -d <域名> [-s <服务名>] [-p <端口>]
  帮助:     ./apply_ssl.sh -h

参数说明:
  -d DOMAIN   域名（必填）
  -s SERVICE  服务名称（可选），用于生成 Nginx 配置文件名
  -p PORT     后端服务端口（可选），指定后生成反向代理配置
  -h          显示此帮助信息

示例:
  ./apply_ssl.sh -d api.example.com
  ./apply_ssl.sh -d api.example.com -s cliproxyapi -p 8317

注意事项:
  1. 必须以 root 权限运行
  2. 域名需已解析到本服务器
  3. Nginx 必须已安装并运行
EOF
    exit 0
}

# ==================== 参数解析 ====================
DOMAIN=""
SERVICE=""
PORT=""

while getopts "d:s:p:h" opt; do
    case $opt in
        d) DOMAIN="$OPTARG" ;;
        s) SERVICE="$OPTARG" ;;
        p) PORT="$OPTARG" ;;
        h) show_help ;;
        *) show_help; exit 1 ;;
    esac
done

# ==================== 环境检查 ====================
check_root

if ! command -v nginx &> /dev/null; then
    echo -e "${RED}错误: 未检测到 Nginx 安装。${NC}"
    echo -e "请先安装 Nginx：进入仓库根目录的 nginx/ 目录运行 sudo ./install.sh，或使用根目录 sudo ./install.sh 选择 Nginx。"
    exit 1
fi

if ! systemctl is-active --quiet nginx; then
    echo -e "${RED}错误: Nginx 未运行。${NC}"
    echo -e "请先启动 Nginx: systemctl start nginx"
    exit 1
fi

ensure_commands curl openssl

# ==================== 交互式输入 ====================

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}   通用 SSL 证书申请工具 v${COMMON_VERSION}${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# 交互式输入域名
if [ -z "$DOMAIN" ]; then
    read -r -p "请输入域名 (例如 api.example.com): " DOMAIN
fi

# 域名验证
validate_domain "$DOMAIN" || exit 1

# 交互式输入服务名（可选）
if [ -z "$SERVICE" ]; then
    read -r -p "服务名称 (留空则不生成 Nginx 配置): " SERVICE
fi

# 交互式输入端口（可选）
if [ -z "$PORT" ] && [ -n "$SERVICE" ]; then
    read -r -p "后端服务端口 (留空则生成基础配置): " PORT
fi

# ==================== DNS 检查提示 ====================

CONF_D="/etc/nginx/conf.d"
SSL_DIR="/etc/nginx/ssl"
SERVER_IP=$(detect_server_ip)

echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}⚠️  DNS 解析检查${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "域名:         ${GREEN}$DOMAIN${NC}"
echo -e "服务器 IP:    ${GREEN}$SERVER_IP${NC}"

# 检查域名解析
RESOLVED_IP=$(nslookup "$DOMAIN" 2>/dev/null | grep -A1 'Name:' | tail -n1 | awk '{print $2}' || true)
if [ -z "$RESOLVED_IP" ]; then
    RESOLVED_IP=$(dig +short "$DOMAIN" 2>/dev/null | tail -n1 || true)
fi

if [ -n "$RESOLVED_IP" ]; then
    echo -e "域名解析到:   ${GREEN}$RESOLVED_IP${NC}"

    if [ "$RESOLVED_IP" == "$SERVER_IP" ]; then
        echo -e "${GREEN}✓ 域名解析正确${NC}"
    else
        echo -e "${YELLOW}⚠ 域名未解析到本服务器，SSL 申请可能失败${NC}"
        echo -e "${YELLOW}  如果使用 Cloudflare CDN，这是正常的${NC}"
    fi
else
    echo -e "${YELLOW}⚠ 无法解析域名，请确保 DNS 已配置${NC}"
fi

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
read -r -p "按回车继续申请证书..." _

# ==================== 申请 SSL 证书 ====================

echo ""
log_step "[1/3] 检查 acme.sh..."

DOMAIN_SSL_DIR="$SSL_DIR/$DOMAIN"

# 创建临时 Nginx 配置用于验证（如不存在）
NGINX_CONF="$CONF_D/${DOMAIN}.conf"
TEMP_CONF=false

if [ ! -f "$NGINX_CONF" ]; then
    log_info "创建临时 Nginx 配置用于 ACME 验证..."
    cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ {
        root /var/www/acme;
    }
}
EOF
    TEMP_CONF=true
    mkdir -p /var/www/acme
    nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
fi

# 申请证书
log_step "[2/3] 申请 SSL 证书..."
SSL_TYPE=$(apply_ssl_certificate "$DOMAIN" "$DOMAIN_SSL_DIR" "domain")

SSL_OK=false
if [ -f "$DOMAIN_SSL_DIR/fullchain.pem" ] && [[ "$SSL_TYPE" =~ "Let's Encrypt" ]]; then
    SSL_OK=true
fi

# ==================== 配置 Nginx ====================

log_step "[3/3] 配置 Nginx..."

if [ -n "$SERVICE" ]; then
    if [ "$TEMP_CONF" = true ]; then
        FINAL_CONF="$CONF_D/${DOMAIN}.conf"
    else
        FINAL_CONF="$NGINX_CONF"
        if [ -f "$FINAL_CONF" ]; then
            backup_file "$FINAL_CONF"
        fi
    fi

    if [ -n "$PORT" ]; then
        # 生成完整反向代理配置
        cat > "$FINAL_CONF" <<NGINX_EOF
# HTTP → HTTPS 重定向
server {
    listen 80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/acme;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# HTTPS 反向代理
server {
    listen 443 ssl;
    http2 on;
    server_name $DOMAIN;

    ssl_certificate $DOMAIN_SSL_DIR/fullchain.pem;
    ssl_certificate_key $DOMAIN_SSL_DIR/key.pem;
    ${NGINX_SSL_CONFIG}

    access_log /var/log/nginx/${SERVICE}_access.log main;
    error_log /var/log/nginx/${SERVICE}_error.log warn;

    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
    }
}
NGINX_EOF
        log_success "已生成完整反向代理配置"
    else
        # 生成基础 HTTPS 配置
        cat > "$FINAL_CONF" <<NGINX_EOF
# HTTP → HTTPS 重定向
server {
    listen 80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/acme;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# HTTPS 基础配置
server {
    listen 443 ssl;
    http2 on;
    server_name $DOMAIN;

    ssl_certificate $DOMAIN_SSL_DIR/fullchain.pem;
    ssl_certificate_key $DOMAIN_SSL_DIR/key.pem;
    ${NGINX_SSL_CONFIG}

    root /var/www/html;
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
NGINX_EOF
        log_success "已生成基础 HTTPS 配置"
    fi

    echo -e "配置文件: ${YELLOW}$FINAL_CONF${NC}"
else
    log_info "未指定服务名，跳过 Nginx 配置生成"
fi

# 测试并重载 Nginx
if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx || true
    log_success "Nginx 配置测试通过并已重载"
else
    log_error "Nginx 配置测试失败，请检查配置"
    nginx -t 2>&1 || true
    exit 1
fi

# ==================== 输出结果 ====================

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}   SSL 证书申请完成${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "域名:       ${CYAN}$DOMAIN${NC}"
echo -e "证书类型:   ${CYAN}$SSL_TYPE${NC}"
echo -e "证书目录:   ${CYAN}$DOMAIN_SSL_DIR/${NC}"
echo -e "  - 私钥:   ${YELLOW}key.pem${NC}"
echo -e "  - 证书:   ${YELLOW}fullchain.pem${NC}"

if [ -n "$SERVICE" ]; then
    echo -e "Nginx配置:  ${CYAN}$FINAL_CONF${NC}"
fi

echo ""
echo -e "${CYAN}[访问地址]${NC}"
echo -e "HTTP:       ${YELLOW}http://$DOMAIN${NC}"
echo -e "HTTPS:      ${YELLOW}https://$DOMAIN${NC}"

if [ "$SSL_OK" = true ]; then
    echo ""
    echo -e "${GREEN}[证书续期]${NC}"
    echo -e "acme.sh 已自动配置 cron 任务，证书将在到期前自动续期。"
    echo -e "查看任务: ${YELLOW}crontab -l | grep acme${NC}"
else
    echo ""
    echo -e "${YELLOW}[提示]${NC}"
    echo -e "使用自签名证书，客户端需要跳过证书验证或手动信任。"
    echo -e "建议确保域名正确解析后，重新运行此脚本申请有效证书。"
fi

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
