# shellcheck shell=bash
#
# science/lib/core.sh —— xray 基座：二进制、systemd 单元、conf.d、共用配置、geo 数据。
#
# 三个入站工具（reality / httpsproxy）都先调 ensure_xray_core。已就绪则 no-op。
# 这一层单独记 xray-core 状态：卸载最后一个入站时可以选择连基座一起删。

# 固定版本，不查 GitHub 的 "latest" API：那个结果随时间漂移，同一份脚本两周后
# 装出来的东西就不一样了；而且限流/网络故障时容易退化成一个陈旧的兜底值。
# 需要别的版本用 HAO_XRAY_VERSION=vX.Y.Z，但校验和就对不上了（见下）。
XRAY_VERSION_DEFAULT="v26.3.27"

# 固定版本的 zip SHA256（取自上游 release 的 .dgst 文件）。
# 下载后必须校验：只信 HTTPS 等于「拿到的东西是 github.com 给的」，
# 不等于「拿到的东西是我们预期的那个构建」。
XRAY_SHA256_linux_64="23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae"
XRAY_SHA256_linux_arm64_v8a="4d30283ae614e3057f730f67cd088a42be6fdf91f8639d82cb69e48cde80413c"

expected_sha256_for_arch() {
    local arch="$1"
    case "$arch" in
        linux-64)          printf '%s' "$XRAY_SHA256_linux_64" ;;
        linux-arm64-v8a)   printf '%s' "$XRAY_SHA256_linux_arm64_v8a" ;;
        *)                 printf '' ;;
    esac
}

# ==================== 二进制 ====================
install_xray_binary() {
    local version="${HAO_XRAY_VERSION:-$XRAY_VERSION_DEFAULT}"
    local arch url tmpdir expected actual

    arch="$(detect_arch)"
    [ "$arch" != "unknown" ] && [ -n "$arch" ] \
        || die "不支持的 CPU 架构: $(uname -m)（支持 x86_64 与 aarch64）"

    if xray_present; then
        local current
        current="$(xray_version || true)"
        log_info "xray 已安装：${current:-未知版本}（不重复下载）"
        # 版本对不上就说出来，别让用户以为装的是固定的那个版本。
        # 不自动换掉现有二进制：那可能是别人装的，换掉会打断正在跑的服务。
        case "$current" in
            *"${version#v}"*) ;;
            *) log_warning "现有版本和本脚本固定的 $version 不一致。要换成固定版本：先 systemctl stop xray && rm -f $XRAY_BIN，再重跑。" ;;
        esac
        return 0
    fi

    log_step "下载 Xray-core $version ($arch)"
    url="https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-${arch}.zip"

    tmpdir="$(make_tmpdir)"
    # shellcheck disable=SC2064  # 现在就要展开 tmpdir，函数返回后变量就没了
    trap "rm -rf '$tmpdir'" RETURN

    curl -fL --connect-timeout 20 --max-time 300 -o "$tmpdir/xray.zip" "$url" \
        || die "下载失败: $url（网络不通？版本号写错？）"

    expected="$(expected_sha256_for_arch "$arch")"
    actual="$(sha256sum "$tmpdir/xray.zip" | awk '{print $1}')"
    if [ -z "$expected" ]; then
        log_warning "没有 $arch 的预期校验和，跳过校验（下载自 GitHub releases）"
    elif [ "$version" != "$XRAY_VERSION_DEFAULT" ]; then
        log_warning "用了非默认版本 $version，内置校验和对应的是 $XRAY_VERSION_DEFAULT，跳过校验"
        log_warning "实际 SHA256: $actual —— 自己去上游的 .dgst 文件核对一下"
    elif [ "$actual" != "$expected" ]; then
        die "校验和不匹配！预期 $expected，实际 $actual。不安装这个文件 —— 可能是下载损坏或被篡改。"
    else
        log_success "校验和匹配（SHA256）"
    fi

    require_cmds unzip
    unzip -o -q "$tmpdir/xray.zip" -d "$tmpdir/x" || die "解压失败"
    [ -f "$tmpdir/x/xray" ] || die "压缩包里没有 xray 可执行文件"

    install -m 0755 "$tmpdir/x/xray" "$XRAY_BIN"
    log_success "已安装 $XRAY_BIN：$(xray_version || echo '版本读取失败')"

    # geo 数据放上游约定的 asset 目录，单元里的 XRAY_LOCATION_ASSET 指向它
    install -d -m 0755 "$XRAY_ASSET_DIR"
    if [ -f "$tmpdir/x/geoip.dat" ]; then
        install -m 0644 "$tmpdir/x/geoip.dat" "$XRAY_ASSET_DIR/geoip.dat"
        install -m 0644 "$tmpdir/x/geosite.dat" "$XRAY_ASSET_DIR/geosite.dat"
        log_success "geoip.dat / geosite.dat 已就位（随发行包提供，无需另外下载）"
    else
        log_warning "发行包里没有 geo 数据，routing 的 geoip:private 规则会失效"
        log_warning "手工补：curl -fLo $XRAY_ASSET_DIR/geoip.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
    fi
}

# ==================== 单元与目录 ====================
# 归属检查：官方安装脚本和本工具旧版本写的 unit 都没有 HAO 头，都会判成 foreign。
# 那是对的，不能默默覆盖 —— 旧版本的机器走显式的 `install.sh migrate`。
require_unit_ownership() {
    local result
    result="$(guard unit-free xray)"
    case "$result" in
        free)
            log_info "xray.service 不存在，将新建"
            ;;
        "hao "*)
            log_info "xray.service 由本工具管理（$result），可原地更新"
            ;;
        foreign*)
            log_error "/etc/systemd/system/xray.service 已存在，但不是本工具写的（$result）。"
            if [ -f "$XRAY_LEGACY_CONF" ]; then
                log_error "同时发现旧版单文件配置 $XRAY_LEGACY_CONF —— 这台机器是旧版本装的。"
                die "先跑迁移，它会保留现有密钥和 UUID（客户端不用改）： sudo $0 migrate"
            fi
            die "可能是 Xray 官方安装脚本装的。不覆盖别人的东西。要接管就先自己停掉并移走那个单元，或换一台机器。"
            ;;
        *)
            die "无法判断 xray.service 归属: $result"
            ;;
    esac
}

install_xray_unit() {
    install -d -m 0755 "$XRAY_LOG_DIR"
    # conf.d 是 0700：里面的入站片段含私钥和口令，同机其他用户连文件名都不该列出。
    install -d -m 0755 "$XRAY_ETC"
    install -d -m 0700 "$XRAY_CONF_DIR"
    install_template "xray.service" "$XRAY_UNIT" 0644
    systemctl daemon-reload
}

install_base_config() {
    local target="$XRAY_CONF_DIR/00-base.json"
    case "$(guard managed-file "$target")" in
        missing|"managed "*) ;;
        foreign) die "$target 存在但不是本工具写的。不覆盖。" ;;
    esac
    install_template "00-base.json" "$target" 0644
}

# ==================== 对外入口 ====================
# 幂等：装好了就什么都不做。每个入站工具进来先调它。
ensure_xray_core() {
    log_step "检查 xray 基座"
    require_unit_ownership
    install_xray_binary
    install_xray_unit
    install_base_config

    local -a resources=(
        "managed:$XRAY_BIN"
        "managed:$XRAY_UNIT"
        "managed:$XRAY_CONF_DIR/00-base.json"
    )
    [ -f "$XRAY_ASSET_DIR/geoip.dat" ]   && resources+=("observed:$XRAY_ASSET_DIR/geoip.dat")
    [ -f "$XRAY_ASSET_DIR/geosite.dat" ] && resources+=("observed:$XRAY_ASSET_DIR/geosite.dat")

    state record xray-core installed "${resources[@]}" >/dev/null
    state intent xray-core \
        version="${HAO_XRAY_VERSION:-$XRAY_VERSION_DEFAULT}" \
        config_layout=confdir >/dev/null
    log_success "xray 基座就绪"
}
