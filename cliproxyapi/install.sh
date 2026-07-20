#!/bin/bash
# shellcheck disable=SC2034

################################################################################
#
# CliproxyAPI 智能安装/升级脚本
# 发布标识由 HAO_RELEASE 提供
#
# 功能说明：
#   1. 自动检测是否已安装（智能判断全新安装 or 升级）
#   2. 默认使用 Docker Compose 部署，支持裸机二进制 + Systemd 选项
#   3. 全新安装：完整的交互式配置流程
#   4. 升级模式：保留现有配置，更新镜像或二进制文件
#   5. 支持域名模式 / IP 模式 / HTTP 模式
#   6. 配置 Nginx 反向代理（HTTPS + WebSocket）
#   7. 支持回滚机制
#
# 用法:
#   ./install.sh        # 交互式安装/升级（默认 Docker Compose）
#   HAO_CLIPROXY_MODE=bare ./install.sh  # 裸机安装/升级
#   ./install.sh -h     # 显示帮助
#
# 前置条件：
#   - 必须先运行 ../nginx/install.sh
#   - 默认 Docker Compose 部署需先运行 ../docker/install.sh
#   - 域名模式：域名需要解析到本服务器
#   - IP/HTTP 模式：无需域名
#
################################################################################

set -euo pipefail

HAO_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HAO_REPO_DIR="$(cd "$HAO_SCRIPT_DIR/.." && pwd)"
# ==================== 公共函数 ====================
# 本脚本可在完整仓库内独立运行，并复用 ../lib 公共库。
# shellcheck source=../lib/common.sh
source "$HAO_REPO_DIR/lib/common.sh"
# shellcheck source=../lib/crypto.sh
source "$HAO_REPO_DIR/lib/crypto.sh"
# shellcheck source=../lib/credentials.sh
source "$HAO_REPO_DIR/lib/credentials.sh"

# ==================== 帮助 ====================
show_help() {
    cat <<'EOF'
CliproxyAPI 智能安装/升级脚本

用法:
  ./install.sh       # 交互式安装/升级（默认 Docker Compose）
  ./install.sh -h    # 显示此帮助

部署方式:
  - Docker Compose（默认推荐）
  - 裸机二进制 + Systemd（设置 HAO_CLIPROXY_MODE=bare）

功能:
  - 自动检测全新安装 or 升级
  - 支持域名/IP/HTTP 三种访问模式
  - 自动申请 SSL 证书或生成自签名证书
  - Docker Compose 部署时配置 /opt/docker-services/cliproxyapi
  - 裸机部署时配置 Nginx 反向代理 + Systemd 服务

前置条件:
  - 已安装 Nginx (../nginx/install.sh)
  - 默认 Docker Compose 部署需已安装 Docker + Compose (../docker/install.sh)
  - 域名模式需 DNS 已解析
EOF
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        -h|--help) show_help ;;
    esac
done

# ==================== 全局配置 ====================
CLIPROXY_PORT=8317
CONF_D="/etc/nginx/conf.d"
SSL_DIR="/etc/nginx/ssl"
INSTALL_DIR="/opt/cliproxyapi"
CONFIG_DIR="/etc/cliproxyapi"
DATA_DIR="/var/lib/cliproxyapi"
LOG_DIR="/var/log/cliproxyapi"
GITHUB_REPO="router-for-me/CLIProxyAPI"
GITHUB_API="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
DOCKER_ROOT="/opt/docker-services"
DOCKER_SERVICE_DIR="$DOCKER_ROOT/cliproxyapi"
DOCKER_CONFIG_FILE="$DOCKER_SERVICE_DIR/config.yaml"
DOCKER_AUTH_DIR="$DOCKER_SERVICE_DIR/auths"
DOCKER_LOG_DIR="$DOCKER_SERVICE_DIR/logs"
DOCKER_IMAGE="${HAO_CLIPROXY_IMAGE:-eceasy/cli-proxy-api:latest}"
DOCKER_CONTAINER_NAME="cliproxyapi"

normalize_deploy_mode() {
    local mode="${1,,}"
    case "$mode" in
        docker|compose|docker-compose) echo "docker" ;;
        bare|binary|systemd|native|host) echo "bare" ;;
        *) return 1 ;;
    esac
}

detect_existing_deploy_mode() {
    if [ -f "$DOCKER_SERVICE_DIR/docker-compose.yml" ]; then
        echo "docker"
        return 0
    fi
    if [ -f "$INSTALL_DIR/version.txt" ] || [ -f /etc/systemd/system/cliproxyapi.service ]; then
        echo "bare"
        return 0
    fi
    echo ""
}

select_deploy_mode() {
    local requested existing normalized choice
    requested="${HAO_CLIPROXY_MODE:-}"

    if [ -n "$requested" ]; then
        if normalized=$(normalize_deploy_mode "$requested"); then
            echo "$normalized"
            return 0
        fi
        log_error "未知 CliproxyAPI 部署方式: $requested"
        log_info "可用值: docker / bare"
        exit 1
    fi

    existing=$(detect_existing_deploy_mode)
    if [ -n "$existing" ]; then
        echo "$existing"
        return 0
    fi

    if is_noninteractive; then
        echo "docker"
        return 0
    fi

    echo "" >&2
    echo -e "${CYAN}>>> 请选择 CliproxyAPI 部署方式${NC}" >&2
    echo "" >&2
    echo "  1) Docker Compose（推荐，默认）— 镜像升级简单，配置/数据集中在 /opt/docker-services/cliproxyapi" >&2
    echo "  2) 裸机二进制 + Systemd       — 低开销，适合只单独运行 CPA" >&2
    echo "" >&2

    while true; do
        read -r -p "请选择 [1/2，默认 1]: " choice
        choice="${choice:-1}"
        case "$choice" in
            1) echo "docker"; return 0 ;;
            2) echo "bare"; return 0 ;;
            *) log_warning "无效选择，请重新输入" >&2 ;;
        esac
    done
}

# ==================== Docker Compose 部署 ====================

run_docker_deploy() {
    local backup_dir="" access_url management_url protocol access_mode_text credentials_file domain_ssl_dir conf_file
    local existing_domain_conf conf_backup image_explicit existing_image

    log_step "[1/7] 创建 Docker Compose 目录..."
    mkdir -p "$DOCKER_SERVICE_DIR" "$DOCKER_AUTH_DIR" "$DOCKER_LOG_DIR"
    log_success "目录已就绪: $DOCKER_SERVICE_DIR"

    # 升级且用户未显式指定镜像时，沿用现有 compose 中的镜像，
    # 避免把用户固定的 tag/digest 静默改回默认 latest。
    # HAO_CLIPROXY_IMAGE_EXPLICIT 由根 install.sh 传入；独立运行时以
    # HAO_CLIPROXY_IMAGE 是否被设置作为显式依据。
    image_explicit="${HAO_CLIPROXY_IMAGE_EXPLICIT:-}"
    if [ -z "$image_explicit" ]; then
        [ -n "${HAO_CLIPROXY_IMAGE:-}" ] && image_explicit=true || image_explicit=false
    fi
    if [ "$IS_UPGRADE" = true ] && [ "$image_explicit" != "true" ] \
        && [ -f "$DOCKER_SERVICE_DIR/docker-compose.yml" ]; then
        existing_image="$(awk '$1 == "image:" { print $2; exit }' "$DOCKER_SERVICE_DIR/docker-compose.yml")"
        if [ -n "$existing_image" ] && [ "$existing_image" != "$DOCKER_IMAGE" ]; then
            DOCKER_IMAGE="$existing_image"
            log_info "升级模式：沿用现有镜像 $DOCKER_IMAGE（如需更换请显式指定 --cliproxy-image 或 HAO_CLIPROXY_IMAGE）"
        fi
    fi

    if [ "$IS_UPGRADE" = true ]; then
        backup_dir="$DOCKER_SERVICE_DIR/backup_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$backup_dir"
        [ -f "$DOCKER_CONFIG_FILE" ] && cp -a "$DOCKER_CONFIG_FILE" "$backup_dir/config.yaml"
        [ -f "$DOCKER_SERVICE_DIR/docker-compose.yml" ] && cp -a "$DOCKER_SERVICE_DIR/docker-compose.yml" "$backup_dir/docker-compose.yml"
        log_success "已备份现有配置: $backup_dir"
    fi

    log_step "[2/7] 生成 CliproxyAPI 配置..."
    if [ "$IS_UPGRADE" = false ] || [ ! -f "$DOCKER_CONFIG_FILE" ]; then
        API_KEY_1=$(generate_api_key "sk-")
        API_KEY_2=$(generate_api_key "sk-")
        ADMIN_SECRET_ESCAPED=$(escape_double_quoted "$ADMIN_SECRET")

        # 含 API 密钥与管理密码，落盘前先以 600 权限建档，避免出现可读窗口
        install -m 600 /dev/null "$DOCKER_CONFIG_FILE"
        cat > "$DOCKER_CONFIG_FILE" <<YAML_EOF
# CliproxyAPI Configuration File
# Auto-generated by HAO install script ${COMMON_VERSION}

host: ""
port: $CLIPROXY_PORT

auth-dir: "/root/.cli-proxy-api"

api-keys:
  - "$API_KEY_1"
  - "$API_KEY_2"

remote-management:
  allow-remote: true
  secret-key: "$ADMIN_SECRET_ESCAPED"
  disable-control-panel: false
  panel-github-repository: "https://github.com/router-for-me/Cli-Proxy-API-Management-Center"

debug: false
logging-to-file: true
logs-max-total-size-mb: 100

commercial-mode: false
usage-statistics-enabled: false

proxy-url: ""
force-model-prefix: false
request-retry: 3
max-retry-interval: 30

quota-exceeded:
  switch-project: true
  switch-preview-model: true

routing:
  strategy: "round-robin"

ws-auth: false

tls:
  enable: false
  cert: ""
  key: ""
YAML_EOF
        chmod 600 "$DOCKER_CONFIG_FILE"
        log_success "配置文件: $DOCKER_CONFIG_FILE"
        log_success "API 密钥已生成并写入配置文件（不会输出到日志）"
    else
        log_info "保留现有配置文件: $DOCKER_CONFIG_FILE"
    fi

    log_step "[3/7] 生成 Docker Compose 配置..."
    cat > "$DOCKER_SERVICE_DIR/docker-compose.yml" <<COMPOSE_EOF
# Managed by HAO
# Service: cliproxyapi
# Release: ${COMMON_VERSION}
services:
  cliproxyapi:
    image: $DOCKER_IMAGE
    container_name: $DOCKER_CONTAINER_NAME
    restart: unless-stopped
    labels:
      io.hao.managed: "true"
      io.hao.service: "cliproxyapi"
      io.hao.release: "${COMMON_VERSION}"
    ports:
      - "127.0.0.1:$CLIPROXY_PORT:$CLIPROXY_PORT"
      # OAuth / Web UI callback helper ports, bound to localhost only.
      - "127.0.0.1:8085:8085"
      - "127.0.0.1:1455:1455"
      - "127.0.0.1:54545:54545"
      - "127.0.0.1:51121:51121"
      - "127.0.0.1:11451:11451"
    environment:
      - TZ=Asia/Shanghai
    volumes:
      - ./config.yaml:/CLIProxyAPI/config.yaml
      - ./auths:/root/.cli-proxy-api
      - ./logs:/CLIProxyAPI/logs
COMPOSE_EOF
    log_success "Docker Compose 配置已生成: $DOCKER_SERVICE_DIR/docker-compose.yml"

    log_step "[4/7] 拉取并启动 Docker 容器..."
    cd "$DOCKER_SERVICE_DIR"
    log_info "正在拉取镜像: $DOCKER_IMAGE"
    if $COMPOSE_CMD pull; then
        log_success "镜像拉取完成"
    else
        log_error "镜像拉取失败，请检查网络连接。"
        exit 1
    fi

    if $COMPOSE_CMD up -d; then
        log_success "容器启动命令已执行"
    else
        log_error "容器启动失败"
        $COMPOSE_CMD logs 2>/dev/null || true
        exit 1
    fi

    echo "$DOCKER_IMAGE" > "$DOCKER_SERVICE_DIR/version.txt"

    sleep 5
    if $COMPOSE_CMD ps 2>/dev/null | grep -q "Up"; then
        log_success "容器运行正常"
    else
        log_warning "容器可能未正常启动，请检查日志"
        $COMPOSE_CMD ps 2>/dev/null || true
    fi

    if [ "$IS_UPGRADE" = false ] && [ -n "$DOMAIN" ]; then
        log_step "[5/7] 配置 SSL 证书..."
        domain_ssl_dir="$SSL_DIR/$DOMAIN"
        if [ "$USE_HTTP_ONLY" = true ]; then
            SSL_TYPE="无 (HTTP 模式)"
            log_info "HTTP 模式，跳过 SSL 证书配置"
        elif [ "$USE_DOMAIN" = true ]; then
            SSL_TYPE=$(apply_ssl_certificate "$DOMAIN" "$domain_ssl_dir" "domain")
        else
            SSL_TYPE=$(apply_ssl_certificate "$DOMAIN" "$domain_ssl_dir" "ip")
        fi

        log_step "[6/7] 配置 Nginx 反向代理..."
        NGINX_SUPPORTS_HTTP3=false
        if detect_nginx_http3; then
            NGINX_SUPPORTS_HTTP3=true
            log_info "检测到 HTTP/3 支持"
        fi

        mkdir -p "$domain_ssl_dir"
        conf_file="$CONF_D/${DOMAIN}.conf"
        existing_domain_conf="$(find_nginx_conf_by_server_name "$DOMAIN" "$CONF_D" || true)"
        if [ -n "$existing_domain_conf" ]; then
            if ! grep -q "CLI-PROXY-API-START" "$existing_domain_conf"; then
                log_error "Nginx server_name 已被其他配置占用: $existing_domain_conf"
                log_error "请为 CliproxyAPI 使用独立域名，避免覆盖其他服务。"
                exit 1
            fi
            conf_file="$existing_domain_conf"
        fi
        conf_backup="$(backup_file_for_write "$conf_file")"

        read -r -d '' LOCATION_BLOCKS <<'LOC_EOF' || true
    #CLI-PROXY-API-START

    # WebSocket
    location /v1/ws {
        proxy_pass http://127.0.0.1:CLIPROXY_PORT_PLACEHOLDER;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }

    # OpenAI SSE - Chat Completions
    location /v1/chat/completions {
        proxy_pass http://127.0.0.1:CLIPROXY_PORT_PLACEHOLDER;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection "";
        proxy_set_header Accept-Encoding "";
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;
        add_header X-Accel-Buffering no always;
        gzip off;
        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
        chunked_transfer_encoding on;
    }

    # 其他 v1 API
    location /v1/ {
        proxy_pass http://127.0.0.1:CLIPROXY_PORT_PLACEHOLDER;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
    }

    # v0 管理接口
    location /v0/ {
        proxy_pass http://127.0.0.1:CLIPROXY_PORT_PLACEHOLDER;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 60;
    }

    # 默认
    location / {
        proxy_pass http://127.0.0.1:CLIPROXY_PORT_PLACEHOLDER;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
    }

    #CLI-PROXY-API-END
LOC_EOF

        if [ "$USE_HTTP_ONLY" = true ]; then
            cat > "$conf_file" <<NGX_HTTP
# Managed by HAO
# Service: cliproxyapi
# Release: ${COMMON_VERSION}
server {
    listen 80;
    server_name $DOMAIN;

    client_max_body_size 100m;
    tcp_nodelay on;

    access_log /var/log/nginx/cliproxyapi_access.log;
    error_log /var/log/nginx/cliproxyapi_error.log warn;

$LOCATION_BLOCKS
}
NGX_HTTP
        elif [ "$NGINX_SUPPORTS_HTTP3" = true ]; then
            cat > "$conf_file" <<NGX_H3
# Managed by HAO
# Service: cliproxyapi
# Release: ${COMMON_VERSION}
server {
    listen 80;
    listen 443 ssl;
    listen 443 quic;
    http2 on;

    server_name $DOMAIN;
    client_max_body_size 100m;
    tcp_nodelay on;

    location /.well-known/acme-challenge/ {
        root /var/www/acme;
    }

    #SSL-START
    #HTTP_TO_HTTPS_START
    set \$isRedcert 1;
    if (\$server_port != 443) { set \$isRedcert 2; }
    if ( \$uri ~ /\.well-known/ ) { set \$isRedcert 1; }
    if (\$isRedcert != 1) { rewrite ^(.*)\$ https://\$host\$1 permanent; }
    #HTTP_TO_HTTPS_END
    ssl_certificate $domain_ssl_dir/fullchain.pem;
    ssl_certificate_key $domain_ssl_dir/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers EECDH+CHACHA20:EECDH+CHACHA20-draft:EECDH+AES128:RSA+AES128:EECDH+AES256:RSA+AES256:EECDH+3DES:RSA+3DES:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_tickets on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header Alt-Svc 'h3=":443"; ma=86400';
    error_page 497 https://\$host\$request_uri;
    #SSL-END

    access_log /var/log/nginx/cliproxyapi_access.log;
    error_log /var/log/nginx/cliproxyapi_error.log warn;

$LOCATION_BLOCKS
}
NGX_H3
        else
            cat > "$conf_file" <<NGX_H2
# Managed by HAO
# Service: cliproxyapi
# Release: ${COMMON_VERSION}
server {
    listen 80;
    listen 443 ssl;
    http2 on;

    server_name $DOMAIN;
    client_max_body_size 100m;
    tcp_nodelay on;

    location /.well-known/acme-challenge/ {
        root /var/www/acme;
    }

    #SSL-START
    #HTTP_TO_HTTPS_START
    set \$isRedcert 1;
    if (\$server_port != 443) { set \$isRedcert 2; }
    if ( \$uri ~ /\.well-known/ ) { set \$isRedcert 1; }
    if (\$isRedcert != 1) { rewrite ^(.*)\$ https://\$host\$1 permanent; }
    #HTTP_TO_HTTPS_END
    ssl_certificate $domain_ssl_dir/fullchain.pem;
    ssl_certificate_key $domain_ssl_dir/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers EECDH+CHACHA20:EECDH+CHACHA20-draft:EECDH+AES128:RSA+AES128:EECDH+AES256:RSA+AES256:EECDH+3DES:RSA+3DES:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_tickets on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    add_header Strict-Transport-Security "max-age=31536000" always;
    error_page 497 https://\$host\$request_uri;
    #SSL-END

    access_log /var/log/nginx/cliproxyapi_access.log;
    error_log /var/log/nginx/cliproxyapi_error.log warn;

$LOCATION_BLOCKS
}
NGX_H2
        fi

        sed -i "s|CLIPROXY_PORT_PLACEHOLDER|$CLIPROXY_PORT|g" "$conf_file"
        log_success "Nginx 配置已生成: $conf_file"

        if nginx -t >/dev/null 2>&1; then
            systemctl reload nginx || true
            log_success "Nginx 已重载"
        else
            log_error "Nginx 配置测试失败"
            nginx -t 2>&1 || true
            restore_file_after_failed_write "$conf_file" "$conf_backup"
            nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
            exit 1
        fi
    else
        log_info "升级模式：保留现有 Nginx / SSL 配置"
    fi

    log_step "[7/7] 生成部署信息..."
    if [ "$USE_HTTP_ONLY" = true ]; then
        protocol="http"
        access_mode_text="HTTP 模式"
    elif [ "$USE_DOMAIN" = true ]; then
        protocol="https"
        access_mode_text="域名模式"
    else
        protocol="https"
        access_mode_text="IP 模式"
    fi
    if [ -n "$DOMAIN" ]; then
        access_url="$protocol://$DOMAIN"
        management_url="$access_url/management.html"
    else
        access_url="未检测到（请查看现有 Nginx 配置）"
        management_url="$access_url"
    fi
    credentials_file="$DOCKER_SERVICE_DIR/hao-credentials.txt"

    {
        echo "================================================"
        echo "       CliproxyAPI Docker Compose 凭据信息 (${COMMON_VERSION})"
        echo "================================================"
        echo "部署时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "部署方式: Docker Compose"
        echo "镜像:     $DOCKER_IMAGE"
        echo "访问模式: $access_mode_text"
        echo "访问地址: $access_url"
        echo "管理界面: $management_url"
        echo ""
        if [ "$IS_UPGRADE" = false ]; then
            echo "[API 密钥]"
            echo "密钥 1:    $API_KEY_1"
            echo "密钥 2:    $API_KEY_2"
            echo ""
            echo "[管理面板]"
            echo "登录密码:  $ADMIN_SECRET"
            echo ""
        else
            echo "[API 密钥]"
            key_index=1
            while IFS= read -r existing_key; do
                echo "密钥 $key_index:    $existing_key"
                ((key_index+=1))
            done < <(extract_yaml_list_values "$DOCKER_CONFIG_FILE" "api-keys")
            [ "$key_index" -eq 1 ] && echo "未检测到；请查看配置文件: $DOCKER_CONFIG_FILE"
            echo ""
            echo "[管理面板]"
            if [ -n "$ADMIN_SECRET" ]; then
                echo "登录密码:  $ADMIN_SECRET"
            else
                echo "未检测到；请查看配置文件: $DOCKER_CONFIG_FILE"
            fi
            echo ""
        fi
        echo "[服务目录]"
        echo "Docker 目录:  $DOCKER_SERVICE_DIR"
        echo "Compose 文件: $DOCKER_SERVICE_DIR/docker-compose.yml"
        echo "配置文件:     $DOCKER_CONFIG_FILE"
        echo "数据目录:     $DOCKER_AUTH_DIR"
        echo "日志目录:     $DOCKER_LOG_DIR"
        echo ""
        echo "[Docker 管理]"
        echo "进入目录:  cd $DOCKER_SERVICE_DIR"
        echo "查看状态:  $COMPOSE_CMD ps"
        echo "查看日志:  $COMPOSE_CMD logs -f cliproxyapi"
        echo "重启服务:  $COMPOSE_CMD restart"
        echo "升级镜像:  $COMPOSE_CMD pull && $COMPOSE_CMD up -d"
        echo ""
        echo "[SSL 证书]"
        echo "类型:      ${SSL_TYPE:-已存在}"
        [ -n "$DOMAIN" ] && echo "证书目录:  $SSL_DIR/$DOMAIN/"
        if [ -n "$backup_dir" ]; then
            echo ""
            echo "[备份]"
            echo "备份目录:  $backup_dir"
        fi
        echo "================================================"
    } | write_credentials_file "$credentials_file"
    log_success "凭据信息已保存: $credentials_file"

    clear 2>/dev/null || true
    printf '%s\n' "================================================"
    printf '%s\n' "       CliproxyAPI Docker Compose 部署完成 (${COMMON_VERSION})"
    printf '%s\n' "================================================"
    printf '访问地址: %s\n' "$access_url"
    printf '管理界面: %s\n' "$management_url"
    printf '凭据文件: %s\n' "$credentials_file"
    printf '%s\n' "请到凭据文件中查看 API 密钥和管理面板密码。"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✅ CliproxyAPI Docker Compose 部署完成！${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "🔐 凭据文件: ${YELLOW}$credentials_file${NC}"
    echo -e "🌐 访问地址: ${GREEN}$access_url${NC}"
    echo -e "📊 服务状态: ${CYAN}cd $DOCKER_SERVICE_DIR && $COMPOSE_CMD ps${NC}"
    echo ""
    log_success "日志已保存: $DEPLOY_LOG_FILE"
}

# ==================== 环境检查 ====================
check_root
setup_logging "cliproxyapi-install"

ensure_commands curl wget tar openssl

DEPLOY_MODE=$(select_deploy_mode)
DEPLOY_MODE_TEXT="Docker Compose"
[ "$DEPLOY_MODE" = "bare" ] && DEPLOY_MODE_TEXT="裸机 Systemd"

if [ "$DEPLOY_MODE" = "docker" ]; then
    if ! command -v docker &> /dev/null \
        || ! systemctl is-active --quiet docker 2>/dev/null \
        || [ -z "$(detect_compose_cmd)" ]; then
        log_error "Docker/Compose 环境未就绪。"
        log_info "请先安装 Docker：进入仓库根目录的 docker/ 目录运行 sudo ./install.sh，或使用根目录 sudo ./install.sh 选择 Docker。"
        log_info "如需跳过 Docker，可设置 HAO_CLIPROXY_MODE=bare 使用裸机安装。"
        exit 1
    fi

    COMPOSE_CMD=$(detect_compose_cmd)
    if [ -z "$COMPOSE_CMD" ]; then
        log_error "未检测到 docker-compose。请安装 docker-compose-plugin。"
        exit 1
    fi
fi

if ! command -v nginx &> /dev/null; then
    log_error "未检测到 Nginx。"
    log_info "请先安装 Nginx：进入仓库根目录的 nginx/ 目录运行 sudo ./install.sh，或使用根目录 sudo ./install.sh 选择 Nginx。"
    exit 1
fi

if ! nginx -t >/dev/null 2>&1 || ! systemctl is-active --quiet nginx 2>/dev/null; then
    log_error "Nginx 未正常运行或配置测试未通过。"
    log_info "请先修复/启动 Nginx 后再运行本脚本：systemctl start nginx && nginx -t"
    exit 1
fi

# ==================== 检测安装状态 ====================
IS_UPGRADE=false
CURRENT_VERSION="none"

if [ "$DEPLOY_MODE" = "docker" ]; then
    if [ -f "$DOCKER_SERVICE_DIR/docker-compose.yml" ]; then
        IS_UPGRADE=true
        CURRENT_VERSION=$(cat "$DOCKER_SERVICE_DIR/version.txt" 2>/dev/null || echo "docker")
    fi
else
    if [ -f "$INSTALL_DIR/version.txt" ]; then
        IS_UPGRADE=true
        CURRENT_VERSION=$(cat "$INSTALL_DIR/version.txt" 2>/dev/null || echo "unknown")
    fi
fi

# 端口检查（仅在全新安装时严格检查）
if [ "$IS_UPGRADE" = false ]; then
    if [ "$DEPLOY_MODE" = "docker" ]; then
        for port in "$CLIPROXY_PORT" 8085 1455 54545 51121 11451; do
            ensure_port_available "$port" "CliproxyAPI Docker"
        done
    else
        ensure_port_available "$CLIPROXY_PORT" "CliproxyAPI"
    fi
fi

# ==================== 欢迎横幅 ====================
clear 2>/dev/null || true
if [ "$IS_UPGRADE" = true ]; then
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}   CliproxyAPI 升级程序 ${COMMON_VERSION}${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    log_info "部署方式: $DEPLOY_MODE_TEXT"
    log_info "检测到已安装版本: v${CURRENT_VERSION}"
    log_warning "即将进入升级模式（保留现有配置）"
    echo ""
    if ! is_noninteractive; then
        read -r -p "按回车键继续，或 Ctrl+C 取消..." _
    fi
else
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}   CliproxyAPI ${DEPLOY_MODE_TEXT} 安装程序 ${COMMON_VERSION}${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
fi

# ==================== 交互输入（仅全新安装） ====================
USE_DOMAIN=true
USE_HTTP_ONLY=false
ADMIN_SECRET=""
API_KEY_1=""
API_KEY_2=""

if [ "$IS_UPGRADE" = false ]; then
    if is_noninteractive; then
        MODE="${HAO_ACCESS_MODE:-domain}"
        DOMAIN="${HAO_DOMAIN:-$(detect_server_ip)}"
        ADMIN_SECRET="${HAO_ADMIN_PASSWORD:-$(generate_password 32)}"
        case "$MODE" in
            domain) USE_DOMAIN=true; USE_HTTP_ONLY=false ;;
            ip)     USE_DOMAIN=false; USE_HTTP_ONLY=false ;;
            http)   USE_DOMAIN=false; USE_HTTP_ONLY=true ;;
        esac
    else
        MODE=$(select_access_mode)

        case "$MODE" in
            domain) USE_DOMAIN=true; USE_HTTP_ONLY=false ;;
            ip)     USE_DOMAIN=false; USE_HTTP_ONLY=false ;;
            http)   USE_DOMAIN=false; USE_HTTP_ONLY=true ;;
        esac

        DOMAIN=$(get_domain_for_mode "$MODE")

        echo ""
        read -r -s -p "请输入管理面板密码（输入不回显）: " ADMIN_SECRET
        echo "" >&2
        if [ -z "$ADMIN_SECRET" ]; then
            log_error "管理面板密码不能为空。"
            exit 1
        fi

        echo ""
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        if [ "$USE_HTTP_ONLY" = true ]; then
            echo -e "${YELLOW}⚠️  HTTP 模式：无 SSL 加密${NC}"
        elif [ "$USE_DOMAIN" = true ]; then
            echo -e "${YELLOW}⚠️  重要提示：请确保域名已解析${NC}"
        else
            echo -e "${YELLOW}⚠️  IP 模式：将使用自签名证书${NC}"
        fi
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "访问地址: ${GREEN}$DOMAIN${NC}"
        echo -e "服务器IP: ${GREEN}$(detect_server_ip)${NC}"
        echo ""
        read -r -p "按回车键继续安装，Ctrl+C 取消..." _
    fi
else
    # 升级模式：从现有配置读取域名
    DOMAIN=""
    EXISTING_CONF=""
    for conf_file in "$CONF_D"/*.conf; do
        if [ -f "$conf_file" ] && grep -q "CLI-PROXY-API-START" "$conf_file" 2>/dev/null; then
            EXISTING_CONF="$conf_file"
            break
        fi
    done

    if [ -n "$EXISTING_CONF" ]; then
        DOMAIN=$(grep "server_name" "$EXISTING_CONF" | head -1 | awk '{print $2}' | sed 's/;//g' || echo "")
        if grep -q "listen 443" "$EXISTING_CONF" 2>/dev/null; then
            USE_HTTP_ONLY=false
        else
            USE_DOMAIN=false
            USE_HTTP_ONLY=true
        fi
        log_info "检测到现有域名: $DOMAIN"
    else
        log_warning "未检测到现有 Nginx 配置，升级后可能需要手动配置"
    fi

    if [ "$DEPLOY_MODE" = "docker" ] && [ -f "$DOCKER_CONFIG_FILE" ]; then
        ADMIN_SECRET=$(grep "secret-key:" "$DOCKER_CONFIG_FILE" | awk '{print $2}' | tr -d '"' || echo "")
    elif [ -f "$CONFIG_DIR/config.yaml" ]; then
        ADMIN_SECRET=$(grep "secret-key:" "$CONFIG_DIR/config.yaml" | awk '{print $2}' | tr -d '"' || echo "")
    fi
fi

if [ "$IS_UPGRADE" = false ]; then
    case "$MODE" in
        domain) validate_domain "$DOMAIN" || exit 1 ;;
        ip|http) validate_ip "$DOMAIN" || exit 1 ;;
        *) log_error "未知访问模式: $MODE"; exit 1 ;;
    esac

    PREEXISTING_CONF="$(find_nginx_conf_by_server_name "$DOMAIN" "$CONF_D" || true)"
    if [ -n "$PREEXISTING_CONF" ] && ! grep -q "CLI-PROXY-API-START" "$PREEXISTING_CONF"; then
        log_error "Nginx server_name 已被其他配置占用: $PREEXISTING_CONF"
        log_error "请为 CliproxyAPI 使用独立域名，避免覆盖其他服务。"
        exit 1
    fi
fi

if [ "$DEPLOY_MODE" = "docker" ]; then
    run_docker_deploy
    exit 0
fi

# ==================== 检测系统架构 ====================
echo ""
log_step "[1/7] 检测系统架构..."

ARCH=$(detect_arch)
if [ "$ARCH" = "unknown" ]; then
    log_error "不支持的系统架构: $(uname -m)"
    exit 1
fi
log_success "架构: $ARCH"

# ==================== 获取最新版本 ====================
log_step "[2/7] 获取最新版本信息..."

RELEASE_INFO=$(curl -s --connect-timeout 15 "$GITHUB_API") || true

if [ -z "$RELEASE_INFO" ]; then
    log_error "无法获取版本信息，请检查网络连接。"
    exit 1
fi

LATEST_VERSION=$(echo "$RELEASE_INFO" | grep -o '"tag_name": *"[^"]*"' | cut -d'"' -f4 | sed 's/^v//') || true

if [ -z "$LATEST_VERSION" ]; then
    log_error "无法解析版本号。"
    exit 1
fi

log_success "最新版本: v$LATEST_VERSION"

if [ "$IS_UPGRADE" = true ] && [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
    log_success "已是最新版本 (v$LATEST_VERSION)，无需升级。"
    exit 0
fi

# ==================== 备份（仅升级模式） ====================
BACKUP_DIR=""
SERVICE_WAS_RUNNING=false

if [ "$IS_UPGRADE" = true ]; then
    log_step "[3/7] 备份现有配置..."

    BACKUP_DIR="${INSTALL_DIR}/backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"

    [ -f "$CONFIG_DIR/config.yaml" ] && cp -a "$CONFIG_DIR/config.yaml" "$BACKUP_DIR/config.yaml" && log_success "✓ 已备份配置文件"
    [ -d "$DATA_DIR" ] && cp -a "$DATA_DIR" "$BACKUP_DIR/data" && log_success "✓ 已备份数据目录"
    [ -f "$INSTALL_DIR/cli-proxy-api" ] && cp -a "$INSTALL_DIR/cli-proxy-api" "$BACKUP_DIR/cli-proxy-api.bak" && log_success "✓ 已备份可执行文件"

    log_success "备份完成: $BACKUP_DIR"

    if systemctl is-active --quiet cliproxyapi 2>/dev/null; then
        SERVICE_WAS_RUNNING=true
        systemctl stop cliproxyapi
        log_success "服务已停止"
    fi
    sleep 2
fi

# ==================== 下载并安装 ====================
STEP_NUM=$([ "$IS_UPGRADE" = true ] && echo "4" || echo "3")
log_step "[${STEP_NUM}/7] 下载并安装 CliproxyAPI..."

EXPECTED_FILENAME="CLIProxyAPI_${LATEST_VERSION}_${ARCH}.tar.gz"
DOWNLOAD_URL=$(echo "$RELEASE_INFO" | grep -o "\"browser_download_url\": *\"[^\"]*${EXPECTED_FILENAME}[^\"]*\"" | cut -d'"' -f4) || true

if [ -z "$DOWNLOAD_URL" ]; then
    log_error "无法找到架构 ${ARCH} 的下载地址。"
    [ "$IS_UPGRADE" = true ] && exit 1 || exit 1
fi

TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"

log_info "下载: $EXPECTED_FILENAME"
if ! curl -L --connect-timeout 120 -o "cli-proxy-api.tar.gz" "$DOWNLOAD_URL"; then
    log_error "下载失败，请检查网络连接。"
    rm -rf "$TMP_DIR"
    exit 1
fi

log_success "下载完成"
tar -xzf "cli-proxy-api.tar.gz"

mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$DATA_DIR/storage" "$DATA_DIR/auth" "$LOG_DIR"

BINARY_FILE=$(find . -name "cli-proxy-api" -type f | head -1)
if [ -z "$BINARY_FILE" ]; then
    log_error "解压后未找到可执行文件。"
    rm -rf "$TMP_DIR"
    exit 1
fi

mv "$BINARY_FILE" "$INSTALL_DIR/cli-proxy-api"
chmod +x "$INSTALL_DIR/cli-proxy-api"
echo "$LATEST_VERSION" > "$INSTALL_DIR/version.txt"

log_success "安装完成: $INSTALL_DIR/cli-proxy-api"
cd / && rm -rf "$TMP_DIR"

# ==================== 配置文件处理 ====================
STEP_NUM=$([ "$IS_UPGRADE" = true ] && echo "5" || echo "4")
log_step "[${STEP_NUM}/7] 配置文件处理..."

if [ "$IS_UPGRADE" = true ]; then
    if [ -f "$BACKUP_DIR/config.yaml" ]; then
        cp -a "$BACKUP_DIR/config.yaml" "$CONFIG_DIR/config.yaml"
        chmod 600 "$CONFIG_DIR/config.yaml"
        log_success "配置文件已恢复（保留所有设置）"
    else
        log_warning "备份配置不存在，保持现有配置"
        [ -f "$CONFIG_DIR/config.yaml" ] && chmod 600 "$CONFIG_DIR/config.yaml"
    fi
else
    # 使用安全的密钥生成
    API_KEY_1=$(generate_api_key "sk-")
    API_KEY_2=$(generate_api_key "sk-")
    ADMIN_SECRET_ESCAPED=$(escape_double_quoted "$ADMIN_SECRET")

    # 含 API 密钥与管理密码，落盘前先以 600 权限建档，避免出现可读窗口
    install -m 600 /dev/null "$CONFIG_DIR/config.yaml"
    cat > "$CONFIG_DIR/config.yaml" <<YAML_EOF
# CliproxyAPI Configuration File
# Auto-generated by install script ${COMMON_VERSION}

# ==================== Server Configuration ====================
host: "127.0.0.1"
port: $CLIPROXY_PORT

# ==================== Authentication ====================
auth-dir: "$DATA_DIR/auth"

# API keys for client authentication
api-keys:
  - "$API_KEY_1"
  - "$API_KEY_2"

# ==================== Management Panel ====================
remote-management:
  allow-remote: true
  secret-key: "$ADMIN_SECRET_ESCAPED"
  disable-control-panel: false
  panel-github-repository: "https://github.com/router-for-me/Cli-Proxy-API-Management-Center"

# ==================== Logging ====================
debug: false
logging-to-file: true
logs-max-total-size-mb: 100

# ==================== Performance ====================
commercial-mode: false
usage-statistics-enabled: false

# ==================== Request Handling ====================
proxy-url: ""
force-model-prefix: false
request-retry: 3
max-retry-interval: 30

quota-exceeded:
  switch-project: true
  switch-preview-model: true

routing:
  strategy: "round-robin"

ws-auth: false

# ==================== TLS ====================
# TLS is handled by Nginx, keep disabled
tls:
  enable: false
  cert: ""
  key: ""
YAML_EOF

    log_success "配置文件: $CONFIG_DIR/config.yaml"
    log_success "API 密钥已生成并写入配置文件（不会输出到日志）"
fi

# ==================== SSL 证书处理 ====================
if [ "$IS_UPGRADE" = false ] && [ -n "$DOMAIN" ]; then
    STEP_NUM=$([ "$IS_UPGRADE" = true ] && echo "6" || echo "5")
    log_step "[${STEP_NUM}/7] 配置 SSL 证书..."

    DOMAIN_SSL_DIR="$SSL_DIR/$DOMAIN"

    if [ "$USE_HTTP_ONLY" = true ]; then
        SSL_TYPE="无 (HTTP 模式)"
        log_info "HTTP 模式，跳过 SSL 证书配置"
    elif [ "$USE_DOMAIN" = true ]; then
        SSL_TYPE=$(apply_ssl_certificate "$DOMAIN" "$DOMAIN_SSL_DIR" "domain")
    else
        SSL_TYPE=$(apply_ssl_certificate "$DOMAIN" "$DOMAIN_SSL_DIR" "ip")
    fi
fi

# ==================== Nginx 配置（仅全新安装） ====================
if [ "$IS_UPGRADE" = false ] && [ -n "$DOMAIN" ]; then
    STEP_NUM=$([ "$IS_UPGRADE" = true ] && echo "7" || echo "6")
    log_step "[${STEP_NUM}/7] 配置 Nginx 反向代理..."

    NGINX_SUPPORTS_HTTP3=false
    if detect_nginx_http3; then
        NGINX_SUPPORTS_HTTP3=true
        log_info "检测到 HTTP/3 支持"
    fi

    DOMAIN_SSL_DIR="$SSL_DIR/$DOMAIN"
    mkdir -p "$DOMAIN_SSL_DIR"

    # 公共 location 块（所有模式共用）
    read -r -d '' LOCATION_BLOCKS <<'LOC_EOF' || true
    #CLI-PROXY-API-START

    # WebSocket
    location /v1/ws {
        proxy_pass http://127.0.0.1:CLIPROXY_PORT_PLACEHOLDER;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }

    # OpenAI SSE - Chat Completions
    location /v1/chat/completions {
        proxy_pass http://127.0.0.1:CLIPROXY_PORT_PLACEHOLDER;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection "";
        proxy_set_header Accept-Encoding "";
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;
        add_header X-Accel-Buffering no always;
        gzip off;
        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
        chunked_transfer_encoding on;
    }

    # 其他 v1 API
    location /v1/ {
        proxy_pass http://127.0.0.1:CLIPROXY_PORT_PLACEHOLDER;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
    }

    # v0 管理接口
    location /v0/ {
        proxy_pass http://127.0.0.1:CLIPROXY_PORT_PLACEHOLDER;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 60;
    }

    # 默认
    location / {
        proxy_pass http://127.0.0.1:CLIPROXY_PORT_PLACEHOLDER;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
    }

    #CLI-PROXY-API-END
LOC_EOF

    # 生成 Nginx 配置
    CONF_FILE="$CONF_D/${DOMAIN}.conf"

    EXISTING_DOMAIN_CONF="$(find_nginx_conf_by_server_name "$DOMAIN" "$CONF_D" || true)"
    if [ -n "$EXISTING_DOMAIN_CONF" ]; then
        if ! grep -q "CLI-PROXY-API-START" "$EXISTING_DOMAIN_CONF"; then
            log_error "Nginx server_name 已被其他配置占用: $EXISTING_DOMAIN_CONF"
            log_error "请为 CliproxyAPI 使用独立域名，避免覆盖其他服务。"
            exit 1
        fi
        CONF_FILE="$EXISTING_DOMAIN_CONF"
    fi
    CONF_BACKUP="$(backup_file_for_write "$CONF_FILE")"

    if [ "$USE_HTTP_ONLY" = true ]; then
        # HTTP 模式
        cat > "$CONF_FILE" <<NGX_HTTP
# Managed by HAO
# Service: cliproxyapi
# Release: ${COMMON_VERSION}
server {
    listen 80;
    server_name $DOMAIN;

    client_max_body_size 100m;
    tcp_nodelay on;

    access_log /var/log/nginx/cliproxyapi_access.log;
    error_log /var/log/nginx/cliproxyapi_error.log warn;

$LOCATION_BLOCKS
}
NGX_HTTP
    elif [ "$NGINX_SUPPORTS_HTTP3" = true ]; then
        # HTTP/3 模式
        cat > "$CONF_FILE" <<NGX_H3
# Managed by HAO
# Service: cliproxyapi
# Release: ${COMMON_VERSION}
server {
    listen 80;
    listen 443 ssl;
    listen 443 quic;
    http2 on;

    server_name $DOMAIN;
    client_max_body_size 100m;
    tcp_nodelay on;

    location /.well-known/acme-challenge/ {
        root /var/www/acme;
    }

    #SSL-START
    #HTTP_TO_HTTPS_START
    set \$isRedcert 1;
    if (\$server_port != 443) { set \$isRedcert 2; }
    if ( \$uri ~ /\.well-known/ ) { set \$isRedcert 1; }
    if (\$isRedcert != 1) { rewrite ^(.*)\$ https://\$host\$1 permanent; }
    #HTTP_TO_HTTPS_END
    ssl_certificate $DOMAIN_SSL_DIR/fullchain.pem;
    ssl_certificate_key $DOMAIN_SSL_DIR/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers EECDH+CHACHA20:EECDH+CHACHA20-draft:EECDH+AES128:RSA+AES128:EECDH+AES256:RSA+AES256:EECDH+3DES:RSA+3DES:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_tickets on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header Alt-Svc 'h3=":443"; ma=86400';
    error_page 497 https://\$host\$request_uri;
    #SSL-END

    access_log /var/log/nginx/cliproxyapi_access.log;
    error_log /var/log/nginx/cliproxyapi_error.log warn;

$LOCATION_BLOCKS
}
NGX_H3
    else
        # HTTP/2 模式
        cat > "$CONF_FILE" <<NGX_H2
# Managed by HAO
# Service: cliproxyapi
# Release: ${COMMON_VERSION}
server {
    listen 80;
    listen 443 ssl;
    http2 on;

    server_name $DOMAIN;
    client_max_body_size 100m;
    tcp_nodelay on;

    location /.well-known/acme-challenge/ {
        root /var/www/acme;
    }

    #SSL-START
    #HTTP_TO_HTTPS_START
    set \$isRedcert 1;
    if (\$server_port != 443) { set \$isRedcert 2; }
    if ( \$uri ~ /\.well-known/ ) { set \$isRedcert 1; }
    if (\$isRedcert != 1) { rewrite ^(.*)\$ https://\$host\$1 permanent; }
    #HTTP_TO_HTTPS_END
    ssl_certificate $DOMAIN_SSL_DIR/fullchain.pem;
    ssl_certificate_key $DOMAIN_SSL_DIR/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers EECDH+CHACHA20:EECDH+CHACHA20-draft:EECDH+AES128:RSA+AES128:EECDH+AES256:RSA+AES256:EECDH+3DES:RSA+3DES:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_tickets on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    add_header Strict-Transport-Security "max-age=31536000" always;
    error_page 497 https://\$host\$request_uri;
    #SSL-END

    access_log /var/log/nginx/cliproxyapi_access.log;
    error_log /var/log/nginx/cliproxyapi_error.log warn;

$LOCATION_BLOCKS
}
NGX_H2
    fi

    # 替换占位符
    sed -i "s|CLIPROXY_PORT_PLACEHOLDER|$CLIPROXY_PORT|g" "$CONF_FILE"

    log_success "Nginx 配置已生成: $CONF_FILE"

    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx || true
        log_success "Nginx 已重载"
    else
        log_error "Nginx 配置测试失败"
        nginx -t 2>&1 || true
        restore_file_after_failed_write "$CONF_FILE" "$CONF_BACKUP"
        nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
        exit 1
    fi
fi

# ==================== Systemd 服务 ====================
log_step "[7/7] 配置 Systemd 服务..."

cat > /etc/systemd/system/cliproxyapi.service <<SVC_EOF
# Managed by HAO
# Service: cliproxyapi
# Release: ${COMMON_VERSION}
[Unit]
Description=CLIProxyAPI Service
Documentation=https://help.router-for.me/cn/
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/cli-proxy-api -config $CONFIG_DIR/config.yaml
Restart=always
RestartSec=10s

Environment="HOME=/root"

NoNewPrivileges=true
PrivateTmp=true

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVC_EOF

systemctl daemon-reload
systemctl enable cliproxyapi >/dev/null 2>&1

if [ "$IS_UPGRADE" = true ] && [ "$SERVICE_WAS_RUNNING" = true ]; then
    systemctl start cliproxyapi || true
elif [ "$IS_UPGRADE" = false ]; then
    systemctl start cliproxyapi || true
fi

sleep 2

if systemctl is-active --quiet cliproxyapi; then
    log_success "服务已启动"
else
    log_warning "服务启动失败，请检查: journalctl -u cliproxyapi -n 50"
fi

# ==================== 完成信息 ====================
SERVER_IP=$(detect_server_ip)

clear 2>/dev/null || true
echo -e "${GREEN}"
if [ "$IS_UPGRADE" = true ]; then
    CREDENTIALS_FILE="$INSTALL_DIR/hao-credentials.txt"
    if [ -f "$CONFIG_DIR/config.yaml" ]; then
        {
            echo "================================================"
            echo "       CliproxyAPI 裸机 Systemd 凭据信息 (${COMMON_VERSION})"
            echo "================================================"
            echo "更新时间: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "部署方式: 裸机 Systemd"
            echo "旧版本:    v$CURRENT_VERSION"
            echo "新版本:    v$LATEST_VERSION"
            echo ""
            echo "[API 密钥]"
            key_index=1
            while IFS= read -r existing_key; do
                echo "密钥 $key_index:    $existing_key"
                ((key_index+=1))
            done < <(extract_yaml_list_values "$CONFIG_DIR/config.yaml" "api-keys")
            [ "$key_index" -eq 1 ] && echo "未检测到；请查看配置文件: $CONFIG_DIR/config.yaml"
            echo ""
            echo "[管理面板]"
            if [ -n "$ADMIN_SECRET" ]; then
                echo "登录密码:  $ADMIN_SECRET"
            else
                echo "未检测到；请查看配置文件: $CONFIG_DIR/config.yaml"
            fi
            echo ""
            echo "[配置信息]"
            echo "配置文件:  $CONFIG_DIR/config.yaml"
            echo "数据目录:  $DATA_DIR"
            echo "备份位置:  $BACKUP_DIR"
            echo "================================================"
        } | write_credentials_file "$CREDENTIALS_FILE"
        log_success "凭据信息已保存: $CREDENTIALS_FILE"
    fi

    cat <<EOF
================================================
       CliproxyAPI 升级成功！(${COMMON_VERSION})
================================================
EOF
    echo -e "${NC}"
    echo -e "旧版本:     ${YELLOW}v${CURRENT_VERSION}${NC}"
    echo -e "新版本:     ${GREEN}v${LATEST_VERSION}${NC}"
    echo ""
    echo -e "${CYAN}[配置保留]${NC}"
    echo -e "配置文件:   已保留"
    echo -e "数据目录:   已保留"
    echo -e "凭据文件:   $CREDENTIALS_FILE"
    echo -e "备份位置:   $BACKUP_DIR"
else
    if [ "$USE_HTTP_ONLY" = true ]; then
        PROTOCOL="http"
        ACCESS_MODE_TEXT="HTTP 模式"
    elif [ "$USE_DOMAIN" = true ]; then
        PROTOCOL="https"
        ACCESS_MODE_TEXT="域名模式"
    else
        PROTOCOL="https"
        ACCESS_MODE_TEXT="IP 模式"
    fi

    CREDENTIALS_FILE="$INSTALL_DIR/hao-credentials.txt"
    {
        echo "================================================"
        echo "       CliproxyAPI 裸机 Systemd 凭据信息 (${COMMON_VERSION})"
        echo "================================================"
        echo "部署时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "部署方式: 裸机 Systemd"
        echo "版本:      v$LATEST_VERSION"
        echo "访问模式:  $ACCESS_MODE_TEXT"
        echo "服务器 IP: $SERVER_IP"
        echo "访问地址:  ${PROTOCOL}://$DOMAIN"
        echo "管理界面:  ${PROTOCOL}://$DOMAIN/management.html"
        echo ""
        echo "[API 密钥]"
        echo "密钥 1:    $API_KEY_1"
        echo "密钥 2:    $API_KEY_2"
        echo ""
        echo "[管理面板]"
        echo "登录密码:  $ADMIN_SECRET"
        echo ""
        echo "[配置信息]"
        echo "配置文件:  $CONFIG_DIR/config.yaml"
        echo "数据目录:  $DATA_DIR"
        echo "日志文件:  $LOG_DIR/cliproxyapi.log"
        echo ""
        echo "[SSL 证书]"
        echo "类型:      ${SSL_TYPE:-已存在}"
        [ -n "$DOMAIN" ] && echo "证书目录:  $SSL_DIR/$DOMAIN/"
        echo "================================================"
    } | write_credentials_file "$CREDENTIALS_FILE"
    log_success "凭据信息已保存: $CREDENTIALS_FILE"

    cat <<EOF
================================================
       CliproxyAPI 安装成功！(${COMMON_VERSION})
================================================
访问模式:  $ACCESS_MODE_TEXT
服务器 IP: $SERVER_IP
访问地址:  $DOMAIN

[访问地址]
$( [ "$USE_HTTP_ONLY" = true ] && echo "HTTP:      http://$DOMAIN" || echo "HTTPS:     https://$DOMAIN" )
管理界面:  ${PROTOCOL}://$DOMAIN/management.html
$( [ "$USE_HTTP_ONLY" = true ] && echo "
⚠️  HTTP 模式注意事项:
- 数据传输不加密，API Key 可能泄露
- 仅建议在内网或开发环境使用" )
$( [ "$USE_HTTP_ONLY" = false ] && [ "$USE_DOMAIN" = false ] && echo "
⚠️  IP 模式注意事项:
- 浏览器会提示证书不安全，请点击「高级」→「继续访问」
- API 客户端需要关闭 SSL 验证或信任自签名证书" )

[凭据信息]
凭据文件:  $CREDENTIALS_FILE
请到凭据文件中查看 API 密钥和管理面板密码。

[配置信息]
版本:      v$LATEST_VERSION
配置文件:  $CONFIG_DIR/config.yaml
数据目录:  $DATA_DIR
日志文件:  $LOG_DIR/cliproxyapi.log

[SSL 证书]
类型:      ${SSL_TYPE:-已存在}
EOF
fi

echo ""
echo -e "${CYAN}[服务管理]${NC}"
echo "查看状态:  systemctl status cliproxyapi"
echo "启动服务:  systemctl start cliproxyapi"
echo "停止服务:  systemctl stop cliproxyapi"
echo "重启服务:  systemctl restart cliproxyapi"
echo "查看日志:  journalctl -u cliproxyapi -f"
echo ""
echo -e "${GREEN}安装完成！${NC}"
echo "================================================"
echo ""
log_success "日志已保存: $DEPLOY_LOG_FILE"
