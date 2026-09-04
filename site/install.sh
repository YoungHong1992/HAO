#!/bin/bash
# shellcheck disable=SC2034

################################################################################
#
# site —— 通用「从 Git 仓库部署自有站点」脚本
# 发布标识由 HAO_RELEASE 提供
#
# 功能说明：
#   支持在 HAO_SITES 中声明多个站点，每个站点一组 HAO_SITE_<ID>_* 变量：
#   1. 以目标用户克隆/更新仓库到 /opt/hao-sites/<id>（非 Git 目录或仓库不一致时拒绝覆盖）
#   2. static 类型：可选构建命令（目标用户执行，CI=true），产物发布到 /var/www/hao-sites/<id>
#   3. node 类型：生成 systemd 单元 hao-site-<id>.service（含加固项），启动并等待端口就绪
#   4. 生成 Nginx 虚拟主机 /etc/nginx/conf.d/hao-site-<id>.conf：
#      - 设置 DOMAIN 时按域名服务，可申请 Let's Encrypt 证书（acme.sh webroot，ECC）
#      - 真实证书签发后默认启用 80->443 跳转（可用 REDIRECT=no 关闭；
#        自签名证书时永不跳转，80 端口直接提供服务）
#      - 未设置 DOMAIN 时使用 80 端口默认站点（server_name _），同一批仅允许一个
#   5. 生成更新脚本 /usr/local/bin/hao-site-update-<id>（拉取 -> 构建/发布/重启 -> 重载 Nginx）
#
# 用法:
#   sudo HAO_SITES="blog" HAO_SITE_BLOG_REPO="..." HAO_SITE_BLOG_TYPE=static ./install.sh
#   ./install.sh -h    # 显示帮助
#
# 配置变量（详见 README.md）：
#   HAO_SITES                    逗号分隔的站点 ID 列表（必填）
#   HAO_SITE_<ID>_REPO           Git 仓库地址（ssh/https）或本地路径 / file://（必填）
#   HAO_SITE_<ID>_TYPE           static | node（必填）
#   HAO_SITE_<ID>_DOMAIN         域名；留空 = 80 端口默认站点，不申请证书
#   HAO_SITE_<ID>_BRANCH         分支，默认 main
#   HAO_SITE_<ID>_BUILD          static：构建命令（在克隆目录内以目标用户执行）
#   HAO_SITE_<ID>_OUTPUT         static：产物目录，默认 build（无 BUILD 时默认 "."）
#   HAO_SITE_<ID>_START          node：入口文件，默认 server.js
#   HAO_SITE_<ID>_PORT           node：监听端口；留空自动从 8100 起分配（重跑时复用既有单元端口）
#   HAO_SITE_<ID>_TARGET_USER    克隆/构建/运行用户，默认 $SUDO_USER，否则 root
#   HAO_SITE_<ID>_CERT           申请 Let's Encrypt 证书，默认 yes（需 DOMAIN）
#   HAO_SITE_<ID>_REDIRECT       80->443 跳转，默认 yes（仅在真实证书签发后生效）
#   HAO_SITE_<ID>_ENV            node：额外环境变量，格式 KEY=VALUE,KEY2=VALUE2
#
# 设计说明：
#   所有配置校验与解析（resolve_all_sites）在 check_root 之前执行，
#   配置错误可在非 root 环境下快速暴露，也便于测试（见 tests/test-site.sh）。
#
# 前置条件：
#   - 已安装 Nginx（可通过 ../nginx/install.sh）
#   - 已安装 Git（可通过 ../git-github/install.sh）
#   - node 类型站点需要 Node.js（请将 node 加入 HAO_SERVICES 或自行安装）
#   - 域名模式需 DNS 已解析到本服务器；启用跳转前请确认云安全组已放行 443/TCP
#
################################################################################

set -euo pipefail

HAO_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HAO_REPO_DIR="$(cd "$HAO_SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$HAO_REPO_DIR/lib/common.sh"

# ==================== 常量 ====================
CONF_D="${HAO_NGINX_CONF_DIR:-/etc/nginx/conf.d}"
SSL_DIR="${HAO_NGINX_SSL_DIR:-/etc/nginx/ssl}"
CLONE_BASE="/opt/hao-sites"
WEB_BASE="/var/www/hao-sites"
UPDATE_BIN_DIR="/usr/local/bin"
NODE_PORT_SCAN_START=8100
NODE_PORT_SCAN_END=8200

# ==================== 帮助 ====================
show_help() {
    cat <<'EOF'
site —— 通用「从 Git 仓库部署自有站点」脚本

用法:
  sudo HAO_SITES="blog" \
       HAO_SITE_BLOG_REPO="git@github.com:me/blog.git" \
       HAO_SITE_BLOG_TYPE="static" \
       HAO_SITE_BLOG_DOMAIN="blog.example.com" \
       ./install.sh
  ./install.sh -h           # 显示此帮助
  ./install.sh --no-prompt  # 与其他模块参数兼容（本脚本本身无交互式确认）

多站点模型:
  HAO_SITES 声明逗号分隔的站点 ID（小写字母/数字/连字符），
  每个站点读取一组 HAO_SITE_<ID>_* 变量（ID 转为大写、连字符转为下划线）。

配置变量:
  HAO_SITES                    站点 ID 列表（必填），如 "blog,tools"
  HAO_SITE_<ID>_REPO           Git 仓库地址（ssh/https）或本地路径 / file://（必填）
  HAO_SITE_<ID>_TYPE           static | node（必填）
  HAO_SITE_<ID>_DOMAIN         域名；留空 = 80 端口默认站点（server_name _），不申请证书
  HAO_SITE_<ID>_BRANCH         分支，默认 main
  HAO_SITE_<ID>_BUILD          static：构建命令（在克隆目录内以目标用户执行，CI=true）
  HAO_SITE_<ID>_OUTPUT         static：产物目录（相对克隆目录），默认 build；
                               未设置 BUILD 时默认 "."（发布仓库根目录，自动排除 .git）
  HAO_SITE_<ID>_START          node：入口文件，默认 server.js
  HAO_SITE_<ID>_PORT           node：监听端口；留空自动从 8100 起分配，
                               幂等重跑时复用既有 systemd 单元中的端口
  HAO_SITE_<ID>_TARGET_USER    克隆/构建/运行的系统用户，默认 $SUDO_USER，否则 root
  HAO_SITE_<ID>_CERT           申请 Let's Encrypt 证书（yes|no），默认 yes（需 DOMAIN）
  HAO_SITE_<ID>_REDIRECT       80->443 跳转（yes|no），默认 yes；
                               仅在真实证书（非自签名）签发后生效。
                               ⚠️ 启用跳转前请确认云安全组已放行 443/TCP，
                               否则跳转后站点将完全不可访问（典型现象：522 超时）
  HAO_SITE_<ID>_ENV            node：额外环境变量，格式 KEY=VALUE,KEY2=VALUE2；
                               端口请用 HAO_SITE_<ID>_PORT 设置，不要在 ENV 中设置 PORT

生成的文件:
  /opt/hao-sites/<id>                      仓库克隆（目标用户所有）
  /var/www/hao-sites/<id>                  static 发布目录
  /etc/systemd/system/hao-site-<id>.service  node systemd 单元（0640）
  /etc/nginx/conf.d/hao-site-<id>.conf     Nginx 虚拟主机
  /usr/local/bin/hao-site-update-<id>      更新脚本（sudo hao-site-update-<id>）

幂等性:
  重复执行安全：仓库 fetch + reset 到指定分支、配置原地重写、
  已签发的真实证书不重复申请。脚本完全非交互（HAO_UNATTENDED=1 兼容）。

环境要求:
  - Root 权限
  - 已安装 Nginx 与 Git；node 类型站点需要 Node.js
EOF
    exit 0
}

die() {
    log_error "$*"
    exit 1
}

# ==================== 参数解析 ====================
# 本脚本配置全部来自环境变量，无交互式确认；HAO_UNATTENDED / HAO_NO_PROMPT 天然兼容。
for arg in "$@"; do
    case "$arg" in
        -h|--help) show_help ;;
        --no-prompt) ;;
        *) echo "[ERROR] 未知参数: $arg（使用 -h 查看帮助）" >&2; exit 1 ;;
    esac
done

# ==================== 通用小工具 ====================
site_prefix() {
    printf '%s' "$1" | tr 'a-z-' 'A-Z_'
}

# 仓库地址可能内嵌凭据（https://user:token@...），日志/报错中只显示脱敏形式
sanitize_repo_url() {
    printf '%s' "$1" | sed -E 's#(://)[^/@]+@#\1***@#'
}

# 将任意字符串转为安全的单引号 shell 字面量（用于生成更新脚本）
shell_quote() {
    local escaped
    escaped="$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
    printf "'%s'" "$escaped"
}

# 以目标用户身份执行命令（与 git-github 的 run_as_target 同模式）
site_run_as() {
    local user="$1" home="$2"
    shift 2
    if [ "$user" = "$(id -un)" ]; then
        env HOME="$home" "$@"
    else
        runuser -u "$user" -- env HOME="$home" "$@"
    fi
}

# 已存在的证书是否为真实的 Let's Encrypt 证书（自签名证书会在重跑时重试申请）
site_cert_is_letsencrypt() {
    local pem="$1"
    local issuer
    issuer="$(openssl x509 -in "$pem" -noout -issuer 2>/dev/null || true)"
    [[ "$issuer" == *"Let's Encrypt"* ]]
}

# ==================== 配置解析与校验（先于 check_root，可非 root 测试） ====================
SITE_IDS=()
declare -A CFG_REPO=() CFG_TYPE=() CFG_DOMAIN=() CFG_BRANCH=() CFG_BUILD=()
declare -A CFG_OUTPUT=() CFG_START=() CFG_PORT=() CFG_USER=() CFG_GROUP=()
declare -A CFG_HOME=() CFG_CERT=() CFG_REDIRECT=() CFG_ENV=()
declare -A SUMMARY_URL=() SUMMARY_REDIRECT=()
SERVER_IP_CACHE=""
NGINX_SUPPORTS_HTTP3=false

read_site_var() {
    local var="HAO_SITE_${1}_${2}"
    printf '%s' "${!var:-$3}"
}

trim_spaces() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

resolve_all_sites() {
    local raw_sites="${HAO_SITES:-}"
    if [ -z "$raw_sites" ]; then
        die "HAO_SITES 未设置或为空。请用逗号分隔的站点 ID 声明要部署的站点，例如: HAO_SITES=\"blog,tools\""
    fi

    local -a raw_ids
    IFS=',' read -ra raw_ids <<< "$raw_sites"
    local -A seen_ids=()
    local raw id prefix
    for raw in "${raw_ids[@]}"; do
        id="$(trim_spaces "$raw")"
        [ -n "$id" ] || die "HAO_SITES 包含空条目: $raw_sites"
        [[ "$id" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] \
            || die "无效的站点 ID: $id（仅允许小写字母、数字和连字符，例如 blog-v2）"
        [ -z "${seen_ids[$id]:-}" ] || die "站点 ID 重复: $id"
        seen_ids[$id]=1
        SITE_IDS+=("$id")
    done

    local -A PORT_OWNER=() DOMAIN_OWNER=()
    local empty_domain_site=""

    for id in "${SITE_IDS[@]}"; do
        prefix="$(site_prefix "$id")"

        # ---- 必填项 ----
        local repo type
        repo="$(read_site_var "$prefix" REPO "")"
        [ -n "$repo" ] \
            || die "站点 '$id' 缺少必需变量 HAO_SITE_${prefix}_REPO（Git 仓库地址或本地路径）"
        type="$(read_site_var "$prefix" TYPE "")"
        [ -n "$type" ] \
            || die "站点 '$id' 缺少必需变量 HAO_SITE_${prefix}_TYPE（可选: static | node）"
        case "$type" in
            static|node) ;;
            *) die "站点 '$id' 的 HAO_SITE_${prefix}_TYPE 无效: $type（可选: static | node）" ;;
        esac

        # ---- 域名 ----
        local domain
        domain="$(read_site_var "$prefix" DOMAIN "")"
        if [ -n "$domain" ]; then
            validate_domain "$domain" || exit 1
        fi

        # ---- 分支 ----
        local branch
        branch="$(read_site_var "$prefix" BRANCH "main")"
        [[ "$branch" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] \
            || die "站点 '$id' 的 HAO_SITE_${prefix}_BRANCH 非法: $branch"

        # ---- 证书 / 跳转开关 ----
        local cert redirect
        cert="$(read_site_var "$prefix" CERT "yes")"
        case "$cert" in
            yes|no) ;;
            *) die "站点 '$id' 的 HAO_SITE_${prefix}_CERT 只能是 yes 或 no，当前: $cert" ;;
        esac
        redirect="$(read_site_var "$prefix" REDIRECT "yes")"
        case "$redirect" in
            yes|no) ;;
            *) die "站点 '$id' 的 HAO_SITE_${prefix}_REDIRECT 只能是 yes 或 no，当前: $redirect" ;;
        esac

        # ---- static: BUILD / OUTPUT ----
        local build output_raw output
        build="$(read_site_var "$prefix" BUILD "")"
        output_raw="$(read_site_var "$prefix" OUTPUT "")"
        if [ -n "$output_raw" ]; then
            output="$output_raw"
        elif [ -n "$build" ]; then
            output="build"
        else
            output="."
        fi
        output="${output%/}"
        case "$output" in
            ..|*/../*|../*|*/..|/*)
                die "站点 '$id' 的 HAO_SITE_${prefix}_OUTPUT 非法: $output（必须是克隆目录内的相对路径，不能包含 ..）" ;;
        esac

        # ---- node: START / PORT / ENV ----
        local start_raw start port port_raw env_raw
        start_raw="$(read_site_var "$prefix" START "")"
        start="${start_raw:-server.js}"
        port_raw="$(read_site_var "$prefix" PORT "")"
        port="$port_raw"
        env_raw="$(read_site_var "$prefix" ENV "")"

        if [ "$type" = "static" ]; then
            if [ -n "$port_raw" ]; then
                log_warning "站点 '$id' 是 static 类型，HAO_SITE_${prefix}_PORT 将被忽略"
                port=""
            fi
            if [ -n "$start_raw" ]; then
                log_warning "站点 '$id' 是 static 类型，HAO_SITE_${prefix}_START 将被忽略"
                start=""
            fi
            if [ -n "$env_raw" ]; then
                log_warning "站点 '$id' 是 static 类型，HAO_SITE_${prefix}_ENV 将被忽略"
                env_raw=""
            fi
        else
            if [ -n "$build" ]; then
                log_warning "站点 '$id' 是 node 类型，HAO_SITE_${prefix}_BUILD 将被忽略（仅 static 类型使用）"
                build=""
            fi
            if [ -n "$output_raw" ]; then
                log_warning "站点 '$id' 是 node 类型，HAO_SITE_${prefix}_OUTPUT 将被忽略"
            fi
            if [ -n "$port" ]; then
                validate_port "$port" || exit 1
            else
                # 幂等重跑：复用既有 systemd 单元中的端口，避免每次重跑都换端口
                local existing_unit="/etc/systemd/system/hao-site-${id}.service"
                if [ -f "$existing_unit" ]; then
                    port="$(sed -n 's|^ExecStart=.*[[:space:]]\([0-9]\{1,5\}\)[[:space:]]*$|\1|p' "$existing_unit" | head -1)"
                fi
                if [ -z "$port" ]; then
                    local candidate="$NODE_PORT_SCAN_START"
                    while [ "$candidate" -le "$NODE_PORT_SCAN_END" ]; do
                        if [ -z "${PORT_OWNER[$candidate]:-}" ] && check_port_available "$candidate"; then
                            port="$candidate"
                            break
                        fi
                        candidate=$((candidate + 1))
                    done
                    [ -n "$port" ] \
                        || die "无法为站点 '$id' 自动分配端口（${NODE_PORT_SCAN_START}-${NODE_PORT_SCAN_END} 均被占用）"
                    log_info "站点 '$id' 自动分配端口: $port"
                fi
            fi
            if [ -n "${PORT_OWNER[$port]:-}" ]; then
                die "端口冲突: 站点 '${PORT_OWNER[$port]}' 与 '$id' 使用相同端口 $port"
            fi
            PORT_OWNER[$port]="$id"
        fi

        # ---- ENV 规范化（仅 node）----
        local env_normalized=""
        if [ "$type" = "node" ] && [ -n "$env_raw" ]; then
            local -a env_pairs
            IFS=',' read -ra env_pairs <<< "$env_raw"
            local pair key
            for pair in "${env_pairs[@]}"; do
                pair="$(trim_spaces "$pair")"
                [ -z "$pair" ] && continue
                case "$pair" in
                    *=*) ;;
                    *) die "站点 '$id' 的 HAO_SITE_${prefix}_ENV 条目无效: $pair（格式 KEY=VALUE，逗号分隔）" ;;
                esac
                key="${pair%%=*}"
                [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
                    || die "站点 '$id' 的 HAO_SITE_${prefix}_ENV 变量名非法: $key"
                [ "$key" != "PORT" ] \
                    || die "站点 '$id': 端口由 HAO_SITE_${prefix}_PORT 控制，请勿在 ENV 中设置 PORT"
                if [ -n "$env_normalized" ]; then
                    env_normalized+=",$pair"
                else
                    env_normalized="$pair"
                fi
            done
        fi

        # ---- 域名冲突 / 默认站点唯一性 ----
        if [ -n "$domain" ]; then
            if [ -n "${DOMAIN_OWNER[$domain]:-}" ]; then
                die "域名冲突: 站点 '${DOMAIN_OWNER[$domain]}' 与 '$id' 使用相同域名 $domain"
            fi
            DOMAIN_OWNER[$domain]="$id"
        else
            if [ -n "$empty_domain_site" ]; then
                die "站点 '$empty_domain_site' 与 '$id' 均未设置 DOMAIN（80 端口默认站点只能有一个，请为其他站点设置域名）"
            fi
            empty_domain_site="$id"
            if [ "$cert" = "yes" ]; then
                log_info "站点 '$id' 未设置 DOMAIN，将以 HTTP（80 端口默认站点）发布，跳过证书申请"
            fi
        fi

        # ---- 目标用户 ----
        local user home group
        user="$(read_site_var "$prefix" TARGET_USER "${SUDO_USER:-root}")"
        id "$user" >/dev/null 2>&1 \
            || die "站点 '$id' 的目标用户不存在: $user（HAO_SITE_${prefix}_TARGET_USER）"
        home="$(getent passwd "$user" | awk -F: '{print $6}')"
        { [ -n "$home" ] && [ -d "$home" ]; } \
            || die "站点 '$id' 的目标用户 $user 没有可用的 home 目录"
        group="$(id -gn "$user")"

        # ---- 写入解析结果 ----
        CFG_REPO[$id]="$repo"
        CFG_TYPE[$id]="$type"
        CFG_DOMAIN[$id]="$domain"
        CFG_BRANCH[$id]="$branch"
        CFG_BUILD[$id]="$build"
        CFG_OUTPUT[$id]="$output"
        CFG_START[$id]="$start"
        CFG_PORT[$id]="$port"
        CFG_USER[$id]="$user"
        CFG_GROUP[$id]="$group"
        CFG_HOME[$id]="$home"
        CFG_CERT[$id]="$cert"
        CFG_REDIRECT[$id]="$redirect"
        CFG_ENV[$id]="$env_normalized"
    done
}

# ==================== 部署步骤 ====================

# 克隆或更新仓库到 /opt/hao-sites/<id>
site_git_sync() {
    local id="$1"
    local user="${CFG_USER[$id]}" home="${CFG_HOME[$id]}" group="${CFG_GROUP[$id]}"
    local repo="${CFG_REPO[$id]}" branch="${CFG_BRANCH[$id]}"
    local clone_dir="$CLONE_BASE/$id"
    local safe_repo
    safe_repo="$(sanitize_repo_url "$repo")"

    install -d -m 0755 "$CLONE_BASE"

    if [ ! -e "$clone_dir" ]; then
        log_step "[站点 $id] 克隆仓库 ($safe_repo, 分支 $branch) 到 $clone_dir ..."
        install -d -m 0755 -o "$user" -g "$group" "$clone_dir"
        if ! site_run_as "$user" "$home" git clone --branch "$branch" "$repo" "$clone_dir"; then
            rm -rf "$clone_dir"
            die "站点 '$id' 克隆失败，请检查仓库地址与分支名: $branch"
        fi
        log_success "[站点 $id] 克隆完成"
        return 0
    fi

    if [ ! -d "$clone_dir/.git" ]; then
        die "站点 '$id' 的目录已存在且不是 Git 检出，拒绝覆盖: $clone_dir（请手动处理后重试）"
    fi

    local current_remote
    current_remote="$(site_run_as "$user" "$home" git -C "$clone_dir" remote get-url origin 2>/dev/null || true)"
    if [ "$current_remote" != "$repo" ]; then
        die "站点 '$id' 目录中的仓库 ($(sanitize_repo_url "$current_remote")) 与配置的仓库 ($safe_repo) 不一致，拒绝操作。如需更换仓库，请手动移除 $clone_dir 后重试。"
    fi

    log_step "[站点 $id] 更新代码到 origin/$branch ..."
    site_run_as "$user" "$home" git -C "$clone_dir" fetch --prune origin \
        || die "站点 '$id' git fetch 失败"
    site_run_as "$user" "$home" git -C "$clone_dir" checkout -f -B "$branch" "origin/$branch" \
        || die "站点 '$id' git checkout 失败"
    site_run_as "$user" "$home" git -C "$clone_dir" reset --hard "origin/$branch" \
        || die "站点 '$id' git reset 失败"
    log_success "[站点 $id] 代码已更新"
}

site_static_build() {
    local id="$1"
    local build="${CFG_BUILD[$id]}"
    [ -n "$build" ] || return 0
    local user="${CFG_USER[$id]}" home="${CFG_HOME[$id]}"
    log_step "[站点 $id] 执行构建: $build"
    site_run_as "$user" "$home" env CI=true bash -c "cd $CLONE_BASE/$id && $build" \
        || die "站点 '$id' 构建失败"
    log_success "[站点 $id] 构建完成"
}

site_static_publish() {
    local id="$1"
    local prefix
    prefix="$(site_prefix "$id")"
    local output="${CFG_OUTPUT[$id]}" user="${CFG_USER[$id]}" group="${CFG_GROUP[$id]}"
    local src="$CLONE_BASE/$id/$output"
    local dest="$WEB_BASE/$id"
    [ -d "$src" ] \
        || die "站点 '$id' 的产物目录不存在: $src（请检查 HAO_SITE_${prefix}_BUILD / HAO_SITE_${prefix}_OUTPUT）"

    log_step "[站点 $id] 发布静态文件到 $dest ..."
    install -d -m 0755 "$dest"
    find "$dest" -mindepth 1 -delete
    cp -a "$src/." "$dest/"
    if [ "$output" = "." ]; then
        rm -rf "$dest/.git"
    fi
    chown -R "$user:$group" "$dest"
    chmod 755 "$dest"
    log_success "[站点 $id] 静态文件已发布"
}

site_node_service() {
    local id="$1"
    local prefix
    prefix="$(site_prefix "$id")"
    local user="${CFG_USER[$id]}" home="${CFG_HOME[$id]}"
    local port="${CFG_PORT[$id]}" start="${CFG_START[$id]}"
    local clone_dir="$CLONE_BASE/$id"
    local unit_name="hao-site-${id}.service"
    local unit_file="/etc/systemd/system/$unit_name"

    local node_bin
    node_bin="$(command -v node || true)"
    if [ -z "$node_bin" ]; then
        die "站点 '$id' 需要 Node.js，但未找到 node 命令。请先将 node 加入 HAO_SERVICES（或手动安装 Node.js）后重试。"
    fi

    # Environment 行：NODE_ENV/HOME/PORT 在前，用户 ENV 在后（同名时用户优先；PORT 已在校验阶段禁止）
    local env_lines env_escaped
    env_lines="Environment=\"NODE_ENV=production\""
    env_lines+=$'\n'"Environment=\"HOME=$(escape_double_quoted "$home")\""
    env_lines+=$'\n'"Environment=\"PORT=$port\""
    if [ -n "${CFG_ENV[$id]}" ]; then
        local -a pairs
        IFS=',' read -ra pairs <<< "${CFG_ENV[$id]}"
        local pair
        for pair in "${pairs[@]}"; do
            env_escaped="$(escape_double_quoted "$pair")"
            env_lines+=$'\n'"Environment=\"$env_escaped\""
        done
    fi

    log_step "[站点 $id] 生成 systemd 单元 $unit_name ..."
    cat > "$unit_file" <<UNIT_EOF
# Managed by HAO
# Service: site
# HAO-SITE: $id
# Release: ${COMMON_VERSION}
[Unit]
Description=HAO Site: $id (node)
After=network.target

[Service]
Type=simple
User=$user
WorkingDirectory=$clone_dir
ExecStart=$node_bin $start $port
Restart=always
RestartSec=10s

$env_lines

NoNewPrivileges=true
PrivateTmp=true

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT_EOF
    # ENV 可能包含敏感值，单元文件不对外可读（systemd 以 root 运行，不受影响）
    chmod 0640 "$unit_file"

    systemctl daemon-reload
    systemctl enable "$unit_name" >/dev/null 2>&1
    systemctl restart "$unit_name" \
        || die "站点 '$id' 服务启动失败，请检查: journalctl -u $unit_name -n 50"

    log_step "[站点 $id] 等待服务端口 $port 就绪 ..."
    if wait_for_local_port "$port" 30 2; then
        log_success "[站点 $id] 服务已就绪 (127.0.0.1:$port)"
    else
        log_error "站点 '$id' 服务未能在 30 秒内监听端口 $port"
        log_error "排查: journalctl -u $unit_name -n 50"
        exit 1
    fi
}

# 生成 Nginx 虚拟主机（含占用检查、证书、可控的 80->443 跳转）
site_write_vhost() {
    local id="$1"
    local prefix
    prefix="$(site_prefix "$id")"
    local domain="${CFG_DOMAIN[$id]}" type="${CFG_TYPE[$id]}"
    local cert="${CFG_CERT[$id]}" redirect="${CFG_REDIRECT[$id]}"
    local port="${CFG_PORT[$id]}"
    local server_name_value="$domain"
    [ -n "$server_name_value" ] || server_name_value="_"
    local conf_file="$CONF_D/hao-site-${id}.conf"

    # ---- 占用检查：server_name 不得被非本站点配置占用 ----
    local existing
    existing="$(find_nginx_conf_by_server_name "$server_name_value" "$CONF_D" || true)"
    if [ -n "$existing" ]; then
        if ! grep -q 'HAO-SITE' "$existing"; then
            die "Nginx 配置 $existing 已占用 server_name '$server_name_value'（非 HAO site 模块管理），拒绝覆盖。请为站点 '$id' 更换域名，或手动处理该配置。"
        fi
        if ! grep -qE "^# HAO-SITE: ${id}\$" "$existing"; then
            die "server_name '$server_name_value' 已被另一个 HAO 站点占用: $existing"
        fi
        conf_file="$existing"
    fi

    # ---- 证书（仅 DOMAIN + CERT=yes）----
    local ssl_type="" real_cert=false domain_ssl_dir="$SSL_DIR/$domain"
    if [ -n "$domain" ] && [ "$cert" = "yes" ]; then
        if [ -f "$domain_ssl_dir/fullchain.pem" ] && site_cert_is_letsencrypt "$domain_ssl_dir/fullchain.pem"; then
            ssl_type="Let's Encrypt (ECC-256)"
            log_info "[站点 $id] 已存在 Let's Encrypt 证书，跳过申请"
        else
            ssl_type="$(apply_ssl_certificate "$domain" "$domain_ssl_dir" "domain")"
        fi
        case "$ssl_type" in
            *"Let's Encrypt"*) real_cert=true ;;
        esac
    fi

    # ---- 跳转策略：仅在真实证书签发后允许 80->443 跳转（522 教训）----
    local redirect_active=false
    if [ -n "$domain" ] && [ "$cert" = "yes" ] && [ "$real_cert" = true ] && [ "$redirect" = "yes" ]; then
        redirect_active=true
    elif [ -n "$domain" ] && [ "$cert" = "yes" ] && [ "$redirect" = "yes" ] && [ "$real_cert" != true ]; then
        log_warning "[站点 $id] 证书为自签名，HTTP->HTTPS 跳转未启用，80 端口直接提供服务"
    fi

    # ---- 站点内容块 ----
    local body
    if [ "$type" = "static" ]; then
        IFS= read -r -d '' body <<EOF || true
    root $WEB_BASE/$id;
    index index.html;

    access_log /var/log/nginx/hao-site-${id}_access.log;
    error_log /var/log/nginx/hao-site-${id}_error.log warn;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~* \.(?:css|js|map|json|jpg|jpeg|gif|png|svg|ico|webp|avif|woff|woff2|ttf|eot)\$ {
        expires 7d;
        add_header Cache-Control "public";
        try_files \$uri =404;
    }
EOF
    else
        IFS= read -r -d '' body <<EOF || true
    client_max_body_size 50m;

    access_log /var/log/nginx/hao-site-${id}_access.log;
    error_log /var/log/nginx/hao-site-${id}_error.log warn;

    location / {
        proxy_pass http://127.0.0.1:$port;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # WebSocket 支持
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
    }
EOF
    fi

    # ---- ACME webroot 块（仅设置域名时）----
    local acme_block=""
    if [ -n "$domain" ]; then
        mkdir -p /var/www/acme
        chmod 755 /var/www/acme
        IFS= read -r -d '' acme_block <<'EOF' || true
    location /.well-known/acme-challenge/ {
        root /var/www/acme;
    }
EOF
    fi

    # ---- 组装 server 块 ----
    local blocks=""
    if [ -z "$domain" ]; then
        blocks="server {
    listen 80;
    server_name _;

$body
}"
    elif [ "$cert" != "yes" ]; then
        blocks="server {
    listen 80;
    server_name $domain;

$acme_block

$body
}"
    else
        local listen_443 quic_header=""
        if [ "$NGINX_SUPPORTS_HTTP3" = true ]; then
            listen_443="    listen 443 ssl;
    listen 443 quic;
    http2 on;"
            quic_header="    add_header Alt-Svc 'h3=\":443\"; ma=86400';"
        else
            listen_443="    listen 443 ssl;
    http2 on;"
        fi

        local port80_inner
        if [ "$redirect_active" = true ]; then
            # 与 NGINX_REDIRECT_LOGIC 同语义：ACME 路径保留在 80，其余 301 到 https
            port80_inner="    location / {
        return 301 https://\$host\$request_uri;
    }"
        else
            port80_inner="$body"
        fi

        blocks="server {
    listen 80;
    server_name $domain;

$acme_block

$port80_inner
}

server {
$listen_443
    server_name $domain;

    ssl_certificate $domain_ssl_dir/fullchain.pem;
    ssl_certificate_key $domain_ssl_dir/key.pem;
$NGINX_SSL_CONFIG
$quic_header
$body
}"
    fi

    # ---- 写入 + 测试 + 重载（失败自动恢复备份）----
    mkdir -p "$CONF_D"
    local conf_backup
    conf_backup="$(backup_file_for_write "$conf_file")"
    cat > "$conf_file" <<NGX_EOF
# Managed by HAO
# Service: site
# HAO-SITE: $id
# Release: ${COMMON_VERSION}
$blocks
NGX_EOF
    log_success "[站点 $id] Nginx 配置已生成: $conf_file"

    if nginx -t >/dev/null 2>&1; then
        if systemctl reload nginx 2>/dev/null; then
            log_success "Nginx 已重载"
        else
            systemctl start nginx 2>/dev/null || log_warning "Nginx 重载失败且无法启动，请手动检查"
        fi
    else
        log_error "Nginx 配置测试失败"
        nginx -t 2>&1 || true
        restore_file_after_failed_write "$conf_file" "$conf_backup"
        nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
        exit 1
    fi

    if [ "$redirect_active" = true ]; then
        log_warning "[站点 $id] 已为 $domain 启用 HTTP->HTTPS 跳转"
        log_warning "⚠️ 请确认云服务器安全组/防火墙已放行 443/TCP，否则跳转后站点将完全不可访问（典型现象: 522 超时）"
        log_warning "如 443 端口未放行，请设置 HAO_SITE_${prefix}_REDIRECT=no 后重新部署"
    fi

    # ---- 汇总信息 ----
    if [ -z "$domain" ]; then
        if [ -z "$SERVER_IP_CACHE" ]; then
            SERVER_IP_CACHE="$(detect_server_ip)"
        fi
        SUMMARY_URL[$id]="http://$SERVER_IP_CACHE/"
    elif [ "$real_cert" = true ]; then
        SUMMARY_URL[$id]="https://$domain"
    elif [ "$cert" = "yes" ]; then
        SUMMARY_URL[$id]="http://$domain（https 为自签名证书，浏览器会提示不安全）"
    else
        SUMMARY_URL[$id]="http://$domain"
    fi
    SUMMARY_REDIRECT[$id]="$redirect_active"
}

# 生成独立更新脚本 /usr/local/bin/hao-site-update-<id>（嵌入解析后的字面量，不依赖本仓库）
site_write_update_script() {
    local id="$1"
    local type="${CFG_TYPE[$id]}"
    local script="$UPDATE_BIN_DIR/hao-site-update-$id"

    {
        cat <<EOF
#!/usr/bin/env bash
# shellcheck disable=SC2034
# Managed by HAO
# Service: site
# HAO-SITE: $id
# Release: ${COMMON_VERSION}
# 站点 '$id' 更新脚本：拉取最新代码 -> 重新构建/发布（static）或重启服务（node）-> 重载 Nginx
set -euo pipefail

SITE_ID=$(shell_quote "$id")
SITE_TYPE=$(shell_quote "$type")
CLONE_DIR=$(shell_quote "$CLONE_BASE/$id")
BRANCH=$(shell_quote "${CFG_BRANCH[$id]}")
TARGET_USER=$(shell_quote "${CFG_USER[$id]}")
TARGET_GROUP=$(shell_quote "${CFG_GROUP[$id]}")
TARGET_HOME=$(shell_quote "${CFG_HOME[$id]}")
BUILD_CMD=$(shell_quote "${CFG_BUILD[$id]}")
OUTPUT_DIR=$(shell_quote "${CFG_OUTPUT[$id]}")
WEB_DIR=$(shell_quote "$WEB_BASE/$id")
UNIT_NAME=$(shell_quote "hao-site-${id}.service")
PORT=$(shell_quote "${CFG_PORT[$id]}")
EOF
        cat <<'EOF'

log() { printf '[hao-site-update-%s] %s\n' "$SITE_ID" "$*"; }

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "[ERROR] 请使用 root 权限运行: sudo hao-site-update-$SITE_ID" >&2
    exit 1
fi

command -v git >/dev/null 2>&1 || { echo "[ERROR] 未找到 git 命令。" >&2; exit 1; }

run_as_target() {
    if [ "$TARGET_USER" = "$(id -un)" ]; then
        env HOME="$TARGET_HOME" "$@"
    else
        runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" "$@"
    fi
}

log "拉取最新代码（分支 $BRANCH）..."
run_as_target git -C "$CLONE_DIR" fetch --prune origin
run_as_target git -C "$CLONE_DIR" checkout -f -B "$BRANCH" "origin/$BRANCH"
run_as_target git -C "$CLONE_DIR" reset --hard "origin/$BRANCH"
EOF
        if [ "$type" = "static" ]; then
            cat <<'EOF'

if [ -n "$BUILD_CMD" ]; then
    log "执行构建: $BUILD_CMD"
    run_as_target env CI=true bash -c "cd $CLONE_DIR && $BUILD_CMD"
fi
log "发布静态文件到 $WEB_DIR ..."
install -d -m 0755 "$WEB_DIR"
find "$WEB_DIR" -mindepth 1 -delete
cp -a "$CLONE_DIR/$OUTPUT_DIR/." "$WEB_DIR/"
if [ "$OUTPUT_DIR" = "." ]; then
    rm -rf "$WEB_DIR/.git"
fi
chown -R "$TARGET_USER:$TARGET_GROUP" "$WEB_DIR"
chmod 755 "$WEB_DIR"
EOF
        else
            cat <<'EOF'

log "重启服务 $UNIT_NAME ..."
systemctl restart "$UNIT_NAME"
log "等待端口 $PORT 就绪..."
ready=0
for _ in $(seq 1 15); do
    if timeout 2 bash -c ">/dev/tcp/127.0.0.1/$PORT" 2>/dev/null; then
        ready=1
        break
    fi
    sleep 2
done
if [ "$ready" != "1" ]; then
    echo "[ERROR] 服务未监听端口 $PORT，请检查: journalctl -u $UNIT_NAME -n 50" >&2
    exit 1
fi
EOF
        fi
        cat <<'EOF'

log "重载 Nginx ..."
if ! systemctl reload nginx 2>/dev/null; then
    log "Nginx 未在运行或重载失败，已跳过（配置将在 Nginx 下次启动时生效）"
fi
log "完成。"
EOF
    } > "$script"
    chmod 0755 "$script"
    log_success "[站点 $id] 更新脚本已生成: $script"
}

site_print_summary() {
    local id="$1"
    local type="${CFG_TYPE[$id]}"
    echo ""
    echo "============================================"
    echo "  站点 '$id' 部署完成 (${COMMON_VERSION})"
    echo "============================================"
    echo "类型:      $type"
    echo "访问地址:  ${SUMMARY_URL[$id]}"
    if [ "${SUMMARY_REDIRECT[$id]}" = "true" ]; then
        echo "跳转:      80 -> 443 已启用（请确认安全组已放行 443/TCP）"
    fi
    echo "代码目录:  $CLONE_BASE/$id"
    if [ "$type" = "static" ]; then
        echo "发布目录:  $WEB_BASE/$id"
    else
        echo "服务单元:  hao-site-${id}.service"
        echo "监听端口:  127.0.0.1:${CFG_PORT[$id]}"
    fi
    echo "更新命令:  sudo hao-site-update-$id"
}

apply_site() {
    local id="$1"
    echo ""
    log_step "================ 站点: $id (${CFG_TYPE[$id]}) ================"
    site_git_sync "$id"
    if [ "${CFG_TYPE[$id]}" = "static" ]; then
        site_static_build "$id"
        site_static_publish "$id"
    else
        site_node_service "$id"
    fi
    site_write_vhost "$id"
    site_write_update_script "$id"
    site_print_summary "$id"
}

# ==================== 主流程 ====================
resolve_all_sites

check_root
setup_logging "site-install"

echo "============================================"
echo "   site 站点部署脚本 ${COMMON_VERSION}"
echo "============================================"
echo ""

# 依赖检查（模块依赖由根 CLI 编排保证；独立运行时给出明确指引）
command -v git >/dev/null 2>&1 \
    || die "未检测到 Git。请先将 git-github 加入 HAO_SERVICES，或运行: apt-get install -y git"
command -v nginx >/dev/null 2>&1 \
    || die "未检测到 Nginx。请先将 nginx 加入 HAO_SERVICES，或运行: apt-get install -y nginx"

NEED_SSL_TOOLS=false
for site_id in "${SITE_IDS[@]}"; do
    if [ -n "${CFG_DOMAIN[$site_id]}" ] && [ "${CFG_CERT[$site_id]}" = "yes" ]; then
        NEED_SSL_TOOLS=true
    fi
    log_info "站点 $site_id: 类型=${CFG_TYPE[$site_id]} 域名=${CFG_DOMAIN[$site_id]:-（未设置）} 分支=${CFG_BRANCH[$site_id]} 用户=${CFG_USER[$site_id]}${CFG_PORT[$site_id]:+ 端口=${CFG_PORT[$site_id]}}"
done
if [ "$NEED_SSL_TOOLS" = true ]; then
    ensure_commands openssl curl
fi

if detect_nginx_http3; then
    NGINX_SUPPORTS_HTTP3=true
    log_info "检测到 Nginx HTTP/3 支持"
fi

for site_id in "${SITE_IDS[@]}"; do
    apply_site "$site_id"
done

echo ""
log_success "全部站点部署完成: ${SITE_IDS[*]}"
if [ -n "${DEPLOY_LOG_FILE:-}" ]; then
    log_success "日志已保存: $DEPLOY_LOG_FILE"
fi
