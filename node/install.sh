#!/bin/bash
# shellcheck disable=SC2034

################################################################################
#
# Node.js 运行时安装脚本（NodeSource 官方 apt 仓库，系统级安装）
# 发布标识由 HAO_RELEASE 提供
#
# 功能说明：
#   1. 配置 NodeSource 官方 apt 仓库（手动配置，等效 setup_<主版本>.x）
#   2. 通过 apt 系统级安装 Node.js：node/npm 落在 /usr/bin 标准路径
#   3. 验证 node --version 与 npm --version
#
# 背景：
#   线上事故：某项目的 systemd unit 写死 /usr/bin/node，而机器上的 Node
#   实际装在某用户 home（nvm）下，服务无法启动。装在用户目录的 Node 对
#   系统服务、其他用户、非登录 shell 均不可见。本模块把 Node.js 作为
#   系统包装到标准路径。
#
# 用法:
#   sudo ./install.sh                 # 交互式安装
#   sudo ./install.sh --no-prompt     # 非交互式安装
#   ./install.sh -h                   # 显示帮助
#
# 配置变量（均可选，见 README.md）：
#   HAO_NODE_VERSION    Node.js 主版本号（数字），默认 22（LTS）
#   HAO_NODE_ACTION     ensure（默认：/usr/bin/node 已是请求主版本则跳过安装，
#                       仅验证）| upgrade（刷新仓库并升级到该主版本最新小版本）
#
################################################################################

set -euo pipefail

HAO_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HAO_REPO_DIR="$(cd "$HAO_SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$HAO_REPO_DIR/lib/common.sh"

# ==================== 帮助 ====================
show_help() {
    cat <<'EOF'
Node.js 运行时安装脚本（NodeSource 官方 apt 仓库）

用法:
  sudo ./install.sh              # 交互式安装
  sudo ./install.sh --no-prompt  # 非交互式安装（跳过确认）
  ./install.sh -h                # 显示此帮助

功能:
  1. 配置 NodeSource 官方 apt 仓库（/etc/apt/sources.list.d/nodesource.list）
  2. apt 安装 nodejs 包：node/npm 落在 /usr/bin 标准路径，
     systemd unit 与任意用户可直接使用
  3. 验证 node --version 与 npm --version

配置:
  HAO_NODE_VERSION    Node.js 主版本号（数字），默认 22（LTS）
  HAO_NODE_ACTION     ensure | upgrade（默认 ensure）

幂等性:
  - ensure 且 /usr/bin/node 主版本与请求一致：干净跳过（不触碰 apt），仅验证
  - 用户目录 / /usr/local 下的 node（nvm、tarball 等）不算已安装；
    本模块只认系统标准路径 /usr/bin/node，且不会删除用户级安装
  - upgrade：刷新仓库配置并升级到该主版本的最新小版本

环境要求:
  - Root 权限
  - Debian / Ubuntu（apt）
  - 网络连接（deb.nodesource.com）
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
NODE_ACTION="${HAO_NODE_ACTION:-ensure}"
case "$NODE_ACTION" in
    ensure|upgrade) ;;
    *)
        echo "[ERROR] 无效的 HAO_NODE_ACTION: $NODE_ACTION（可选: ensure | upgrade）" >&2
        exit 1
        ;;
esac
NODE_MAJOR="${HAO_NODE_VERSION:-22}"
if ! [[ "$NODE_MAJOR" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] 无效的 HAO_NODE_VERSION: $NODE_MAJOR（应为数字主版本号，例如 22）" >&2
    exit 1
fi

NODE_KEYRING_PATH="/etc/apt/keyrings/nodesource.gpg"
NODE_SOURCE_PATH="/etc/apt/sources.list.d/nodesource.list"
NODE_REPO_URL="https://deb.nodesource.com/node_${NODE_MAJOR}.x"
NODE_KEY_URL="https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key"

# /usr/bin/node 的主版本号；不存在或无法解析时返回 1
system_node_major() {
    local v
    [ -x /usr/bin/node ] || return 1
    v="$(/usr/bin/node --version 2>/dev/null)" || return 1
    v="${v#v}"
    v="${v%%.*}"
    [[ "$v" =~ ^[0-9]+$ ]] || return 1
    echo "$v"
}

node_source_content() {
    cat <<EOF
# Managed by HAO
# Service: node
# 发布标识: ${COMMON_VERSION}
# NodeSource Node.js ${NODE_MAJOR}.x 官方 apt 仓库（手动配置，等效 setup_${NODE_MAJOR}.x）
deb [signed-by=${NODE_KEYRING_PATH}] ${NODE_REPO_URL} nodistro main
EOF
}

# 配置 NodeSource apt 仓库（GPG key + 源列表），均为幂等写入
configure_nodesource_repo() {
    export DEBIAN_FRONTEND=noninteractive
    local tmp_dir desired_src key_tmp
    tmp_dir="$(mktemp -d)"
    desired_src="$tmp_dir/nodesource.list"
    key_tmp="$tmp_dir/nodesource.gpg"

    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg

    install -d -m 0755 /etc/apt/keyrings /etc/apt/sources.list.d

    # GPG key：已存在则复用（如需刷新，删除该文件后重跑本脚本）
    if [ -e "$NODE_KEYRING_PATH" ]; then
        log_info "NodeSource 仓库 GPG key 已存在，复用: $NODE_KEYRING_PATH"
    else
        if ! curl -fsSL --connect-timeout 30 "$NODE_KEY_URL" | gpg --batch --dearmor > "$key_tmp"; then
            rm -rf "$tmp_dir"
            log_error "NodeSource GPG key 下载或解析失败: $NODE_KEY_URL"
            exit 1
        fi
        if [ ! -s "$key_tmp" ]; then
            rm -rf "$tmp_dir"
            log_error "NodeSource GPG key 内容为空: $NODE_KEY_URL"
            exit 1
        fi
        install -m 0644 "$key_tmp" "$NODE_KEYRING_PATH"
        log_success "已安装 NodeSource GPG key: $NODE_KEYRING_PATH"
    fi

    # apt 源：内容一致则保持不动；不一致则备份后覆盖
    node_source_content > "$desired_src"
    if [ -f "$NODE_SOURCE_PATH" ] && cmp -s "$desired_src" "$NODE_SOURCE_PATH"; then
        log_info "NodeSource apt 源已是目标配置，保持不变: $NODE_SOURCE_PATH"
    else
        if [ -f "$NODE_SOURCE_PATH" ]; then
            log_warning "已存在的 nodesource.list 与目标配置不一致，备份后覆盖"
            backup_file "$NODE_SOURCE_PATH"
        fi
        install -m 0644 "$desired_src" "$NODE_SOURCE_PATH"
        log_success "已写入 NodeSource apt 源: $NODE_SOURCE_PATH (node_${NODE_MAJOR}.x)"
    fi

    rm -rf "$tmp_dir"
    apt-get update -qq
}

# ==================== 安装流程 ====================
check_root
setup_logging "node-install"

echo "============================================"
echo "   Node.js 安装脚本 ${COMMON_VERSION}"
echo "============================================"
echo ""

log_info "目标版本: Node.js ${NODE_MAJOR}.x（NodeSource 官方 apt 仓库）"
log_info "动作: ${NODE_ACTION}"

if [ "$NO_PROMPT" = false ]; then
    if ! confirm "是否开始安装？"; then
        log_info "安装已取消。"
        exit 0
    fi
fi

# === Step 1/3: 检测现有系统级 Node.js ===
log_step "Step 1/3: 检测系统级 Node.js..."

# 用户目录或 /usr/local 下的 node（nvm/tarball 等）不满足系统服务需求：
# 只提示，不算已安装，也不会删除它。
PATH_NODE="$(command -v node 2>/dev/null || true)"
if [ -n "$PATH_NODE" ] && [ "$PATH_NODE" != "/usr/bin/node" ]; then
    log_warning "PATH 中检测到非系统路径的 node: $PATH_NODE（本模块确保 /usr/bin/node 就绪，不会删除它）"
fi

NEED_INSTALL=true
CURRENT_MAJOR="$(system_node_major || true)"
if [ -n "$CURRENT_MAJOR" ] && [ "$CURRENT_MAJOR" = "$NODE_MAJOR" ]; then
    CURRENT_VERSION="$(/usr/bin/node --version 2>/dev/null || echo unknown)"
    if [ ! -x /usr/bin/npm ]; then
        log_warning "检测到 /usr/bin/node (${CURRENT_VERSION}) 但缺少 npm，将重装 nodejs 包..."
    elif [ "$NODE_ACTION" = "upgrade" ]; then
        log_info "Node.js 已安装 (${CURRENT_VERSION})，HAO_NODE_ACTION=upgrade，刷新到 ${NODE_MAJOR}.x 最新小版本..."
    else
        NEED_INSTALL=false
        log_success "Node.js 已安装且主版本一致 (${CURRENT_VERSION})，跳过安装。如需刷新: HAO_NODE_ACTION=upgrade"
    fi
elif [ -n "$CURRENT_MAJOR" ]; then
    log_warning "系统 Node.js 主版本 (${CURRENT_MAJOR}) 与请求 (${NODE_MAJOR}) 不一致，将安装请求版本..."
else
    log_info "未检测到系统级 Node.js (/usr/bin/node)，开始安装..."
fi

# === Step 2/3: 配置仓库并安装 ===
if [ "$NEED_INSTALL" = true ]; then
    log_step "Step 2/3: 配置 NodeSource 仓库并安装 Node.js ${NODE_MAJOR}.x..."
    command -v apt-get &>/dev/null || { log_error "未检测到 apt-get，本模块仅支持 Debian/Ubuntu"; exit 1; }
    configure_nodesource_repo
    apt-get install -y nodejs || { log_error "Node.js (nodejs 包) 安装失败"; exit 1; }
    log_success "Node.js 安装完成: $(/usr/bin/node --version 2>/dev/null || echo unknown)"
else
    log_step "Step 2/3: 跳过安装（ensure：已满足请求的主版本）"
fi

# === Step 3/3: 验证 ===
log_step "Step 3/3: 验证安装..."
INSTALLED_MAJOR="$(system_node_major || true)"
if [ "$INSTALLED_MAJOR" != "$NODE_MAJOR" ]; then
    log_error "验证失败: /usr/bin/node 主版本 (${INSTALLED_MAJOR:-缺失}) 与请求 (${NODE_MAJOR}) 不一致"
    exit 1
fi
if [ ! -x /usr/bin/npm ]; then
    log_error "验证失败: /usr/bin/npm 不存在"
    exit 1
fi
command -v node &>/dev/null || { log_error "验证失败: node 不在 PATH 中"; exit 1; }
command -v npm &>/dev/null || { log_error "验证失败: npm 不在 PATH 中"; exit 1; }
log_success "node 就绪: $(command -v node) ($(node --version))"
log_success "npm 就绪: $(command -v npm) ($(npm --version 2>/dev/null || echo unknown))"

echo ""
echo "============================================"
echo "  使用方法:"
echo "    node --version          # 查看 Node.js 版本"
echo "    npm --version           # 查看 npm 版本"
echo "    npm install -g <pkg>    # 全局安装 CLI 工具"
echo "    升级: sudo HAO_NODE_ACTION=upgrade $0 --no-prompt"
echo "============================================"
echo ""
if [ -n "${DEPLOY_LOG_FILE:-}" ]; then
    log_success "日志已保存: $DEPLOY_LOG_FILE"
fi
