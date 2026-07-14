#!/bin/bash
# shellcheck disable=SC2034

################################################################################
#
# uv (Python 环境管理器) 安装与 agent 约定配置脚本
# 发布标识由 HAO_RELEASE 提供
#
# 功能说明：
#   1. 系统级安装 uv 到 /usr/local/bin（已安装则原地升级）
#   2. 可选：预装指定 Python 解释器版本（uv python install）
#   3. 将「Python 项目一律使用 uv」的约定写入目标用户已安装的
#      AI 编程助手全局指令文件（Claude Code / Pi / Codex CLI / OpenCode）
#
# 背景：
#   Debian 12+ / Ubuntu 24.04+ 的系统 Python 是 externally-managed（PEP 668），
#   全局 pip 默认被拒绝。AI agent 碰壁后常退化为 apt install python3-* 或
#   --break-system-packages，污染系统。本模块统一约定为 uv 管理虚拟环境。
#
# 用法:
#   sudo ./install.sh                 # 交互式安装
#   sudo ./install.sh --no-prompt     # 非交互式安装
#   ./install.sh -h                   # 显示帮助
#
# 配置变量（均可选，见 README.md）：
#   HAO_UV_ACTION       ensure（默认：已安装则不升级）| upgrade（显式升级）
#   HAO_UV_PYTHON       预装的 Python 版本，逗号分隔（如 "3.12" 或 "3.11,3.12"）
#   HAO_UV_USER         agent 约定写入的目标用户，默认 SUDO_USER 或当前用户
#   HAO_UV_AGENT_FILES  显式指定约定写入的文件（逗号分隔绝对路径），
#                       设置后跳过自动检测
#   HAO_UV_SKIP_AGENT_CONVENTION  设为 1 时不写任何 agent 约定
#
################################################################################

set -euo pipefail

HAO_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HAO_REPO_DIR="$(cd "$HAO_SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$HAO_REPO_DIR/lib/common.sh"
# shellcheck source=../lib/agent-convention.sh
source "$HAO_REPO_DIR/lib/agent-convention.sh"

# ==================== 帮助 ====================
show_help() {
    cat <<'EOF'
uv 安装与 agent 约定配置脚本

用法:
  sudo ./install.sh              # 交互式安装
  sudo ./install.sh --no-prompt  # 非交互式安装（跳过确认）
  ./install.sh -h                # 显示此帮助

功能:
  1. 系统级安装 uv 到 /usr/local/bin（已安装则升级）
  2. HAO_UV_PYTHON 非空时预装对应 Python 解释器
  3. 将 Python 虚拟环境约定写入目标用户已安装的 AI 助手指令文件：
     - Claude Code:  ~/.claude/CLAUDE.md
     - Pi:           ~/.pi/agent/AGENTS.md
     - Codex CLI:    ~/.codex/AGENTS.md
     - OpenCode:     ~/.config/opencode/AGENTS.md
     只写入检测到对应工具（或已有配置目录）的文件；
     HAO_UV_AGENT_FILES 可显式覆盖检测结果。

幂等性:
  - uv 已安装时默认保持现有版本（HAO_UV_ACTION=upgrade 时才升级）
  - agent 约定使用标记块（HAO-UV BEGIN/END）包裹，重复执行原地更新

环境要求:
  - Root 权限
  - 网络连接（astral.sh, github.com）
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
UV_ACTION="${HAO_UV_ACTION:-ensure}"
case "$UV_ACTION" in
    ensure|upgrade) ;;
    *)
        echo "[ERROR] 无效的 HAO_UV_ACTION: $UV_ACTION（可选: ensure | upgrade）" >&2
        exit 1
        ;;
esac
UV_PYTHON_VERSIONS="${HAO_UV_PYTHON:-}"
UV_TARGET_USER="${HAO_UV_USER:-${SUDO_USER:-$(id -un)}}"
UV_AGENT_FILES_OVERRIDE="${HAO_UV_AGENT_FILES:-}"
UV_SKIP_AGENT_CONVENTION="${HAO_UV_SKIP_AGENT_CONVENTION:-0}"
UV_INSTALL_DIR="/usr/local/bin"

uv_convention_text() {
    cat <<'EOF'
## Python 环境约定（uv）

本机 Python 项目一律使用 [uv](https://docs.astral.sh/uv/) 管理环境和依赖：

- 新项目 / 有 `pyproject.toml` 的项目：`uv sync` 安装依赖，`uv add <pkg>` 添加依赖，`uv run <cmd>` 执行命令。
- 只有 `requirements.txt` 的第三方项目：`uv venv` 创建 `.venv`，然后 `uv pip install -r requirements.txt`。
- 需要独立 Python 版本时：`uv python install 3.12`，`uv venv --python 3.12`。
- 运行一次性工具：`uvx <tool>`（等价 pipx）。

禁止事项：

- 禁止系统级 `pip install`，禁止 `pip install --break-system-packages`（本系统 Python 是 externally-managed，PEP 668）。
- 禁止用 `apt install python3-*` 安装项目应用依赖（系统工具依赖除外）。
- 禁止手动下载/编译 Python，统一用 `uv python install`。
EOF
}

# ==================== 安装流程 ====================
check_root
setup_logging "uv-install"

echo "============================================"
echo "   uv 安装脚本 ${COMMON_VERSION}"
echo "============================================"
echo ""

log_info "目标用户: $UV_TARGET_USER"
if [ -n "$UV_PYTHON_VERSIONS" ]; then
    log_info "预装 Python: $UV_PYTHON_VERSIONS"
else
    log_info "预装 Python: 不预装（按需由 uv 自动下载）"
fi

if [ "$NO_PROMPT" = false ]; then
    if ! confirm "是否开始安装？"; then
        log_info "安装已取消。"
        exit 0
    fi
fi

# === Step 1: 安装/升级 uv ===
log_step "Step 1/3: 安装 uv..."
if command -v uv &>/dev/null; then
    UV_CURRENT="$(uv --version 2>/dev/null || echo unknown)"
    if [ "$UV_ACTION" = "upgrade" ]; then
        log_info "uv 已安装 (${UV_CURRENT})，HAO_UV_ACTION=upgrade，升级..."
        # 通过安装脚本安装的 uv 支持 self update；发行版打包的不支持则重装覆盖
        if ! uv self update 2>/dev/null; then
            log_info "uv self update 不可用，通过官方脚本重新安装..."
            curl -fsSL --connect-timeout 30 https://astral.sh/uv/install.sh \
                | env UV_INSTALL_DIR="$UV_INSTALL_DIR" UV_NO_MODIFY_PATH=1 sh \
                || { log_error "uv 安装失败"; exit 1; }
        fi
    else
        log_success "uv 已安装 (${UV_CURRENT})，保持现有版本。如需升级: HAO_UV_ACTION=upgrade"
    fi
else
    curl -fsSL --connect-timeout 30 https://astral.sh/uv/install.sh \
        | env UV_INSTALL_DIR="$UV_INSTALL_DIR" UV_NO_MODIFY_PATH=1 sh \
        || { log_error "uv 安装失败"; exit 1; }
fi
command -v uv &>/dev/null || { log_error "uv 安装后不在 PATH 中"; exit 1; }
log_success "uv 就绪: $(uv --version)"

# === Step 2: 预装 Python 解释器 ===
if [ -z "$UV_PYTHON_VERSIONS" ]; then
    log_step "Step 2/3: 跳过 Python 预装（未设置 HAO_UV_PYTHON）"
else
    log_step "Step 2/3: 预装 Python 解释器..."
    TARGET_HOME="$(getent passwd "$UV_TARGET_USER" | cut -d: -f6)"
    IFS=',' read -ra PYTHON_LIST <<< "$UV_PYTHON_VERSIONS"
    for py_version in "${PYTHON_LIST[@]}"; do
        py_version="$(echo "$py_version" | tr -d '[:space:]')"
        [ -z "$py_version" ] && continue
        if ! [[ "$py_version" =~ ^3\.[0-9]+(\.[0-9]+)?$ ]]; then
            log_error "无效的 Python 版本: $py_version（示例: 3.12）"
            exit 1
        fi
        # 解释器装到目标用户目录，agent 以该用户运行时可直接使用
        if [ "$UV_TARGET_USER" != "root" ] && [ -n "$TARGET_HOME" ]; then
            runuser -u "$UV_TARGET_USER" -- env HOME="$TARGET_HOME" uv python install "$py_version" \
                || { log_error "Python $py_version 安装失败"; exit 1; }
        else
            uv python install "$py_version" \
                || { log_error "Python $py_version 安装失败"; exit 1; }
        fi
        log_success "Python $py_version 就绪"
    done
fi

# === Step 3: 写入 agent 约定 ===
# 检测与标记块写入逻辑在 lib/agent-convention.sh，与其他工具模块共用。
if [ "$UV_SKIP_AGENT_CONVENTION" = "1" ]; then
    log_step "Step 3/3: 跳过 agent 约定（HAO_UV_SKIP_AGENT_CONVENTION=1）"
else
    log_step "Step 3/3: 写入 agent 约定..."
    TARGET_HOME="$(getent passwd "$UV_TARGET_USER" | cut -d: -f6)"
    if [ -z "$TARGET_HOME" ] || [ ! -d "$TARGET_HOME" ]; then
        log_error "无法确定用户 $UV_TARGET_USER 的 home 目录"
        exit 1
    fi

    AGENT_FILES=()
    if [ -n "$UV_AGENT_FILES_OVERRIDE" ]; then
        IFS=',' read -ra AGENT_FILES <<< "$UV_AGENT_FILES_OVERRIDE"
    else
        while IFS= read -r line; do
            [ -n "$line" ] && AGENT_FILES+=("$line")
        done < <(hao_detect_agent_files "$TARGET_HOME")
    fi

    if [ "${#AGENT_FILES[@]}" -eq 0 ]; then
        log_warning "未检测到任何 AI 助手（Claude Code/Pi/Codex/OpenCode），约定未写入。"
        log_warning "安装助手后重跑本脚本，或用 HAO_UV_AGENT_FILES 显式指定文件。"
    else
        for agent_file in "${AGENT_FILES[@]}"; do
            agent_file="$(echo "$agent_file" | tr -d '[:space:]')"
            [ -z "$agent_file" ] && continue
            uv_convention_text | hao_write_agent_convention "$agent_file" "HAO-UV" "$UV_TARGET_USER"
            log_success "约定已写入: $agent_file"
        done
    fi
fi

echo ""
echo "============================================"
echo "  使用方法:"
echo "    uv --version          # 查看版本"
echo "    uv venv               # 在当前目录创建 .venv"
echo "    uv add <package>      # 添加依赖（pyproject.toml 项目）"
echo "    uv pip install -r requirements.txt   # 兼容 requirements 项目"
echo "    uvx <tool>            # 运行一次性工具"
echo "============================================"
echo ""
if [ -n "${DEPLOY_LOG_FILE:-}" ]; then
    log_success "日志已保存: $DEPLOY_LOG_FILE"
fi
