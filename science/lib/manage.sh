# shellcheck shell=bash
#
# science/lib/manage.sh —— status 与 uninstall。

# ==================== status ====================
cmd_status() {
    case "${1:-}" in
        ""|-h|--help) ;;
        *) die "status 不接受参数" ;;
    esac
    require_skill_scripts

    echo "== xray =="
    if xray_present; then
        echo "  二进制: $XRAY_BIN ($(xray_version || echo '版本读取失败'))"
    else
        echo "  二进制: 未安装"
    fi
    if [ -f "$XRAY_UNIT" ]; then
        echo "  单元:   $XRAY_UNIT ($(guard managed-file "$XRAY_UNIT"))"
        echo "  运行:   $(systemctl is-active xray 2>/dev/null || echo inactive) / $(systemctl is-enabled xray 2>/dev/null || echo disabled)"
    else
        echo "  单元:   未安装"
    fi

    echo ""
    echo "== 入站配置 (conf.d) =="
    local frag
    if [ -d "$XRAY_CONF_DIR" ]; then
        for frag in "$XRAY_CONF_DIR"/*.json; do
            [ -f "$frag" ] || continue
            # 只列文件名和归属，绝不打印内容（里面有私钥和口令）
            printf '  %-24s %s\n' "$(basename "$frag")" "$(guard managed-file "$frag")"
        done
    else
        echo "  （没有 $XRAY_CONF_DIR）"
    fi

    echo ""
    echo "== 端口 =="
    ss -tlnp 2>/dev/null | grep -E 'xray' || echo "  （没有 xray 在监听）"

    echo ""
    echo "== 凭据文件（只列路径，不打印内容）=="
    local svc f
    for svc in xray-reality xray-httpsproxy; do
        for f in "$(cred_file "$svc")" "$(client_file "$svc")"; do
            [ -f "$f" ] && printf '  %s (%s)\n' "$f" "$(stat -c '%a' "$f")"
        done
    done

    echo ""
    echo "== BBR =="
    echo "  拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"

    echo ""
    echo "== HAO 状态记录 =="
    state services 2>/dev/null | grep -E 'xray|bbr|SERVICE' || echo "  （状态里没有相关记录）"
}

# ==================== uninstall ====================
uninstall_usage() {
    cat >&2 <<'EOF'
用法: sudo ./install.sh uninstall <reality|proxy|bbr|core|all>

  reality   删 Reality 入站配置 + 它的凭据，重启 xray
  proxy     删 HTTPS 代理入站配置 + 它的凭据，重启 xray（证书不删）
  bbr       删 /etc/sysctl.d/99-hao-bbr.conf（重启后恢复默认拥塞控制）
  core      删 xray 二进制、单元、conf.d、日志。要求入站已经全部卸掉
  all       上面全部

删之前会列出要删的东西并要求确认。证书一律不删（可能有别的服务在用），
要停止续期用 certbot 自己的命令: certbot delete --cert-name <域名>
EOF
}

# 删一个入站：删配置片段 + 凭据 + 状态记录，然后重启（若还有别的入站）
uninstall_inbound() {
    local svc="$1" fragment="$2" label="$3"
    local frag_path="$XRAY_CONF_DIR/$fragment"
    local -a targets=()

    [ -f "$frag_path" ] && targets+=("$frag_path")
    [ -f "$(cred_file "$svc")" ]   && targets+=("$(cred_file "$svc")")
    [ -f "$(client_file "$svc")" ] && targets+=("$(client_file "$svc")")

    if [ "${#targets[@]}" -eq 0 ] && [ ! -f "$STATE_SERVICES_DIR/$svc.json" ]; then
        log_info "$label 没有安装，跳过"
        return 0
    fi

    log_step "将删除 $label 的这些文件"
    local t
    for t in "${targets[@]}"; do echo "  $t" >&2; done
    log_warning "凭据文件删掉之后，那个账号/UUID 就找不回来了。需要留就先自己 sudo cat 出来存好。"
    confirm "确认删除？" || { log_info "已跳过 $label"; return 0; }

    for t in "${targets[@]}"; do
        rm -f "$t"
        log_success "已删 $t"
    done
    rm -f "$STATE_SERVICES_DIR/$svc.json" "$STATE_SERVICES_DIR/$svc.resources" "$STATE_SERVICES_DIR/$svc.intent"
    log_success "已清除 $svc 的状态记录"
}

cmd_uninstall() {
    local what="${1:-}"
    case "$what" in
        reality|proxy|bbr|core|all) ;;
        -h|--help|"") uninstall_usage; return 0 ;;
        *) uninstall_usage; die "不认识的卸载目标: $what" ;;
    esac

    require_root
    require_skill_scripts

    if [ "$what" = "reality" ] || [ "$what" = "all" ]; then
        uninstall_inbound xray-reality "$REALITY_FRAGMENT_NAME" "Reality 入站"
    fi
    if [ "$what" = "proxy" ] || [ "$what" = "all" ]; then
        uninstall_inbound xray-httpsproxy "$HTTPSPROXY_FRAGMENT_NAME" "HTTPS 代理入站"
        if [ -f "$RENEWAL_HOOK" ] && [ "$(guard managed-file "$RENEWAL_HOOK")" != "foreign" ]; then
            rm -f "$RENEWAL_HOOK"
            log_success "已删 $RENEWAL_HOOK"
        fi
        log_info "证书没有删。要停止续期： certbot delete --cert-name <域名>"
    fi

    if [ "$what" = "bbr" ] || [ "$what" = "all" ]; then
        if [ -f "$BBR_SYSCTL_FILE" ]; then
            log_step "将删除 $BBR_SYSCTL_FILE"
            log_info "注意：删文件不会立刻改回算法，重启后才恢复默认（或手工 sysctl -w）。"
            if confirm "确认删除？"; then
                rm -f "$BBR_SYSCTL_FILE"
                rm -f "$STATE_SERVICES_DIR/$BBR_SERVICE".{json,resources,intent}
                log_success "已删 $BBR_SYSCTL_FILE 并清除状态"
            fi
        else
            log_info "没有 $BBR_SYSCTL_FILE，跳过"
        fi
    fi

    # 还有入站活着就重启让删除生效；一个都不剩了就停服务。
    # 这个计数是**删除之后**的实际剩余量，所以下面 core 那一步可以直接用它判断
    # 「基座还有没有人在用」——包括用户中途在确认提示里选了 n 而没真删的情况。
    local remaining
    remaining="$(inbound_fragments | wc -l)"

    # 先把「卸 core 但还有人在用」这一支拦掉，再决定要不要重启。
    # 反过来的话（以前就是）会白重启一次 xray：连接被打断，然后才告诉用户
    # 「先卸掉入站再来」——那次重启对谁都没有用。
    if { [ "$what" = "core" ] || [ "$what" = "all" ]; } && [ "$remaining" -gt 0 ]; then
        die "还有 $remaining 个入站配置在用这个基座，先卸掉它们（uninstall reality / proxy）再卸 core。"
    fi

    if [ -x "$XRAY_BIN" ] && [ -f "$XRAY_UNIT" ]; then
        if [ "$remaining" -gt 0 ]; then
            log_info "还剩 $remaining 个入站配置，重启 xray 让删除生效"
            xray_apply || log_warning "重启后状态异常，用 'systemctl status xray' 看一眼"
        else
            log_info "没有入站配置了，停掉 xray"
            systemctl disable --now xray >/dev/null 2>&1 || true
        fi
    fi

    if [ "$what" = "core" ] || [ "$what" = "all" ]; then
        log_step "将删除 xray 基座"
        cat >&2 <<EOF
  $XRAY_BIN
  $XRAY_UNIT
  $XRAY_ETC/            （整个目录，含 conf.d）
  $XRAY_ASSET_DIR/      （geoip.dat / geosite.dat）
  $XRAY_LOG_DIR/        （日志）
EOF
        if confirm "确认删除？"; then
            systemctl disable --now xray >/dev/null 2>&1 || true
            rm -f "$XRAY_UNIT"
            systemctl daemon-reload
            rm -f "$XRAY_BIN"
            rm -rf "$XRAY_ETC" "$XRAY_ASSET_DIR" "$XRAY_LOG_DIR"
            rm -f "$STATE_SERVICES_DIR/xray-core".{json,resources,intent}
            log_success "xray 基座已删除"
        fi
    fi

    state handoff
    log_success "状态记录已刷新（hao-state.sh handoff）"
}
