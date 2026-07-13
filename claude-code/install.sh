#!/bin/bash
# shellcheck disable=SC2034

################################################################################
#
# Claude Code 安装与配置脚本
# 发布标识由 HAO_RELEASE 提供
#
# 功能说明：
#   1. 检测并安装 Node.js (v22 LTS)
#   2. 通过 npm 全局安装 @anthropic-ai/claude-code
#   3. 可选：为目标用户写入 ~/.claude/settings.json（自定义网关/模型/超时）
#
# 用法:
#   sudo ./install.sh                 # 交互式安装
#   sudo ./install.sh --no-prompt     # 非交互式安装
#   ./install.sh -h                   # 显示帮助
#
# 配置变量（均可选，见 README.md）：
#   HAO_CC_BASE_URL       Anthropic 兼容网关地址
#   HAO_CC_AUTH_TOKEN     API token（或使用 HAO_CC_TOKEN_FILE）
#   HAO_CC_TOKEN_FILE     从文件读取 token，避免 token 出现在命令行/profile
#   HAO_CC_MODEL          默认模型（同时写入 SONNET/OPUS/HAIKU 默认值）
#   HAO_CC_API_TIMEOUT_MS API 超时，默认 3000000
#   HAO_CC_USER           settings.json 目标用户，默认 SUDO_USER 或当前用户
#   HAO_CC_CONFIGURE_ONLY 设为 1 时只写配置，跳过 Node.js/CLI 安装（无需 root）
#
################################################################################

set -euo pipefail

HAO_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HAO_REPO_DIR="$(cd "$HAO_SCRIPT_DIR/.." && pwd)"
# ==================== 公共函数 ====================
# 本脚本可在完整仓库内独立运行，并复用 ../lib 公共库。
# shellcheck source=../lib/common.sh
source "$HAO_REPO_DIR/lib/common.sh"
# shellcheck source=../lib/credentials.sh
source "$HAO_REPO_DIR/lib/credentials.sh"

# ==================== 帮助 ====================
show_help() {
    cat <<'EOF'
Claude Code 安装与配置脚本

用法:
  sudo ./install.sh              # 交互式安装
  sudo ./install.sh --no-prompt  # 非交互式安装（跳过确认）
  ./install.sh -h                # 显示此帮助

功能:
  1. 检测并安装 Node.js (v22 LTS)
  2. npm 全局安装 @anthropic-ai/claude-code（已安装则升级）
  3. 如提供 HAO_CC_* 配置变量，为目标用户写入 ~/.claude/settings.json

模式:
  HAO_CC_CONFIGURE_ONLY=1 时跳过步骤 1-2，只写配置。
  该模式下无需 root（为当前用户写配置时）。

安全说明:
  - token 只写入 settings.json (0600)，不会打印或写入日志
  - 已存在的 settings.json 先备份再覆盖

环境要求:
  - Root 权限（安装模式）
  - 网络连接（npm registry, nodesource.com）
EOF
    exit 0
}

# ==================== 参数解析 ====================
NO_PROMPT=false
if [ "${HAO_UNATTENDED:-}" = "1" ] || [ "${HAO_NO_PROMPT:-}" = "1" ]; then
    NO_PROMPT=true
fi
for arg in "$@"; do
    case "$arg" in
        -h|--help) show_help ;;
        --no-prompt) NO_PROMPT=true ;;
    esac
done

# ==================== 配置解析 ====================
CONFIGURE_ONLY=false
if [ "${HAO_CC_CONFIGURE_ONLY:-}" = "1" ]; then
    CONFIGURE_ONLY=true
fi

CC_BASE_URL="${HAO_CC_BASE_URL:-}"
CC_AUTH_TOKEN="${HAO_CC_AUTH_TOKEN:-}"
CC_TOKEN_FILE="${HAO_CC_TOKEN_FILE:-}"
CC_MODEL="${HAO_CC_MODEL:-}"
CC_API_TIMEOUT_MS="${HAO_CC_API_TIMEOUT_MS:-3000000}"
CC_TARGET_USER="${HAO_CC_USER:-${SUDO_USER:-$(id -un)}}"

if [ -n "$CC_TOKEN_FILE" ]; then
    if [ ! -r "$CC_TOKEN_FILE" ]; then
        echo "[ERROR] HAO_CC_TOKEN_FILE 不存在或不可读: $CC_TOKEN_FILE" >&2
        exit 1
    fi
    CC_AUTH_TOKEN="$(head -n1 "$CC_TOKEN_FILE")"
fi

WRITE_SETTINGS=false
if [ -n "$CC_BASE_URL" ] || [ -n "$CC_AUTH_TOKEN" ] || [ -n "$CC_MODEL" ]; then
    WRITE_SETTINGS=true
fi

json_escape() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '%s' "$value"
}

# ==================== 安装流程 ====================
if [ "$CONFIGURE_ONLY" = false ]; then
    check_root
    setup_logging "claude-code-install"
elif [ "$EUID" -eq 0 ]; then
    setup_logging "claude-code-configure"
fi

echo "============================================"
echo "   Claude Code 安装脚本 ${COMMON_VERSION}"
echo "============================================"
echo ""

if [ "$WRITE_SETTINGS" = true ]; then
    log_info "配置目标用户: $CC_TARGET_USER"
    log_info "网关地址: ${CC_BASE_URL:-默认 (api.anthropic.com)}"
    if [ -n "$CC_AUTH_TOKEN" ]; then
        log_info "token: provided (hidden)"
    else
        log_info "token: not provided"
    fi
else
    log_info "未提供 HAO_CC_* 配置变量，仅安装 CLI，不写 settings.json"
fi

if [ "$NO_PROMPT" = false ]; then
    if ! confirm "是否开始安装？"; then
        log_info "安装已取消。"
        exit 0
    fi
fi

# === Step 1: 安装 Node.js ===
if [ "$CONFIGURE_ONLY" = true ]; then
    log_step "Step 1/3: 跳过 Node.js 安装（HAO_CC_CONFIGURE_ONLY=1）"
else
    log_step "Step 1/3: 检测 Node.js..."
    if command -v node &>/dev/null; then
        NODE_VERSION=$(node --version | sed 's/v//')
        NODE_MAJOR="${NODE_VERSION%%.*}"
        if [[ "$NODE_MAJOR" =~ ^[0-9]+$ ]] && [ "$NODE_MAJOR" -ge 18 ]; then
            log_success "Node.js 已安装 (v${NODE_VERSION})"
        else
            log_warning "Node.js 版本过低 (v${NODE_VERSION})，升级到 v22 LTS..."
            curl -fsSL --connect-timeout 30 https://deb.nodesource.com/setup_22.x | bash - || { log_error "Node.js 安装失败"; exit 1; }
            apt-get install -y nodejs
        fi
    else
        log_info "安装 Node.js v22 LTS..."
        curl -fsSL --connect-timeout 30 https://deb.nodesource.com/setup_22.x | bash - || { log_error "Node.js 安装失败"; exit 1; }
        apt-get install -y nodejs
    fi
    log_success "Node.js 就绪: $(node --version)"
fi

# === Step 2: 安装 Claude Code ===
if [ "$CONFIGURE_ONLY" = true ]; then
    log_step "Step 2/3: 跳过 Claude Code 安装（HAO_CC_CONFIGURE_ONLY=1）"
else
    log_step "Step 2/3: 安装 Claude Code..."
    if command -v claude &>/dev/null; then
        CLAUDE_VERSION=$(claude --version 2>/dev/null || echo "unknown")
        log_warning "Claude Code 已安装 (${CLAUDE_VERSION})，升级到最新版..."
    fi
    npm install -g @anthropic-ai/claude-code
    log_success "Claude Code 安装完成: $(claude --version 2>/dev/null || echo 'unknown')"
fi

# === Step 3: 写入配置 ===
if [ "$WRITE_SETTINGS" = true ]; then
    log_step "Step 3/3: 写入 settings.json..."

    TARGET_HOME="$(getent passwd "$CC_TARGET_USER" | cut -d: -f6)"
    if [ -z "$TARGET_HOME" ] || [ ! -d "$TARGET_HOME" ]; then
        log_error "无法确定用户 $CC_TARGET_USER 的 home 目录"
        exit 1
    fi

    SETTINGS_DIR="$TARGET_HOME/.claude"
    SETTINGS_FILE="$SETTINGS_DIR/settings.json"

    mkdir -p "$SETTINGS_DIR"
    chmod 700 "$SETTINGS_DIR"

    backup_file "$SETTINGS_FILE"

    # 只写入用户提供的键；token 不经过 stdout/日志。
    {
        echo '{'
        echo '  "env": {'
        first=true
        emit_kv() {
            local key="$1" value="$2"
            [ "$first" = true ] || echo ','
            first=false
            printf '    "%s": "%s"' "$key" "$(json_escape "$value")"
        }
        [ -n "$CC_BASE_URL" ]   && emit_kv "ANTHROPIC_BASE_URL" "$CC_BASE_URL"
        [ -n "$CC_AUTH_TOKEN" ] && emit_kv "ANTHROPIC_AUTH_TOKEN" "$CC_AUTH_TOKEN"
        if [ -n "$CC_MODEL" ]; then
            emit_kv "ANTHROPIC_MODEL" "$CC_MODEL"
            emit_kv "ANTHROPIC_DEFAULT_SONNET_MODEL" "$CC_MODEL"
            emit_kv "ANTHROPIC_DEFAULT_OPUS_MODEL" "$CC_MODEL"
            emit_kv "ANTHROPIC_DEFAULT_HAIKU_MODEL" "$CC_MODEL"
        fi
        emit_kv "API_TIMEOUT_MS" "$CC_API_TIMEOUT_MS"
        echo ''
        echo '  }'
        echo '}'
    } | write_credentials_file "$SETTINGS_FILE"

    if [ "$EUID" -eq 0 ]; then
        chown -R "$CC_TARGET_USER":"$(id -gn "$CC_TARGET_USER")" "$SETTINGS_DIR"
    fi

    if command -v node &>/dev/null; then
        if SETTINGS_FILE="$SETTINGS_FILE" node -e "JSON.parse(require('fs').readFileSync(process.env.SETTINGS_FILE,'utf8'))" 2>/dev/null; then
            log_success "settings.json 校验通过: $SETTINGS_FILE"
        else
            log_error "settings.json JSON 校验失败: $SETTINGS_FILE"
            exit 1
        fi
    else
        log_warning "未检测到 node，跳过 JSON 校验: $SETTINGS_FILE"
    fi
else
    log_step "Step 3/3: 跳过配置（未提供 HAO_CC_* 变量）"
fi

echo ""
echo "============================================"
echo "  使用方法:"
echo "    claude            # 交互模式"
echo "    claude --version  # 查看版本"
echo ""
if [ "$WRITE_SETTINGS" = true ]; then
    echo "  配置文件: settings.json（token 已写入，未打印）"
    echo "  修改配置后需重启 Claude Code 生效"
else
    echo "  配置网关/模型: 参考 claude-code/README.md 或 docs/claude-code-guide.md"
fi
echo "============================================"
echo ""
if [ -n "${DEPLOY_LOG_FILE:-}" ]; then
    log_success "日志已保存: $DEPLOY_LOG_FILE"
fi
