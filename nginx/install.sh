#!/bin/bash
# shellcheck disable=SC2034

################################################################################
#
# Nginx 安装与系统优化脚本
# 版本: v4.0.0
#
# 功能说明：
#   1. 系统内核优化：开启 BBR、优化 TCP 连接、提升文件描述符限制
#   2. 通过 nginx.org 官方仓库安装最新主线版（支持 HTTP/3）
#   3. 配置高并发优化
#
# 适用环境：
#   - Ubuntu 20.04+ / Debian 11+
#
# 使用方法：
#   chmod +x install.sh
#   ./install.sh          # 安装
#   ./install.sh -h       # 显示帮助
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
                if mv "$default_site" "$default_backup" 2>/dev/null; then
                    default_moved=true
                fi
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

# Nginx variables are intentionally kept literal in this config snippet.
# shellcheck disable=SC2016
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
Nginx 安装与系统优化脚本

用法:
  ./install.sh             # 安装 Nginx + 系统优化
  ./install.sh --force     # 强制重装/覆盖配置
  ./install.sh -h          # 显示此帮助

功能:
  - 开启 TCP BBR 拥塞控制
  - 优化系统内核参数
  - 从 nginx.org 官方主线仓库安装 Nginx (含 HTTP/3)
  - 配置高并发优化

支持系统: Ubuntu 20.04+, Debian 11+
EOF
    exit 0
}

FORCE_INSTALL=false
for arg in "$@"; do
    case "$arg" in
        -h|--help) show_help ;;
        --force|--reinstall) FORCE_INSTALL=true ;;
        *) ;;
    esac
done

# ==================== 全局配置 ====================

NGINX_CONF_DIR="/etc/nginx"
NGINX_SSL_DIR="$NGINX_CONF_DIR/ssl"
NGINX_USER="nginx"
NGINX_GROUP="nginx"

ensure_nginx_runtime_user() {
    local nologin_shell="/usr/sbin/nologin"
    [ -x "$nologin_shell" ] || nologin_shell="/sbin/nologin"

    if ! getent group "$NGINX_GROUP" >/dev/null 2>&1; then
        groupadd --system "$NGINX_GROUP"
    fi

    if ! id -u "$NGINX_USER" >/dev/null 2>&1; then
        useradd --system --no-create-home --shell "$nologin_shell" --gid "$NGINX_GROUP" "$NGINX_USER"
    fi
}

configure_systemd_limits() {
    local override_dir="/etc/systemd/system/nginx.service.d"
    mkdir -p "$override_dir"
    cat > "$override_dir/limits.conf" <<'SYSTEMD_EOF'
[Service]
LimitNOFILE=65535
SYSTEMD_EOF
    systemctl daemon-reload
    log_success "systemd 文件描述符限制已配置 (LimitNOFILE=65535)"
}

prepare_nginx_directories() {
    mkdir -p "$NGINX_SSL_DIR" /var/log/nginx
    chown -R root:root "$NGINX_SSL_DIR"
    chmod 755 "$NGINX_SSL_DIR"

    find "$NGINX_SSL_DIR" -type d -exec chmod 755 {} + 2>/dev/null || true
    find "$NGINX_SSL_DIR" -type f -name 'key.pem' -exec chmod 600 {} + 2>/dev/null || true
    find "$NGINX_SSL_DIR" -type f -name 'fullchain.pem' -exec chmod 644 {} + 2>/dev/null || true

    chown root:root /var/log/nginx
    chmod 755 /var/log/nginx

    mkdir -p \
        /var/cache/nginx/client_temp \
        /var/cache/nginx/proxy_temp \
        /var/cache/nginx/fastcgi_temp \
        /var/cache/nginx/uwsgi_temp \
        /var/cache/nginx/scgi_temp
    chown -R "$NGINX_USER:$NGINX_GROUP" /var/cache/nginx
}

nginx_is_healthy() {
    command -v nginx >/dev/null 2>&1 \
        && nginx -t >/dev/null 2>&1 \
        && systemctl is-active --quiet nginx 2>/dev/null
}

handle_existing_nginx() {
    command -v nginx >/dev/null 2>&1 || return 0

    if nginx -t >/dev/null 2>&1 && ! systemctl is-active --quiet nginx 2>/dev/null; then
        log_warning "检测到 Nginx 已安装但未运行，尝试启动..."
        systemctl enable nginx >/dev/null 2>&1 || true
        systemctl start nginx >/dev/null 2>&1 || true
    fi

    if ! nginx_is_healthy; then
        log_warning "检测到已有 Nginx，但当前状态不完整，将继续执行安装/修复流程。"
        return 0
    fi

    log_success "检测到 Nginx 已安装且运行正常。"

    if [ "$FORCE_INSTALL" = true ]; then
        log_warning "已指定 --force，将继续重装并覆盖主配置。"
        return 0
    fi

    if is_noninteractive; then
        log_info "非交互模式下跳过 Nginx 重装；如需覆盖配置，请直接运行 nginx/install.sh --force。"
        exit 0
    fi

    if confirm "是否重新安装并覆盖 /etc/nginx/nginx.conf？" "n"; then
        log_warning "继续执行重装/覆盖配置流程。"
        return 0
    fi

    log_info "已跳过 Nginx 重装。"
    exit 0
}

# ==================== 部署流程 ====================
check_root
setup_logging "nginx-install"
handle_existing_nginx

log_step "[1/3] 系统环境检查与优化..."

# 1. 内核参数优化 (开启 BBR + TCP 调优)
log_info "优化 sysctl.conf..."
cat > /etc/sysctl.d/99-vps-optimize.conf <<'SYSCTL_EOF'
# --- BBR 拥塞控制 ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- TCP 优化 ---
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.ip_local_port_range = 10000 65000
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_fastopen = 3
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 8192

# --- 文件描述符 ---
fs.file-max = 1000000
SYSCTL_EOF

# 应用内核参数
sysctl -p /etc/sysctl.d/99-vps-optimize.conf > /dev/null 2>&1 || true

# 验证 BBR
BBR_STATUS=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
if [ "$BBR_STATUS" = "bbr" ]; then
    BBR_SUMMARY="BBR 已开启"
    log_success "TCP BBR 已成功开启"
else
    BBR_SUMMARY="BBR 未开启"
    log_warning "BBR 开启失败，请检查内核版本 (建议 >= 4.9)"
fi

# 2. 提升系统级文件描述符限制
if ! grep -q "soft nofile 65535" /etc/security/limits.conf 2>/dev/null; then
    {
        echo "* soft nofile 65535"
        echo "* hard nofile 65535"
        echo "root soft nofile 65535"
        echo "root hard nofile 65535"
    } >> /etc/security/limits.conf
fi

# 3. systemd 文件描述符限制会在 Nginx 安装后写入服务 override

# ==================== 步骤 2: 安装 Nginx ====================

log_step "[2/3] 安装 Nginx (nginx.org 官方主线包)..."

# 检测系统并添加 nginx.org 官方仓库
if [ -f /etc/debian_version ]; then
    # 安装必要依赖（curl 已存在时也要确保 gpg/证书工具存在）
    apt-get update -y -qq
    apt-get install -y -qq curl gnupg2 ca-certificates lsb-release

    # 添加 nginx.org GPG key
    curl -fsSL --connect-timeout 30 https://nginx.org/keys/nginx_signing.key \
        | gpg --dearmor --yes -o /usr/share/keyrings/nginx-archive-keyring.gpg

    # 添加 mainline 仓库（支持 HTTP/3）
    . /etc/os-release
    if [ "$ID" = "debian" ] && [ -z "${VERSION_CODENAME:-}" ]; then
        VERSION_CODENAME=$(lsb_release -cs 2>/dev/null || echo "bookworm")
    fi
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
http://nginx.org/packages/mainline/${ID}/ ${VERSION_CODENAME} nginx" \
        > /etc/apt/sources.list.d/nginx.list

    # 优先使用 nginx.org 仓库
    cat > /etc/apt/preferences.d/99nginx <<'APT_PREF_EOF'
Package: nginx*
Pin: origin nginx.org
Pin-Priority: 900
APT_PREF_EOF

    apt-get update -y -qq
    apt-get install -y nginx

    log_success "Nginx 安装完成"

elif [ -f /etc/redhat-release ]; then
    log_error "CentOS / RHEL 不在本脚本的支持范围内。"
    log_info "请使用 Ubuntu 20.04+ 或 Debian 11+。"
    log_info "对于 RHEL 系列，请参考 nginx.org 官方文档手动安装。"
    exit 1
else
    log_error "不支持的操作系统。"
    exit 1
fi

# 确保运行用户和 systemd 限制
ensure_nginx_runtime_user
configure_systemd_limits

# 验证 HTTP/3 模块
if nginx -V 2>&1 | grep -q "http_v3_module"; then
    log_success "HTTP/3 (QUIC) 模块已就绪"
else
    log_warning "当前 Nginx 未包含 HTTP/3 模块"
fi

# ==================== 步骤 3: 配置 Nginx ====================

log_step "[3/3] 配置 Nginx 高并发优化..."

# 备份已有配置
if [ -f "$NGINX_CONF_DIR/nginx.conf" ]; then
    backup_file "$NGINX_CONF_DIR/nginx.conf"
fi

# 创建运行目录、缓存目录、日志目录和 SSL 证书目录
prepare_nginx_directories

# 生成 nginx.conf（高并发调优 + 模块化站点配置）
cat > "$NGINX_CONF_DIR/nginx.conf" <<NGINX_EOF
user  $NGINX_USER;
worker_processes  auto;
worker_rlimit_nofile 65535;

error_log  /var/log/nginx/error.log warn;
pid        /run/nginx.pid;

events {
    worker_connections  10240;
    use epoll;
    multi_accept on;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                      '\$status \$body_bytes_sent "\$http_referer" '
                      '"\$http_user_agent" "\$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;

    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;
    keepalive_timeout  65;
    types_hash_max_size 2048;
    server_tokens   off;

    gzip on;
    gzip_min_length 1k;
    gzip_comp_level 4;
    gzip_types text/plain text/css application/json application/javascript application/xml;

    # 加载模块化站点配置
    include /etc/nginx/conf.d/*.conf;
}
NGINX_EOF

# 测试配置并启动
if nginx -t; then
    systemctl enable nginx
    if systemctl restart nginx; then
        log_success "Nginx 配置测试通过，服务已启动"
    else
        log_error "Nginx 服务启动失败，请检查: journalctl -xe -u nginx"
        exit 1
    fi
else
    log_error "Nginx 配置测试失败，请检查"
    exit 1
fi

# ==================== 输出安装摘要 ====================

NGINX_VERSION=$(nginx -v 2>&1 | grep -oP 'nginx/\K[0-9.]+' || echo "unknown")
echo ""
echo -e "${GREEN}==============================================${NC}"
echo -e "${GREEN}   Nginx 安装与系统优化完成${NC}"
echo -e "${GREEN}==============================================${NC}"
echo -e "版本:         ${GREEN}v${COMMON_VERSION}${NC}"
echo -e "Nginx 版本:   ${YELLOW}$NGINX_VERSION${NC}"
echo -e "安装来源:     ${YELLOW}nginx.org 官方主线仓库${NC}"
echo -e "配置文件:     ${YELLOW}/etc/nginx/nginx.conf${NC}"
echo -e "站点配置:     ${YELLOW}/etc/nginx/conf.d/*.conf${NC}"
echo -e "SSL 证书:     ${YELLOW}/etc/nginx/ssl/${NC}"
echo -e "优化状态:     ${GREEN}${BBR_SUMMARY}, systemd LimitNOFILE=65535${NC}"
echo -e "HTTP/3 支持:  ${GREEN}$(detect_nginx_http3 && echo '✓' || echo '✗')${NC}"
echo -e "${GREEN}==============================================${NC}"
echo ""
log_success "日志已保存: $DEPLOY_LOG_FILE"
