#!/bin/bash
# shellcheck disable=SC2034

################################################################################
#
# New-API Docker 部署脚本
# 发布标识由 HAO_RELEASE 提供
#
# 功能说明：
#   1. 部署 New-API AI 模型聚合管理系统（Docker 方式）
#   2. 自动配置 PostgreSQL / MySQL 数据库
#   3. 自动配置 Redis 缓存
#   4. 自动申请 SSL 证书 / 自签名证书
#   5. 自动配置 Nginx 反向代理
#   6. 生成安全随机密码并保存到凭据文件
#
# 用法:
#   ./install.sh        # 交互式部署
#   ./install.sh -h     # 显示帮助
#
# 前置条件：
#   - Docker 和 Docker Compose 已安装（可通过 ../docker/install.sh）
#   - Nginx 已安装（可通过 ../nginx/install.sh）
#   - 域名需已解析到本服务器
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
New-API Docker 部署脚本

用法:
  ./install.sh       # 首次部署；已有部署默认 no-op
  HAO_NEWAPI_ACTION=upgrade ./install.sh  # 显式同数据库引擎升级
  ./install.sh -h    # 显示此帮助

功能:
  - Docker Compose 部署 (New-API + PostgreSQL/MySQL + Redis)
  - 支持域名/IP/HTTP 三种访问模式
  - 自动申请 Let's Encrypt 证书
  - Nginx 反向代理 + HTTP/3 支持
  - upgrade 复用现有密钥；migrate-db 不执行自动跨引擎迁移

前置条件:
  - 已安装 Docker (../docker/install.sh)
  - 已安装 Nginx (../nginx/install.sh)
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
NEWAPI_PORT="${HAO_NEWAPI_PORT:-3000}"
CONF_D="${HAO_NGINX_CONF_DIR:-/etc/nginx/conf.d}"
SSL_DIR="${HAO_NGINX_SSL_DIR:-/etc/nginx/ssl}"
DOCKER_ROOT="${HAO_DOCKER_ROOT:-/opt/docker-services}"
SERVICE_DIR="$DOCKER_ROOT/new-api"
DATA_DIR="$SERVICE_DIR/data"
LOGS_DIR="$SERVICE_DIR/logs"
DOCKER_IMAGE="${HAO_NEWAPI_IMAGE:-calciumion/new-api:latest}"
DOCKER_NETWORK="${HAO_DOCKER_NETWORK:-ai-services}"
NEWAPI_ACTION="${HAO_NEWAPI_ACTION:-ensure}"
EXISTING_COMPOSE="$SERVICE_DIR/docker-compose.yml"

normalize_newapi_action() {
    case "${1,,}" in
        ensure|install) echo "ensure" ;;
        upgrade) echo "upgrade" ;;
        migrate-db|migrate|database-migration) echo "migrate-db" ;;
        *)
            log_error "HAO_NEWAPI_ACTION 只能是 ensure、upgrade 或 migrate-db，当前: $1"
            return 1
            ;;
    esac
}

detect_existing_db_type() {
    local compose_file="$1"
    if grep -qE '^[[:space:]]+postgres:' "$compose_file" 2>/dev/null; then
        echo "postgresql"
    elif grep -qE '^[[:space:]]+mysql:' "$compose_file" 2>/dev/null; then
        echo "mysql"
    else
        echo "unknown"
    fi
}

extract_existing_secrets() {
    local compose_file="$1"

    if [ "$EXISTING_DB_TYPE" = "postgresql" ]; then
        DB_PASSWORD="$(sed -n 's|.*SQL_DSN=postgresql://newapi:\([^@]*\)@postgres:.*|\1|p' "$compose_file" | head -1)"
    else
        DB_PASSWORD="$(sed -n 's|.*SQL_DSN=newapi:\([^@]*\)@tcp(mysql:.*|\1|p' "$compose_file" | head -1)"
    fi
    REDIS_PASSWORD="$(sed -n 's|.*REDIS_CONN_STRING=redis://:\([^@]*\)@redis:.*|\1|p' "$compose_file" | head -1)"
    SESSION_SECRET="$(sed -n 's|.*SESSION_SECRET=\(.*\)$|\1|p' "$compose_file" | head -1)"

    if [ -z "$DB_PASSWORD" ] || [ -z "$REDIS_PASSWORD" ] || [ -z "$SESSION_SECRET" ]; then
        log_error "无法从现有 Compose 安全恢复全部密钥，已拒绝升级以避免凭据轮换。"
        log_info "请检查: $compose_file"
        return 1
    fi
}

NEWAPI_ACTION="$(normalize_newapi_action "$NEWAPI_ACTION")" || exit 1
EXISTING_DB_TYPE="unknown"
if [ -f "$EXISTING_COMPOSE" ]; then
    EXISTING_DB_TYPE="$(detect_existing_db_type "$EXISTING_COMPOSE")"
    case "$NEWAPI_ACTION" in
        ensure)
            echo "New-API 已部署；默认 ensure 动作为 no-op。"
            echo "如需刷新镜像/配置，请显式设置 HAO_NEWAPI_ACTION=upgrade。"
            exit 0
            ;;
        migrate-db)
            log_error "HAO 不自动执行 PostgreSQL/MySQL 跨引擎数据迁移。"
            log_info "请先完成独立备份、迁移和回滚方案，再由专用迁移流程处理；当前部署未改变。"
            exit 1
            ;;
        upgrade) ;;
    esac
elif [ "$NEWAPI_ACTION" != "ensure" ]; then
    log_error "New-API 尚未部署，不能执行 $NEWAPI_ACTION；请使用 ensure 完成首次安装。"
    exit 1
fi

# ==================== 环境检查 ====================
check_root
setup_logging "newapi-install"

ensure_commands curl wget openssl

if ! command -v docker &> /dev/null \
    || ! systemctl is-active --quiet docker 2>/dev/null \
    || [ -z "$(detect_compose_cmd)" ]; then
    log_error "Docker/Compose 环境未就绪。"
    log_info "请先安装 Docker：进入仓库根目录的 docker/ 目录运行 sudo ./install.sh，或使用根目录 sudo ./install.sh 选择 Docker。"
    exit 1
fi

COMPOSE_CMD=$(detect_compose_cmd)
if [ -z "$COMPOSE_CMD" ]; then
    log_error "未检测到 docker-compose。请安装: apt-get install docker-compose-plugin"
    exit 1
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

# 端口检查（覆盖安装时允许现有 New-API 占用端口）
if [ ! -f "$SERVICE_DIR/docker-compose.yml" ]; then
    ensure_port_available "$NEWAPI_PORT" "New-API"
fi

# ==================== 欢迎 ====================
clear 2>/dev/null || true
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}   New-API Docker 部署程序 ${COMMON_VERSION}${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [ -f "$EXISTING_COMPOSE" ]; then
    log_warning "检测到已安装 New-API；本次为显式 upgrade。"
fi

# ==================== 交互输入 ====================
log_step "[1/8] 请输入配置信息"
echo ""

if is_noninteractive; then
    MODE="${HAO_ACCESS_MODE:-domain}"
    DOMAIN="${HAO_DOMAIN:-$(detect_server_ip)}"
    DB_CHOICE="${HAO_DB_TYPE:-postgresql}"
    case "$DB_CHOICE" in
        mysql|MySQL) DB_CHOICE=2 ;;
        *)           DB_CHOICE=1 ;;
    esac
    USE_DOMAIN=false
    USE_HTTP_ONLY=false
    case "$MODE" in
        domain) USE_DOMAIN=true ;;
        http)   USE_HTTP_ONLY=true ;;
    esac
else
    MODE=$(select_access_mode)

    USE_DOMAIN=false
    USE_HTTP_ONLY=false
    case "$MODE" in
        domain) USE_DOMAIN=true ;;
        http)   USE_HTTP_ONLY=true ;;
    esac

    DOMAIN=$(get_domain_for_mode "$MODE")
fi

SERVER_IP=$(detect_server_ip)

case "$MODE" in
    domain) validate_domain "$DOMAIN" || exit 1 ;;
    ip|http) validate_ip "$DOMAIN" || exit 1 ;;
    *) log_error "未知访问模式: $MODE"; exit 1 ;;
esac

PREEXISTING_CONF="$(find_nginx_conf_by_server_name "$DOMAIN" "$CONF_D" || true)"
if [ -n "$PREEXISTING_CONF" ] && ! grep -q "NEW-API-START" "$PREEXISTING_CONF"; then
    log_error "Nginx server_name 已被其他配置占用: $PREEXISTING_CONF"
    log_error "请为 New-API 使用独立域名，避免覆盖其他服务。"
    exit 1
fi

echo ""

# 数据库类型选择
USE_POSTGRESQL=true
DB_TYPE="PostgreSQL"
DB_IMAGE="postgres:15"
if is_noninteractive; then
    case "$DB_CHOICE" in
        2)
            USE_POSTGRESQL=false
            DB_TYPE="MySQL"
            DB_IMAGE="mysql:8.2"
            ;;
    esac
else
    echo -e "${CYAN}选择数据库类型:${NC}"
    echo "  1) PostgreSQL 15 (推荐)"
    echo "  2) MySQL 8.2"
    read -r -p "请选择 [1-2, 默认 1]: " DB_CHOICE
    case "$DB_CHOICE" in
        2)
            USE_POSTGRESQL=false
            DB_TYPE="MySQL"
            DB_IMAGE="mysql:8.2"
            ;;
    esac
fi

log_info "已选择: $DB_TYPE"
echo ""

# 首次安装生成密钥；显式升级必须复用现有密钥。
REQUESTED_DB_TYPE="$([ "$USE_POSTGRESQL" = true ] && echo postgresql || echo mysql)"
if [ "$NEWAPI_ACTION" = "upgrade" ]; then
    if [ "$EXISTING_DB_TYPE" = "unknown" ]; then
        log_error "无法识别现有数据库类型，已拒绝升级。"
        exit 1
    fi
    if [ "$REQUESTED_DB_TYPE" != "$EXISTING_DB_TYPE" ]; then
        log_error "升级不能把数据库从 $EXISTING_DB_TYPE 改为 $REQUESTED_DB_TYPE。"
        log_info "数据库迁移必须使用独立、显式且可回滚的迁移流程；当前部署未改变。"
        exit 1
    fi
    extract_existing_secrets "$EXISTING_COMPOSE" || exit 1
    log_success "已复用现有数据库、Redis 和 Session 密钥（值不会输出到日志）"
else
    log_info "正在生成安全随机密码..."
    DB_PASSWORD=$(generate_password 32)
    REDIS_PASSWORD=$(generate_password 32)
    SESSION_SECRET=$(generate_session_secret 48)
    log_success "密码已生成（将保存到凭据文件，不会输出到日志）"
fi
echo ""

# 确认
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [ "$USE_DOMAIN" = true ]; then
    echo -e "${YELLOW}⚠️  请确保域名已解析:${NC}"
    echo -e "域名:   ${GREEN}$DOMAIN${NC}"
    echo -e "目标IP: ${GREEN}$SERVER_IP${NC}"
elif [ "$USE_HTTP_ONLY" = true ]; then
    echo -e "${YELLOW}⚠️  HTTP 模式: 数据不加密${NC}"
    echo -e "访问地址: ${GREEN}http://$DOMAIN${NC}"
else
    echo -e "${YELLOW}⚠️  IP 模式: 将使用自签名证书${NC}"
    echo -e "访问地址: ${GREEN}https://$DOMAIN${NC}"
fi
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
if ! is_noninteractive; then
    read -r -p "按回车键继续部署..." _
fi

# ==================== 创建目录 ====================
log_step "[2/8] 创建目录结构..."

mkdir -p "$DOCKER_ROOT" "$SERVICE_DIR" "$DATA_DIR/postgres" "$DATA_DIR/redis" "$LOGS_DIR"
log_success "目录创建完成"

# ==================== 生成 docker-compose.yml ====================
log_step "[3/8] 生成 Docker Compose 配置..."

if [ "$NEWAPI_ACTION" = "upgrade" ]; then
    backup_file "$EXISTING_COMPOSE"
fi

# compose 内嵌数据库/Redis 密码与 SESSION_SECRET，落盘前先以 600 权限建档，避免出现可读窗口
install -m 600 /dev/null "$SERVICE_DIR/docker-compose.yml"

if [ "$USE_POSTGRESQL" = true ]; then
    cat > "$SERVICE_DIR/docker-compose.yml" <<COMPOSE_EOF
# Managed by HAO
# Service: new-api
# Release: ${COMMON_VERSION}
version: '3.8'

services:
  new-api:
    image: $DOCKER_IMAGE
    container_name: new-api
    restart: always
    labels:
      io.hao.managed: "true"
      io.hao.service: "new-api"
      io.hao.release: "${COMMON_VERSION}"
    ports:
      - "127.0.0.1:$NEWAPI_PORT:3000"
    volumes:
      - ./data:/data
      - ./logs:/app/logs
    environment:
      - SQL_DSN=postgresql://newapi:$DB_PASSWORD@postgres:5432/newapi
      - REDIS_CONN_STRING=redis://:$REDIS_PASSWORD@redis:6379
      - SESSION_SECRET=$SESSION_SECRET
      - TZ=Asia/Shanghai
      - ERROR_LOG_ENABLED=true
      - BATCH_UPDATE_ENABLED=true
      - STREAMING_TIMEOUT=300
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_started
    networks:
      - $DOCKER_NETWORK
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:3000/api/status >/dev/null 2>&1 || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

  postgres:
    image: $DB_IMAGE
    container_name: newapi-postgres
    restart: always
    environment:
      POSTGRES_USER: newapi
      POSTGRES_PASSWORD: $DB_PASSWORD
      POSTGRES_DB: newapi
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - $DOCKER_NETWORK
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U newapi"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    container_name: newapi-redis
    restart: always
    command: redis-server --requirepass $REDIS_PASSWORD --appendonly yes
    volumes:
      - redis_data:/data
    networks:
      - $DOCKER_NETWORK
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "$REDIS_PASSWORD", "ping"]
      interval: 10s
      timeout: 3s
      retries: 5

networks:
  $DOCKER_NETWORK:
    name: $DOCKER_NETWORK
    driver: bridge

volumes:
  postgres_data:
    driver: local
  redis_data:
    driver: local
COMPOSE_EOF
else
    cat > "$SERVICE_DIR/docker-compose.yml" <<COMPOSE_EOF
# Managed by HAO
# Service: new-api
# Release: ${COMMON_VERSION}
version: '3.8'

services:
  new-api:
    image: $DOCKER_IMAGE
    container_name: new-api
    restart: always
    labels:
      io.hao.managed: "true"
      io.hao.service: "new-api"
      io.hao.release: "${COMMON_VERSION}"
    ports:
      - "127.0.0.1:$NEWAPI_PORT:3000"
    volumes:
      - ./data:/data
      - ./logs:/app/logs
    environment:
      - SQL_DSN=newapi:$DB_PASSWORD@tcp(mysql:3306)/newapi
      - REDIS_CONN_STRING=redis://:$REDIS_PASSWORD@redis:6379
      - SESSION_SECRET=$SESSION_SECRET
      - TZ=Asia/Shanghai
      - ERROR_LOG_ENABLED=true
      - BATCH_UPDATE_ENABLED=true
      - STREAMING_TIMEOUT=300
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_started
    networks:
      - $DOCKER_NETWORK
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:3000/api/status >/dev/null 2>&1 || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

  mysql:
    image: $DB_IMAGE
    container_name: newapi-mysql
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: $DB_PASSWORD
      MYSQL_DATABASE: newapi
      MYSQL_USER: newapi
      MYSQL_PASSWORD: $DB_PASSWORD
    volumes:
      - mysql_data:/var/lib/mysql
    networks:
      - $DOCKER_NETWORK
    command: --default-authentication-plugin=mysql_native_password --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-p$DB_PASSWORD"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    container_name: newapi-redis
    restart: always
    command: redis-server --requirepass $REDIS_PASSWORD --appendonly yes
    volumes:
      - redis_data:/data
    networks:
      - $DOCKER_NETWORK
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "$REDIS_PASSWORD", "ping"]
      interval: 10s
      timeout: 3s
      retries: 5

networks:
  $DOCKER_NETWORK:
    name: $DOCKER_NETWORK
    driver: bridge

volumes:
  mysql_data:
    driver: local
  redis_data:
    driver: local
COMPOSE_EOF
fi

chmod 600 "$SERVICE_DIR/docker-compose.yml"
log_success "Docker Compose 配置已生成"

# ==================== 拉取镜像 ====================
log_step "[4/8] 拉取 Docker 镜像..."

cd "$SERVICE_DIR"

log_info "正在拉取镜像（可能需要几分钟）..."
if $COMPOSE_CMD pull; then
    log_success "镜像拉取完成"
else
    log_error "镜像拉取失败，请检查网络连接。"
    exit 1
fi

# ==================== 启动服务 ====================
log_step "[5/8] 启动 Docker 服务..."

log_info "正在启动容器..."
if $COMPOSE_CMD up -d; then
    log_success "容器启动成功"
else
    log_error "容器启动失败"
    $COMPOSE_CMD logs 2>/dev/null || true
    exit 1
fi

# 使用健康检查轮询替代固定 sleep
log_info "等待服务健康检查通过（最多 90 秒）..."
if ! wait_for_healthy "$COMPOSE_CMD" "$SERVICE_DIR" 90 5 "new-api"; then
    log_error "New-API 健康检查未通过。"
    $COMPOSE_CMD ps 2>/dev/null || true
    $COMPOSE_CMD logs --tail=80 new-api 2>/dev/null || true
    exit 1
fi

if $COMPOSE_CMD ps 2>/dev/null | grep -q "Up"; then
    log_success "服务运行正常"
else
    log_error "服务未正常运行，请检查日志"
    $COMPOSE_CMD ps 2>/dev/null || true
    exit 1
fi

# ==================== SSL 证书 ====================
log_step "[6/8] 配置 SSL 证书..."

DOMAIN_SSL_DIR="$SSL_DIR/$DOMAIN"

if [ "$USE_HTTP_ONLY" = true ]; then
    SSL_TYPE="无 (HTTP 模式)"
    log_info "HTTP 模式，跳过 SSL 证书配置"
elif [ "$USE_DOMAIN" = true ]; then
    SSL_TYPE=$(apply_ssl_certificate "$DOMAIN" "$DOMAIN_SSL_DIR" "domain")
else
    SSL_TYPE=$(apply_ssl_certificate "$DOMAIN" "$DOMAIN_SSL_DIR" "ip")
fi

# ==================== Nginx 配置 ====================
log_step "[7/8] 配置 Nginx 反向代理..."

NGINX_SUPPORTS_HTTP3=false
if detect_nginx_http3; then
    NGINX_SUPPORTS_HTTP3=true
    log_info "检测到 HTTP/3 支持"
fi

CONF_FILE="$CONF_D/${DOMAIN}.conf"

EXISTING_DOMAIN_CONF="$(find_nginx_conf_by_server_name "$DOMAIN" "$CONF_D" || true)"
if [ -n "$EXISTING_DOMAIN_CONF" ]; then
    if ! grep -q "NEW-API-START" "$EXISTING_DOMAIN_CONF"; then
        log_error "Nginx server_name 已被其他配置占用: $EXISTING_DOMAIN_CONF"
        log_error "请为 New-API 使用独立域名，避免覆盖其他服务。"
        exit 1
    fi
    CONF_FILE="$EXISTING_DOMAIN_CONF"
fi
CONF_BACKUP="$(backup_file_for_write "$CONF_FILE")"

# 公共 location 块
read -r -d '' NGINX_LOCATION <<'NGX_LOC_EOF' || true
    #NEW-API-START
    location / {
        proxy_pass http://127.0.0.1:NEWAPI_PORT_PLACEHOLDER;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # WebSocket 支持
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        # SSE 流式响应支持
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
        chunked_transfer_encoding on;
    }
    #NEW-API-END
NGX_LOC_EOF

if [ "$USE_HTTP_ONLY" = true ]; then
    cat > "$CONF_FILE" <<NGX_HTTP
# Managed by HAO
# Service: new-api
# Release: ${COMMON_VERSION}
server {
    listen 80;
    server_name $DOMAIN;
    client_max_body_size 50m;
    tcp_nodelay on;
    access_log /var/log/nginx/newapi_access.log;
    error_log /var/log/nginx/newapi_error.log warn;
$NGINX_LOCATION
}
NGX_HTTP
elif [ "$NGINX_SUPPORTS_HTTP3" = true ]; then
    cat > "$CONF_FILE" <<NGX_H3
# Managed by HAO
# Service: new-api
# Release: ${COMMON_VERSION}
server {
    listen 80;
    listen 443 ssl;
    listen 443 quic;
    http2 on;
    server_name $DOMAIN;
    client_max_body_size 50m;
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

    access_log /var/log/nginx/newapi_access.log;
    error_log /var/log/nginx/newapi_error.log warn;
$NGINX_LOCATION
}
NGX_H3
else
    cat > "$CONF_FILE" <<NGX_H2
# Managed by HAO
# Service: new-api
# Release: ${COMMON_VERSION}
server {
    listen 80;
    listen 443 ssl;
    http2 on;
    server_name $DOMAIN;
    client_max_body_size 50m;
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

    access_log /var/log/nginx/newapi_access.log;
    error_log /var/log/nginx/newapi_error.log warn;
$NGINX_LOCATION
}
NGX_H2
fi

# 替换占位符
sed -i "s|NEWAPI_PORT_PLACEHOLDER|$NEWAPI_PORT|g" "$CONF_FILE"

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

# ==================== 生成凭据信息文件 ====================
log_step "[8/8] 生成凭据信息文件..."

CREDENTIALS_FILE="$SERVICE_DIR/hao-credentials.txt"

if [ "$USE_HTTP_ONLY" = true ]; then
    ACCESS_URL="http://$DOMAIN"
elif [ "$USE_DOMAIN" = true ]; then
    ACCESS_URL="https://$DOMAIN"
else
    ACCESS_URL="https://$DOMAIN"
fi

write_credentials_file "$CREDENTIALS_FILE" <<INFO_EOF
================================================
       New-API Docker 部署完成 (${COMMON_VERSION})
================================================
部署时间: $(date '+%Y-%m-%d %H:%M:%S')
访问模式: $(if [ "$USE_HTTP_ONLY" = true ]; then echo "HTTP"; elif [ "$USE_DOMAIN" = true ]; then echo "域名"; else echo "IP"; fi)
访问地址: $ACCESS_URL

⚠️ 首次访问请在 Web 界面创建管理员账号
$( [ "$USE_HTTP_ONLY" = true ] && echo "⚠️  HTTP 模式: 数据不加密，仅限内网/开发" )
$( [ "$USE_HTTP_ONLY" = false ] && [ "$USE_DOMAIN" = false ] && echo "⚠️  IP 模式: 浏览器会提示证书不安全" )

[数据库信息]
类型:      $DB_TYPE
用户名:    newapi
密码:      $DB_PASSWORD
数据库名:  newapi

[Redis 信息]
密码:      $REDIS_PASSWORD

[Session Secret]
$SESSION_SECRET

⚠️ 重要：请妥善保管以上密码信息！

[服务目录]
Docker 目录:  $SERVICE_DIR
配置文件:     $SERVICE_DIR/docker-compose.yml

[Docker 管理]
进入目录:  cd $SERVICE_DIR
查看状态:  $COMPOSE_CMD ps
查看日志:  $COMPOSE_CMD logs -f new-api
重启服务:  $COMPOSE_CMD restart

[升级]
cd $SERVICE_DIR && $COMPOSE_CMD pull && $COMPOSE_CMD up -d

[SSL 证书]
类型:      $SSL_TYPE
证书目录:  $DOMAIN_SSL_DIR/

[官方文档]
https://docs.newapi.pro/zh/docs
================================================
INFO_EOF

log_success "凭据信息已保存: $CREDENTIALS_FILE"

# ==================== 完成 ====================
clear 2>/dev/null || true
printf '%s\n' "================================================"
printf '%s\n' "       New-API Docker 部署完成 (${COMMON_VERSION})"
printf '%s\n' "================================================"
printf '访问地址: %s\n' "$ACCESS_URL"
printf '凭据文件: %s\n' "$CREDENTIALS_FILE"
printf '%s\n' "请到凭据文件中查看数据库密码、Redis 密码和 Session Secret。"
echo ""

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✅ New-API 部署完成！${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "🔐 凭据文件: ${YELLOW}$CREDENTIALS_FILE${NC}"
echo -e "🌐 访问地址: ${GREEN}$ACCESS_URL${NC}"
echo -e "📊 服务状态: ${CYAN}cd $SERVICE_DIR && $COMPOSE_CMD ps${NC}"
echo ""
if [ "$USE_HTTP_ONLY" = true ]; then
    echo -e "${YELLOW}⚠️ HTTP 模式: 数据不加密${NC}"
elif [ "$USE_DOMAIN" = false ]; then
    echo -e "${YELLOW}⚠️ IP 模式: 证书不受信任${NC}"
fi
echo -e "${YELLOW}⚠️ 下一步: 访问 Web 界面创建管理员账号${NC}"
echo ""
log_success "日志已保存: $DEPLOY_LOG_FILE"
