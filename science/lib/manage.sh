# shellcheck shell=bash
#
# science/lib/manage.sh —— status / migrate / uninstall。
#
# migrate 存在的理由：旧版本装出来的是单文件 config.json + `-config` 启动的单元，
# 而且单元里没有 `# Managed by HAO` 头，所以 hao-guard.sh 会把它判成 foreign
# （这是对的——不能默默覆盖别人的东西）。旧机器要升级就得有一条显式的路。

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
    if [ -f "$XRAY_LEGACY_CONF" ]; then
        echo "  ⚠ 发现旧版单文件配置 $XRAY_LEGACY_CONF —— 跑 'sudo $0 migrate' 迁到 conf.d 布局"
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

# ==================== migrate ====================
cmd_migrate() {
    case "${1:-}" in
        ""|-h|--help) ;;
        *) die "migrate 不接受参数" ;;
    esac

    require_root
    require_skill_scripts
    require_os
    require_cmds curl openssl systemctl ss

    [ -f "$XRAY_LEGACY_CONF" ] \
        || die "没有找到旧版配置 $XRAY_LEGACY_CONF，不需要迁移。直接用 'reality' 或 'proxy' 子命令。"

    log_step "从旧版单文件布局迁移到 conf.d"
    cat >&2 <<EOF
  旧布局：$XRAY_LEGACY_CONF 一个文件装所有入站，单元用 -config 启动。
  新布局：$XRAY_CONF_DIR/ 下每个入站一个文件，单元用 -confdir 启动。
          这样装一个入站不用重写另一个，卸一个只需删文件。

  会做的事：
    1. 从旧配置里读出 Reality 的私钥 / UUID / shortId，**原样保留**
       —— 你现有的客户端配置不用改
    2. 写进 $(cred_file xray-reality)（0600）
    3. 写新单元和 $XRAY_CONF_DIR/{00-base.json,10-reality.json}
    4. xray run -test 通过后才重启
    5. 旧配置改名成 ${XRAY_LEGACY_CONF}.pre-confdir.bak（不删）
EOF
    confirm "继续迁移？" || die "已取消，什么都没改。"

    local tmpdir
    tmpdir="$(make_tmpdir)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" EXIT

    # 从旧配置提取三个值，直接写进临时文件，不经过 shell 变量。
    sed -n 's/.*"privateKey"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$XRAY_LEGACY_CONF" | head -1 > "$tmpdir/private"
    sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'         "$XRAY_LEGACY_CONF" | head -1 > "$tmpdir/uuid"
    sed -n 's/.*"shortIds"[[:space:]]*:[[:space:]]*\["\([^"]*\)".*/\1/p' "$XRAY_LEGACY_CONF" | head -1 > "$tmpdir/shortid"

    local port sni
    port="$(sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\([0-9]\{1,5\}\).*/\1/p' "$XRAY_LEGACY_CONF" | head -1)"
    sni="$(sed -n 's/.*"serverNames"[[:space:]]*:[[:space:]]*\["\([^"]*\)".*/\1/p' "$XRAY_LEGACY_CONF" | head -1)"
    port="${port:-8443}"
    sni="${sni:-www.microsoft.com}"

    local f
    for f in private uuid shortid; do
        [ -s "$tmpdir/$f" ] \
            || die "从 $XRAY_LEGACY_CONF 里读不出 $f。这个配置可能不是本工具装的，停下来人工看一眼，不要自动改。"
    done
    log_success "已从旧配置读出密钥、UUID、shortId（端口 $port，伪装 $sni）"

    # 公钥必须从私钥推导——这是唯一一处不得不把密钥放进命令行参数的地方。
    # 另一条路是重新生成密钥，那会让用户所有现有客户端立刻失效，代价更大。
    # 只在迁移时执行一次（旧版本是每次重跑都执行），之后公钥就存进凭据文件了。
    #
    # 二进制先装好：旧机器上一般已经有了，但万一被删过，这里得能自己补上
    # （不能反过来让用户去跑 reality 子命令 —— 那个会因为旧单元是 foreign 而停下）。
    install_xray_binary
    log_warning "接下来要用 'xray x25519 -i <私钥>' 推导公钥。那一瞬间私钥会出现在进程的命令行参数里"
    log_warning "（同机其他用户可从 /proc/<pid>/cmdline 读到）。这是保留你现有客户端的代价，且只做这一次。"
    xray_present || die "$XRAY_BIN 装不上，无法推导公钥。先解决下载问题再迁移。"
    "$XRAY_BIN" x25519 -i "$(cat "$tmpdir/private")" 2>/dev/null \
        | awk '/^Password \(PublicKey\):/ { print $NF } /^PublicKey:/ { print $NF }' \
        | head -1 > "$tmpdir/public" || true
    [ -s "$tmpdir/public" ] || die "推导公钥失败。私钥格式不对，或 xray x25519 的输出格式变了。"
    log_success "公钥已推导并写入凭据文件，以后不会再需要这一步"

    secret write "$(cred_file xray-reality)" \
        "PRIVATE_KEY=@file:$tmpdir/private" \
        "PUBLIC_KEY=@file:$tmpdir/public" \
        "UUID=@file:$tmpdir/uuid" \
        "SHORT_ID=@file:$tmpdir/shortid" \
        --rotate PRIVATE_KEY,PUBLIC_KEY,UUID,SHORT_ID

    # 旧单元没有 HAO 头，unit-free 会判 foreign。这里是显式迁移，允许覆盖，
    # 所以直接装模板，不再走 require_unit_ownership。
    # （二进制在上面推导公钥之前就已经确保装好了。）
    log_step "写入新单元与配置"
    install_xray_unit
    install_base_config

    reality_write_fragment "$port" "$sni"
    if ! xray_test_config; then
        die "新配置测试未通过。旧配置还在原处（$XRAY_LEGACY_CONF），已写入的新文件需要你人工看一眼再决定。"
    fi
    mv "$XRAY_LEGACY_CONF" "${XRAY_LEGACY_CONF}.pre-confdir.bak"
    log_success "旧配置已备份为 ${XRAY_LEGACY_CONF}.pre-confdir.bak"

    xray_apply "$port" || die "迁移后服务没能起来。旧配置在 ${XRAY_LEGACY_CONF}.pre-confdir.bak，可以人工回退。"
    reality_write_client_info "$port" "$sni"

    state record xray-core installed \
        "managed:$XRAY_BIN" "managed:$XRAY_UNIT" "managed:$XRAY_CONF_DIR/00-base.json"
    state record xray-reality installed \
        "managed:$XRAY_CONF_DIR/$REALITY_FRAGMENT_NAME" \
        "secret:$(cred_file xray-reality)" \
        "secret:$(client_file xray-reality)"
    state intent xray-reality protocol=vless-reality port="$port" sni="$sni" flow=xtls-rprx-vision
    state handoff

    log_success "迁移完成，凭据和 UUID 都没变，现有客户端继续可用"
}

# ==================== uninstall ====================
uninstall_usage() {
    cat >&2 <<'EOF'
用法: sudo ./install.sh uninstall <reality|proxy|bbr|core|all>

  reality   删 Reality 入站配置 + 它的凭据，重启 xray
  proxy     删 HTTPS 代理入站配置 + 它的凭据，重启 xray（证书不删）
  bbr       删 /etc/sysctl.d/99-bbr.conf（重启后恢复默认拥塞控制）
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
        if [ "$remaining" -gt 0 ]; then
            die "还有 $remaining 个入站配置在用这个基座，先卸掉它们（uninstall reality / proxy）再卸 core。"
        fi
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
