# shellcheck shell=bash
#
# science/lib/bbr.sh —— 工具三：BBR 拥塞控制。
#
# 单独一个工具而不是塞进入站安装流程，理由和仓库里 fail2ban/swap/journald 拆开一样：
# 它是主机级调优，和代理没有依赖关系，要能独立装、独立卸、独立漂移检查。
# 跨太平洋的链路丢包时 BBR 对吞吐提升明显，所以值得单独提供。

BBR_SERVICE="bbr"
BBR_SYSCTL_FILE="/etc/sysctl.d/99-bbr.conf"
# nginx 模块写的那个文件里也含 BBR 两行。两个文件都设成 bbr 不冲突，
# 但没必要多写一个，检测到就跳过。
NGINX_SYSCTL_FILE="/etc/sysctl.d/99-vps-optimize.conf"

bbr_usage() {
    cat >&2 <<'EOF'
用法: sudo ./install.sh bbr

写 /etc/sysctl.d/99-bbr.conf 打开 BBR + fq，然后回读确认是否真的生效。
需要内核 >= 4.9。已经由别的模块打开过就跳过。
EOF
}

bbr_current() { sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown; }

cmd_bbr() {
    case "${1:-}" in
        -h|--help) bbr_usage; return 0 ;;
        "") ;;
        *) bbr_usage; die "未知参数: $1" ;;
    esac

    require_root
    require_skill_scripts

    local current
    current="$(bbr_current)"
    log_info "当前拥塞控制算法: $current"

    if [ "$current" = "bbr" ] && [ ! -f "$BBR_SYSCTL_FILE" ]; then
        if [ -f "$NGINX_SYSCTL_FILE" ]; then
            log_success "BBR 已经由 $NGINX_SYSCTL_FILE 打开（HAO 的 nginx 模块写的），不重复写文件"
        else
            log_success "BBR 已经开着，且不是本工具写的配置，不动它"
        fi
        return 0
    fi

    case "$(guard managed-file "$BBR_SYSCTL_FILE")" in
        missing|"managed "*) ;;
        *) die "$BBR_SYSCTL_FILE 存在但不是本工具写的，不覆盖。" ;;
    esac

    log_step "即将做的事"
    cat >&2 <<EOF
  写 $BBR_SYSCTL_FILE（net.core.default_qdisc=fq，net.ipv4.tcp_congestion_control=bbr）
  然后 sysctl -p 让它立即生效，并回读确认。

  影响全机所有 TCP 连接（通常是变快，不会更慢）。卸载就是删那个文件后重启。
EOF
    confirm "继续？" || die "已取消，什么都没改。"

    modprobe tcp_bbr 2>/dev/null || true
    install_template "sysctl-bbr.conf" "$BBR_SYSCTL_FILE" 0644
    sysctl -p "$BBR_SYSCTL_FILE" >/dev/null 2>&1 || log_warning "sysctl -p 报错，下面回读实际值"

    current="$(bbr_current)"
    if [ "$current" = "bbr" ]; then
        log_success "BBR 已生效（net.ipv4.tcp_congestion_control = bbr）"
        log_info "队列调度: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
    else
        log_warning "BBR 没有生效，当前仍是 $current。内核版本 $(uname -r)，BBR 需要 >= 4.9。"
        log_warning "如实说明：配置文件写了，但这台机器上没起作用。"
    fi

    state record "$BBR_SERVICE" installed "managed:$BBR_SYSCTL_FILE"
    state intent "$BBR_SERVICE" congestion_control="$current" qdisc=fq
    state handoff
}
