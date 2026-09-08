#!/usr/bin/env bash
# shellcheck shell=bash

# hao-secret.sh —— HAO 凭据生成、复用与落盘
#
# 这个脚本存在的唯一理由：让 agent 能创建含密钥的凭据文件，而密钥值
# 永远不经过对话、不经过 stdout、也不经过命令行参数（argv 对同机任意
# 用户可见，见 /proc/<pid>/cmdline）。agent 只会看到文件路径与 key 名称。
#
# 幂等性：默认复用目标文件中已存在的 key，只生成缺失的 key。
# 这是「重跑一次不会换掉线上密码」的保证，不要绕过它。
# 需要轮换时用 --rotate KEY[,KEY...] 显式指定。
#
# 合并语义：目标文件里未在本次 SPEC 中提及的 key 会被原样保留。
# 少列一个 key 不会把它抹掉 —— 静默弄丢线上凭据是不可接受的失败。
# 要删 key 就自己改文件，那必须是明确的动作。
#
# 用法:
#   hao-secret.sh write <target> SPEC [SPEC...] [--rotate KEY[,KEY]]
#   hao-secret.sh keys <target>
#   hao-secret.sh has <target> <KEY>
#   hao-secret.sh render <template> <output> --from <credfile> [--mode MODE]
#
# SPEC 形式（KEY 必须是大写字母、数字、下划线）:
#   KEY=@password[:LEN]     生成 LEN 位字母数字密码（默认 32）
#   KEY=@session[:LEN]      生成 LEN 位会话密钥（默认 48）
#   KEY=@apikey[:PREFIX]    生成 API key（默认前缀 sk-）
#   KEY=@file:PATH          从文件首行读取（用户自带的密钥走这条）
#   KEY=@env:VARNAME        从环境变量读取
#
# 字面量（KEY=hunter2）会被拒绝：命令行参数对同机其他用户可见。
#
# render 用于把凭据注入配置文件：模板里的 @@KEY@@ 会被凭据文件中
# 同名 key 的值替换，替换过程不打印任何值。

set -euo pipefail

die() {
    echo "hao-secret: $*" >&2
    exit 1
}

# ==================== 随机数生成 ====================
# 失败必须报错退出，绝不能静默返回空字符串或短密钥。
hao_random_alnum() {
    local length="$1" value="" chunk
    while [ "${#value}" -lt "$length" ]; do
        chunk="$(openssl rand -base64 64 2>/dev/null | tr -dc 'a-zA-Z0-9')" || chunk=""
        [ -n "$chunk" ] || die "安全随机数生成失败（openssl 是否已安装？）"
        value="${value}${chunk}"
    done
    printf '%s' "${value:0:length}"
}

# ==================== 字面替换 ====================
# 把 haystack 里所有 needle 换成 value，结果放在 HAO_SUBST_OUT。
#
# 为什么不用 ${haystack//$needle/$value}：bash 的 pattern substitution 对**替换串**
# 里的 `&` 有特殊语义（代表刚匹配到的文本），而这个语义是后来才加进 bash 的 ——
# 也就是说同一份脚本在不同 bash 版本上结果不一样。于是一个含 & 的凭据值会被静默
# 写成 `value=...@@KEY@@...`，而脚本照样报告"已渲染"。
# 用 %% / # 切分只做纯字面替换，任何版本上结果都一致。
#
# 结果走全局变量而不是 stdout：命令替换会吞掉末尾换行，而且密钥值没必要多经过
# 一次管道。
HAO_SUBST_OUT=""
hao_subst_literal() {
    local haystack="$1" needle="$2" value="$3" out=""
    while [ -n "$haystack" ]; do
        case "$haystack" in
            *"$needle"*)
                out="${out}${haystack%%"$needle"*}${value}"
                haystack="${haystack#*"$needle"}"
                ;;
            *)
                out="${out}${haystack}"
                haystack=""
                ;;
        esac
    done
    HAO_SUBST_OUT="$out"
}

# ==================== 现有凭据读取 ====================
declare -A EXISTING=()

load_existing() {
    local file="$1" line key
    [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*) continue ;;
            *=*) ;;
            *) continue ;;
        esac
        key="${line%%=*}"
        [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || continue
        EXISTING["$key"]="${line#*=}"
    done < "$file"
}

# ==================== 原子写入（0600） ====================
# 凭据目录按 0700 创建：文件本身是 0600，但目录若可列出，同机任意用户就能
# 枚举「哪些服务有凭据」。泄露的是元信息而不是密钥，但既然这棵树的边界是
# 「什么都不该被看到」，就把它做实。
#
# 已存在的目录**绝不 chmod**：目标可能是 /etc/foo.env 这种直接落在 /etc 下的
# 路径，那样会把 /etc 改成 0700，后果远比元信息泄露严重。存量目录只告警。
write_file_0600() {
    local target="$1" dir tmp mode
    dir="$(dirname "$target")"
    if [ -d "$dir" ]; then
        mode="$(stat -c '%a' "$dir" 2>/dev/null || echo '')"
        case "$mode" in
            700|7[0-7]00) ;;
            '') ;;
            *)
                if [ -n "$mode" ] && [ "$((0${mode} & 077))" -ne 0 ]; then
                    echo "hao-secret: 提示 —— 凭据目录 $dir 权限为 $mode，可被同机其他用户列出（文件内容仍受 0600 保护）。建议: chmod 0700 $dir" >&2
                fi
                ;;
        esac
    else
        # SC2174「-m 只作用于最深一级目录」在这里正是想要的行为：凭据目录
        # (/etc/hao) 要 0700，而它的父目录 (/etc) 绝不能被改。
        # 也不用 mkdir + chmod 两步 —— 那会留下一个短暂的 0755 窗口。
        # shellcheck disable=SC2174
        mkdir -p -m 0700 "$dir"
    fi
    tmp="$(mktemp "${target}.tmp.XXXXXX")"
    if ! cat > "$tmp"; then
        rm -f "$tmp"
        die "写入失败: $target"
    fi
    chmod 600 "$tmp"
    chown root:root "$tmp" 2>/dev/null || true
    mv "$tmp" "$target"
}

# ==================== write ====================
cmd_write() {
    local target="${1:-}"
    [ -n "$target" ] || die "write 需要目标文件路径"
    shift

    local -a specs=() rotate=()
    local arg
    while [ "$#" -gt 0 ]; do
        arg="$1"
        case "$arg" in
            --rotate)
                [ -n "${2:-}" ] || die "--rotate 需要 KEY 列表"
                IFS=',' read -ra rotate <<< "$2"
                shift 2
                ;;
            -*)
                die "未知参数: $arg"
                ;;
            *)
                specs+=("$arg")
                shift
                ;;
        esac
    done
    [ "${#specs[@]}" -gt 0 ] || die "write 至少需要一个 SPEC"

    load_existing "$target"

    local -A rotate_set=()
    local key
    for key in "${rotate[@]}"; do
        [ -n "$key" ] && rotate_set["$key"]=1
    done

    local -a out_keys=() out_values=()
    local spec source_spec kind param value src_file src_var reused=0 created=0

    for spec in "${specs[@]}"; do
        case "$spec" in
            *=*) ;;
            *) die "SPEC 格式错误（应为 KEY=@...）: $spec" ;;
        esac
        key="${spec%%=*}"
        source_spec="${spec#*=}"
        [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] \
            || die "非法 key 名（只允许大写字母、数字、下划线）: $key"
        case "$source_spec" in
            @*) ;;
            *) die "拒绝接受字面量密钥 $key=...：命令行参数对同机其他用户可见（ps / /proc/<pid>/cmdline）。请改用 $key=@file:PATH 或 $key=@env:VARNAME，或让本脚本生成。" ;;
        esac

        # 已存在且未要求轮换 -> 复用，保证幂等
        if [ -n "${EXISTING[$key]:-}" ] && [ -z "${rotate_set[$key]:-}" ]; then
            out_keys+=("$key")
            out_values+=("${EXISTING[$key]}")
            reused=$((reused + 1))
            continue
        fi

        source_spec="${source_spec#@}"
        kind="${source_spec%%:*}"
        if [ "$kind" = "$source_spec" ]; then
            param=""
        else
            param="${source_spec#*:}"
        fi

        case "$kind" in
            password)
                value="$(hao_random_alnum "${param:-32}")"
                ;;
            session)
                value="$(hao_random_alnum "${param:-48}")"
                ;;
            apikey)
                value="${param:-sk-}$(hao_random_alnum 45)"
                ;;
            file)
                src_file="$param"
                [ -n "$src_file" ] || die "$key=@file: 缺少路径"
                [ -r "$src_file" ] || die "$key=@file:$src_file 不可读"
                value="$(head -n 1 "$src_file")"
                [ -n "$value" ] || die "$key=@file:$src_file 首行为空"
                ;;
            env)
                src_var="$param"
                [ -n "$src_var" ] || die "$key=@env: 缺少变量名"
                [ -n "${!src_var:-}" ] || die "$key=@env:$src_var 未设置或为空"
                value="${!src_var}"
                ;;
            *)
                die "未知的密钥来源 @$kind（可用: password session apikey file env）"
                ;;
        esac

        case "$value" in
            *$'\n'*) die "$key 的值包含换行，无法写入 KEY=VALUE 格式凭据文件" ;;
        esac

        out_keys+=("$key")
        out_values+=("$value")
        created=$((created + 1))
    done

    # 保留目标文件里未在本次 SPEC 中提及的 key。
    # 绝不能因为调用方少列了一个 key 就把它从文件里抹掉 —— 那会静默弄丢
    # 线上服务正在用的凭据，而且往往等到服务挂了才发现。
    local existing_key preserved=0 already
    while IFS= read -r existing_key; do
        [ -n "$existing_key" ] || continue
        already=false
        for key in "${out_keys[@]}"; do
            [ "$key" = "$existing_key" ] && { already=true; break; }
        done
        [ "$already" = true ] && continue
        out_keys+=("$existing_key")
        out_values+=("${EXISTING[$existing_key]}")
        preserved=$((preserved + 1))
    done < <(printf '%s\n' "${!EXISTING[@]}" | sort)

    local i
    local payload=""
    for i in "${!out_keys[@]}"; do
        payload+="${out_keys[$i]}=${out_values[$i]}"$'\n'
    done
    # 按 key 排序成规范形式：同一组 key 无论 SPEC 顺序如何，落盘内容都一致，
    # 这样重跑才能是真正的 no-op（key 名唯一，按整行排序等价于按 key 排序）。
    payload="$(printf '%s' "$payload" | sort)"$'\n'

    # 内容没变就完全不动文件：保留原有 mtime 与「生成时间」，
    # 也避免每次重跑都产生一次无谓的写入。
    local current=""
    if [ -f "$target" ]; then
        current="$(grep -v '^#' "$target" | grep -v '^$' || true)"
        current="${current}"$'\n'
    fi
    if [ -f "$target" ] && [ "$current" = "$payload" ] \
        && [ "$(stat -c '%a' "$target" 2>/dev/null)" = "600" ]; then
        echo "凭据文件: $target (0600)"
        echo "key: ${out_keys[*]}"
        echo "内容未变更，文件未改动（幂等）。值未输出，也不要去读取它。"
        return 0
    fi

    {
        echo "# Managed by HAO"
        echo "# 凭据文件，权限 0600。请勿提交到版本库，请勿在对话或日志中回显其内容。"
        echo "# 生成时间: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '%s' "$payload"
    } | write_file_0600 "$target"

    echo "凭据文件: $target (0600)"
    echo "key: ${out_keys[*]}"
    echo "复用 $reused 项，新生成 $created 项，保留未提及的 $preserved 项。值未输出，也不要去读取它。"
}

# ==================== keys ====================
cmd_keys() {
    local target="${1:-}"
    [ -n "$target" ] || die "keys 需要目标文件路径"
    [ -f "$target" ] || die "凭据文件不存在: $target"
    load_existing "$target"
    local key
    for key in "${!EXISTING[@]}"; do
        echo "$key"
    done | sort
}

# ==================== has ====================
cmd_has() {
    local target="${1:-}" key="${2:-}"
    [ -n "$target" ] && [ -n "$key" ] || die "has 需要 <target> <KEY>"
    [ -f "$target" ] || return 1
    load_existing "$target"
    [ -n "${EXISTING[$key]:-}" ]
}

# ==================== render ====================
# 把模板中的 @@KEY@@ 替换为凭据文件里的值。值不打印。
cmd_render() {
    local template="${1:-}" output="${2:-}"
    [ -n "$template" ] && [ -n "$output" ] || die "render 需要 <template> <output>"
    shift 2

    local credfile="" mode="0640"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --from)
                credfile="${2:-}"
                [ -n "$credfile" ] || die "--from 需要凭据文件路径"
                shift 2
                ;;
            --mode)
                mode="${2:-}"
                [[ "$mode" =~ ^[0-7]{3,4}$ ]] || die "--mode 需要八进制权限，如 0600"
                shift 2
                ;;
            *) die "未知参数: $1" ;;
        esac
    done

    [ -r "$template" ] || die "模板不可读: $template"
    [ -n "$credfile" ] || die "render 需要 --from <credfile>"
    [ -r "$credfile" ] || die "凭据文件不可读: $credfile"

    load_existing "$credfile"

    local content key placeholder missing=""
    content="$(cat "$template")"

    # 先检查模板里所有 @@KEY@@ 是否都能满足，避免写出半成品配置
    local -a wanted=()
    while IFS= read -r placeholder; do
        [ -n "$placeholder" ] && wanted+=("$placeholder")
    done < <(printf '%s' "$content" | grep -oE '@@[A-Z][A-Z0-9_]*@@' | sort -u | sed 's/@@//g')

    for key in "${wanted[@]}"; do
        [ -n "${EXISTING[$key]:-}" ] || missing="$missing $key"
    done
    [ -z "$missing" ] || die "凭据文件 $credfile 缺少模板所需的 key:$missing"

    for key in "${wanted[@]}"; do
        hao_subst_literal "$content" "@@${key}@@" "${EXISTING[$key]}"
        content="$HAO_SUBST_OUT"
    done
    HAO_SUBST_OUT=""

    local dir tmp
    dir="$(dirname "$output")"
    mkdir -p "$dir"
    tmp="$(mktemp "${output}.tmp.XXXXXX")"
    printf '%s\n' "$content" > "$tmp"
    chmod "$mode" "$tmp"
    mv "$tmp" "$output"

    echo "已渲染: $output (mode $mode)"
    if [ "${#wanted[@]}" -gt 0 ]; then
        echo "注入的 key: ${wanted[*]}（值未输出）"
    else
        echo "模板不含 @@KEY@@ 占位符，仅做了复制。"
    fi
}

# ==================== 分派 ====================
# 头部注释就是用法说明。不写死行号 —— 那个数字每次加一段注释就会过时，
# 而且过时的方式是静默的（-h 会把脚本正文也打印出来）。
usage() {
    awk 'NR <= 2 { next }
         /^[[:space:]]*$/ { print ""; next }
         /^#/ { sub(/^# ?/, ""); print; next }
         { exit }' "${BASH_SOURCE[0]}"
}

case "${1:-}" in
    write)  shift; cmd_write "$@" ;;
    keys)   shift; cmd_keys "$@" ;;
    has)    shift; cmd_has "$@" ;;
    render) shift; cmd_render "$@" ;;
    -h|--help|"") usage ;;
    *) die "未知子命令: $1（可用: write keys has render）" ;;
esac
