#!/bin/bash
# shellcheck shell=bash

################################################################################
#
# Maintenance 基础维护脚本
# 发布标识由 HAO_RELEASE 提供
#
# 功能说明：
#   1. 安装并配置 fail2ban SSH 防护
#   2. 自动创建 swap（低内存服务器）并配置 sysctl
#   3. 限制 systemd-journald 日志占用
#   4. 预置/合并 Docker json-file 日志轮转配置
#
# 用法:
#   sudo ./install.sh
#   sudo HAO_SWAP_SIZE_MB=2048 ./install.sh  # 强制指定 swap 大小
#
################################################################################

set -euo pipefail

# ==================== 基础样式与日志 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
readonly COMMON_VERSION="${HAO_RELEASE:-dev-standalone}"
readonly DEPLOY_LOG_DIR="/var/log/vps-deploy"

setup_logging() {
    local script_name="${1:-maintenance}"
    mkdir -p "$DEPLOY_LOG_DIR"
    DEPLOY_LOG_FILE="${DEPLOY_LOG_DIR}/${script_name}-$(date +%Y%m%d-%H%M%S).log"
    exec > >(tee -a "$DEPLOY_LOG_FILE") 2>&1
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] === 日志开始: $DEPLOY_LOG_FILE ==="
}

log_info()    { echo -e "${BLUE}[INFO]${NC} $(date '+%H:%M:%S') $*" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $(date '+%H:%M:%S') $*" >&2; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $(date '+%H:%M:%S') $*" >&2; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*" >&2; }
log_step()    { echo -e "${CYAN}[STEP]${NC} $(date '+%H:%M:%S') $*" >&2; }

print_header() {
    clear 2>/dev/null || true
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}   Maintenance 基础维护 ${COMMON_VERSION}${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

check_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        echo -e "${RED}[ERROR] 必须使用 root 权限运行此脚本。${NC}"
        exit 1
    fi
}

is_noninteractive() {
    [ "${HAO_UNATTENDED:-}" = "1" ]
}

confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local response

    if [ "$default" = "y" ]; then
        read -r -p "$prompt [Y/n]: " response
    else
        read -r -p "$prompt [y/N]: " response
    fi
    response="${response:-$default}"

    case "$response" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

show_help() {
    cat <<EOF
Maintenance 基础维护脚本 ${COMMON_VERSION}

用法:
  sudo ./install.sh

内容:
  - fail2ban SSH 防护
  - swap 自动配置
  - journald 日志限制
  - Docker 日志轮转

环境变量:
  HAO_SWAP_SIZE_MB=2048           # 强制指定 swap 大小，单位 MB
  HAO_DISABLE_SWAP=1              # 跳过 swap 创建
  HAO_RESTART_DOCKER=1            # 有运行容器时也重启 Docker
EOF
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        -h|--help) show_help ;;
        *) log_error "未知参数: $arg"; exit 1 ;;
    esac
done

# ==================== 系统与包管理 ====================

detect_os() {
    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        echo "${ID:-unknown}"
    else
        echo "unknown"
    fi
}

install_packages() {
    local os
    os=$(detect_os)

    case "$os" in
        debian|ubuntu)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y "$@"
            ;;
        centos|rhel|rocky|almalinux)
            if command -v dnf &>/dev/null; then
                dnf install -y "$@"
            else
                yum install -y "$@"
            fi
            ;;
        fedora)
            dnf install -y "$@"
            ;;
        *)
            log_error "暂不支持的系统: $os，请手动安装: $*"
            return 1
            ;;
    esac
}

# ==================== fail2ban ====================

detect_ssh_ports() {
    local ports=""

    if command -v sshd &>/dev/null; then
        ports=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | sort -n -u | paste -sd, - || true)
    fi

    if [ -z "$ports" ]; then
        local files=()
        if [ -f /etc/ssh/sshd_config ]; then
            files+=(/etc/ssh/sshd_config)
        fi
        if compgen -G "/etc/ssh/sshd_config.d/*.conf" >/dev/null; then
            while IFS= read -r file; do
                files+=("$file")
            done < <(find /etc/ssh/sshd_config.d -maxdepth 1 -type f -name '*.conf' | sort)
        fi

        if [ "${#files[@]}" -gt 0 ]; then
            ports=$(grep -hE '^[[:space:]]*Port[[:space:]]+[0-9]+' "${files[@]}" 2>/dev/null \
                | awk '{print $2}' | sort -n -u | paste -sd, - || true)
        fi
    fi

    echo "${ports:-22}"
}

configure_fail2ban() {
    log_step "[1/4] 配置 fail2ban SSH 防护..."

    if ! command -v fail2ban-client &>/dev/null; then
        log_info "安装 fail2ban..."
        install_packages fail2ban
    else
        log_info "fail2ban 已安装"
    fi

    local ssh_ports jail_file
    ssh_ports=$(detect_ssh_ports)
    jail_file="/etc/fail2ban/jail.d/hao-sshd.local"

    mkdir -p /etc/fail2ban/jail.d
    cat > "$jail_file" <<EOF
# Managed by HAO maintenance
[sshd]
enabled = true
port = $ssh_ports
filter = sshd
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF

    if command -v systemctl &>/dev/null; then
        systemctl enable fail2ban >/dev/null 2>&1 || true
        systemctl restart fail2ban || systemctl start fail2ban || true
    fi

    if command -v fail2ban-client &>/dev/null && fail2ban-client status sshd >/dev/null 2>&1; then
        log_success "fail2ban SSH 防护已启用 (端口: $ssh_ports)"
    else
        log_warning "fail2ban 已配置，但 sshd jail 状态暂不可用，请检查: fail2ban-client status sshd"
    fi
}

# ==================== swap ====================

active_swap_exists() {
    swapon --show=NAME --noheadings 2>/dev/null | grep -q . && return 0
    awk 'NR > 1 {found = 1} END {exit found ? 0 : 1}' /proc/swaps 2>/dev/null
}

detect_memory_mb() {
    awk '/MemTotal/ {print int(($2 + 1023) / 1024)}' /proc/meminfo
}

choose_swap_size_mb() {
    local mem_mb swap_mb raw

    if [ "${HAO_DISABLE_SWAP:-}" = "1" ]; then
        echo 0
        return 0
    fi

    raw="${HAO_SWAP_SIZE_MB:-}"
    if [ -n "$raw" ]; then
        if [[ "$raw" =~ ^[0-9]+$ ]] && [ "$raw" -gt 0 ]; then
            echo "$raw"
            return 0
        fi
        log_error "HAO_SWAP_SIZE_MB 必须是正整数，当前值: $raw"
        exit 1
    fi

    mem_mb=$(detect_memory_mb)
    if [ "$mem_mb" -le 2048 ]; then
        swap_mb=2048
    elif [ "$mem_mb" -le 4096 ]; then
        swap_mb=4096
    else
        if is_noninteractive; then
            swap_mb=0
        elif confirm "检测到内存约 ${mem_mb}MB，是否仍创建 4GB swap？" "n"; then
            swap_mb=4096
        else
            swap_mb=0
        fi
    fi

    echo "$swap_mb"
}

configure_swap_sysctl() {
    local sysctl_file="/etc/sysctl.d/99-hao-swap.conf"

    cat > "$sysctl_file" <<EOF
# Managed by HAO maintenance
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF

    sysctl -p "$sysctl_file" >/dev/null 2>&1 || true
    log_success "swap sysctl 参数已配置"
}

create_swap_file() {
    local size_mb="$1"
    local swap_path="/swapfile"

    if [ "$size_mb" -le 0 ]; then
        log_info "跳过 swap 创建"
        configure_swap_sysctl
        return 0
    fi

    if active_swap_exists; then
        log_success "已检测到活动 swap，跳过创建"
        configure_swap_sysctl
        return 0
    fi

    if [ -e "$swap_path" ]; then
        if file "$swap_path" 2>/dev/null | grep -qi 'swap'; then
            log_info "$swap_path 已存在，尝试启用"
        else
            swap_path="/swapfile.hao"
            log_warning "/swapfile 已存在且不是 swap 文件，改用 $swap_path"
        fi
    fi

    if [ ! -e "$swap_path" ]; then
        log_info "创建 ${size_mb}MB swap 文件: $swap_path"
        if command -v fallocate &>/dev/null; then
            fallocate -l "${size_mb}M" "$swap_path" || dd if=/dev/zero of="$swap_path" bs=1M count="$size_mb" status=none
        else
            dd if=/dev/zero of="$swap_path" bs=1M count="$size_mb" status=none
        fi
        chmod 600 "$swap_path"
        mkswap "$swap_path" >/dev/null
    fi

    chmod 600 "$swap_path"
    swapon "$swap_path" || true

    if ! grep -qsE "^[[:space:]]*${swap_path//\//\/}[[:space:]]+" /etc/fstab; then
        echo "$swap_path none swap sw 0 0" >> /etc/fstab
    fi

    if active_swap_exists; then
        log_success "swap 已启用: $swap_path"
    else
        log_warning "swap 启用失败，请手动检查: swapon --show"
    fi

    configure_swap_sysctl
}

configure_swap() {
    log_step "[2/4] 配置 swap..."
    local swap_mb
    swap_mb=$(choose_swap_size_mb)
    create_swap_file "$swap_mb"
}

# ==================== journald ====================

configure_journald() {
    log_step "[3/4] 配置 journald 日志限制..."

    local conf_dir="/etc/systemd/journald.conf.d"
    local conf_file="$conf_dir/hao.conf"

    mkdir -p "$conf_dir"
    cat > "$conf_file" <<EOF
# Managed by HAO maintenance
[Journal]
SystemMaxUse=500M
RuntimeMaxUse=100M
MaxRetentionSec=14day
EOF

    if command -v systemctl &>/dev/null; then
        systemctl restart systemd-journald || true
    fi

    log_success "journald 日志限制已配置: $conf_file"
}

# ==================== Docker 日志轮转 ====================

write_docker_daemon_json() {
    local daemon_file="/etc/docker/daemon.json"
    local backup_file=""

    mkdir -p /etc/docker

    if [ -f "$daemon_file" ]; then
        backup_file="${daemon_file}.bak.$(date +%Y%m%d_%H%M%S)"
        cp -a "$daemon_file" "$backup_file"
        log_info "已备份 Docker daemon.json: $backup_file"
    fi

    if command -v python3 &>/dev/null; then
        if ! python3 - "$daemon_file" <<'PY'
import json
import os
import sys

path = sys.argv[1]
data = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
if not isinstance(data, dict):
    raise SystemExit("daemon.json root must be an object")

data["log-driver"] = "json-file"
log_opts = data.get("log-opts")
if not isinstance(log_opts, dict):
    log_opts = {}
log_opts["max-size"] = "50m"
log_opts["max-file"] = "3"
data["log-opts"] = log_opts

with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
        then
            log_warning "Docker daemon.json 不是有效 JSON，已保留备份并跳过写入。"
            [ -n "$backup_file" ] && cp -a "$backup_file" "$daemon_file"
            return 1
        fi
    elif [ -f "$daemon_file" ]; then
        log_warning "缺少 python3，且 daemon.json 已存在；为避免覆盖现有配置，跳过 Docker 日志轮转写入。"
        return 1
    else
        cat > "$daemon_file" <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  }
}
EOF
    fi

    log_success "Docker 日志轮转已配置: $daemon_file"
}

restart_docker_if_safe() {
    if ! command -v systemctl &>/dev/null || ! systemctl list-unit-files docker.service >/dev/null 2>&1; then
        log_info "Docker 未安装，已预置配置，安装 Docker 后自动生效"
        return 0
    fi

    if ! systemctl is-active --quiet docker 2>/dev/null; then
        log_info "Docker 当前未运行，配置将在下次启动时生效"
        return 0
    fi

    local running_containers=""
    if command -v docker &>/dev/null; then
        running_containers=$(docker ps -q 2>/dev/null || true)
    fi

    if [ -n "$running_containers" ] && [ "${HAO_RESTART_DOCKER:-}" != "1" ]; then
        if is_noninteractive || ! confirm "检测到运行中的容器，是否立即重启 Docker 以应用日志轮转？" "n"; then
            log_warning "已跳过 Docker 重启；新配置将在下次重启 Docker 后生效。"
            return 0
        fi
    fi

    systemctl restart docker || log_warning "Docker 重启失败，请稍后手动执行: systemctl restart docker"
}

configure_docker_logs() {
    log_step "[4/4] 配置 Docker 日志轮转..."

    if write_docker_daemon_json; then
        restart_docker_if_safe
    fi
}

# ==================== 主流程 ====================

main() {
    check_root
    setup_logging "maintenance-install"
    print_header

    configure_fail2ban
    configure_swap
    configure_journald
    configure_docker_logs

    mkdir -p /var/lib/hao
    cat > /var/lib/hao/maintenance.installed <<EOF
# Managed by HAO
# Service: maintenance
installed_at=$(date '+%Y-%m-%d %H:%M:%S')
release=${COMMON_VERSION}
fail2ban_jail=/etc/fail2ban/jail.d/hao-sshd.local
journald_conf=/etc/systemd/journald.conf.d/hao.conf
docker_daemon=/etc/docker/daemon.json
EOF

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}   Maintenance 配置完成！${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${CYAN}[检查命令]${NC}"
    echo "fail2ban-client status sshd"
    echo "swapon --show"
    echo "journalctl --disk-usage"
    echo "cat /etc/docker/daemon.json"
    echo ""
    log_success "日志已保存: $DEPLOY_LOG_FILE"
}

main "$@"
