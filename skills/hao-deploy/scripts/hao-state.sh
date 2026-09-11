#!/usr/bin/env bash
# shellcheck shell=bash

# hao-state.sh —— HAO 主机状态与交接契约
#
# 这个脚本存在的唯一理由：让「下一个接手的 agent」能信任主机上的状态记录。
# 如果每个 agent 都即兴写自己的状态文件，格式就会漂移，交接契约随之失效。
# 所有状态写入都必须经过本脚本，不要手写 /var/lib/hao 下的任何文件。
#
# 状态目录（默认 /var/lib/hao，可用 HAO_STATE_DIR 覆盖）:
#   NOTICE                     给人看的说明
#   HANDOFF.md                 给下一个 agent 看的交接文档（handoff 子命令生成）
#   DEPLOY-INTENT.md           给用户带走的部署意图（intent 子命令生成）
#   manifest.json              汇总清单（schema_version 1）
#   services/<svc>.json        单服务记录
#   services/<svc>.resources   资源清单（TSV: ownership hash path）
#   services/<svc>.intent      部署意图（TSV: key value，不含密钥）
#
# 记录中只有资源路径、归属类别与哈希，永远不含配置值或密钥内容。
#
# 用法:
#   hao-state.sh record <service> <result> OWNERSHIP:PATH [...]
#   hao-state.sh amend <service> --result <result>
#   hao-state.sh remove <service> [--force]
#   hao-state.sh intent <service> key=value [...]
#   hao-state.sh drift
#   hao-state.sh orphans [DIR...]
#   hao-state.sh ownership <service>
#   hao-state.sh services
#   hao-state.sh credentials
#   hao-state.sh handoff [--user USER] [--agent-file PATH]... [--skip-agent-files]
#   hao-state.sh convention <MARKER-ID> [--user USER] [--agent-file PATH]...  # 正文从 stdin
#
# orphans 的默认扫描清单可用 HAO_ORPHAN_DIRS_DEFAULT 覆盖（空格分隔）。每一项写成
# <目录> 或 <目录>:<深度> —— 带深度的是限深扫描，用于控制大目录树的扫描开销。
# 扫描耗时取决于目录规模、存储性能和缓存状态；限深扫描不会覆盖更深的文件。
# 需要完整排查时显式传目录，例如 orphans /opt。
#
# RESULT 取值（只有这五个，amend 用来修正存量记录里的非法值）:
#   installed 第一次装好
#   updated   已经装过，这次重新部署或改了配置
#   verified  只做了检查，没改任何东西
#   failed    中途失败，机器处于半成品状态
#   skipped   归属检查拦住了，或用户拒绝了
#
# OWNERSHIP 取值:
#   managed   HAO 创建并负责的资源，漂移需要人工复核
#   shared    HAO 修改过但属于系统的资源，不可整体覆盖
#   observed  仅观察记录，不属于 HAO
#   secret    凭据文件，只记录路径，哈希恒为 redacted

set -euo pipefail

HAO_RESULTS="installed updated verified failed skipped"

HAO_STATE_DIR="${HAO_STATE_DIR:-/var/lib/hao}"
HAO_RELEASE="${HAO_RELEASE:-skill}"

die() {
    echo "hao-state: $*" >&2
    exit 1
}

# ==================== 基础工具 ====================
hao_json_escape() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    printf '%s' "$value"
}

hao_resource_hash() {
    local path="$1" ownership="$2"
    if [ "$ownership" = "secret" ]; then
        printf 'redacted'
    elif [ -f "$path" ]; then
        sha256sum "$path" | awk '{print $1}'
    elif [ -d "$path" ]; then
        printf 'directory'
    else
        printf 'missing'
    fi
}

init_state() {
    mkdir -p "$HAO_STATE_DIR/services"
    chmod 755 "$HAO_STATE_DIR" "$HAO_STATE_DIR/services"
    cat > "$HAO_STATE_DIR/NOTICE" <<'EOF'
This directory records resources installed or observed by HAO (HongAgentOps).

Read HANDOFF.md first: it tells an AI agent what this host runs and what the
rules are. Files marked `managed` should only be changed through the HAO skill
procedure. Files marked `shared` or `observed` belong to the surrounding system
and must not be overwritten merely because they appear here. Secret values are
never stored in this directory.
EOF
    chmod 644 "$HAO_STATE_DIR/NOTICE"
}

rebuild_manifest() {
    local target="$HAO_STATE_DIR/manifest.json" tmp first=true state_file
    tmp="$(mktemp "$HAO_STATE_DIR/.manifest.json.XXXXXX")"
    {
        printf '{\n'
        printf '  "schema_version": 1,\n'
        printf '  "managed_by": "HAO",\n'
        printf '  "generated_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '  "services": [\n'
        for state_file in "$HAO_STATE_DIR"/services/*.json; do
            [ -f "$state_file" ] || continue
            if [ "$first" = true ]; then
                first=false
            else
                printf ',\n'
            fi
            sed 's/^/    /' "$state_file"
        done
        printf '\n  ]\n}\n'
    } > "$tmp"
    chmod 644 "$tmp"
    mv "$tmp" "$target"
}

# ==================== 部署意图 ====================
# 意图 = 用户当初给的那些回答（仓库、域名、类型、分支、构建命令…）。
#
# 为什么单独存一份：/var/lib/hao 的其余内容描述「这台机器现在是什么样」，
# 机器销毁就一起消失。意图描述「怎么在新机器上再造一台一样的」，是这台主机上
# 唯一值得带走的东西 —— 所以收尾时必须让用户存到他自己的笔记或仓库里。
#
# 这份文件按设计**不含密钥**：明显是凭据的 key 名直接拒绝，值里内嵌的 URL
# 凭据一律脱敏。凭据本来就不可重放（新机器上重新生成），要留旧密码得在销毁前
# 自己从凭据文件导出。
HAO_INTENT_SECRETISH='(password|passwd|token|secret|apikey|api_key|credential|private_key)'

hao_redact_url_creds() {
    printf '%s' "$1" | sed -E 's#(://)[^/@[:space:]]+@#\1***@#g'
}

rebuild_intent() {
    local target="$HAO_STATE_DIR/DEPLOY-INTENT.md" tmp intent_file service key value found=0
    tmp="$(mktemp "$HAO_STATE_DIR/.DEPLOY-INTENT.md.XXXXXX")"
    {
        cat <<EOF
# HAO 部署意图

> 本文件由 \`hao-state.sh intent\` 生成，请勿手工编辑。
> 生成时间: $(date -u +%Y-%m-%dT%H:%M:%SZ)

**请把这份文件存到你自己的笔记或仓库里。**

它记录的是部署时你给出的那些回答。\`HANDOFF.md\` 描述「这台机器现在是什么样」，
随机器一起消失；本文件描述「怎么再造一台一样的」—— 在一台新机器上照着重放
一遍，就能得到等价的部署。这是「机器即用即抛」能成立的前提。

本文件**不含任何密钥**。凭据按设计不可重放：新机器上会重新生成。需要保留旧密码
（数据库口令、API key 等）的，必须在销毁机器前自己从凭据文件导出 ——
路径见 \`hao-state.sh credentials\`，只有路径，内容要你自己去取。

仓库地址里如果内嵌过凭据，这里存的是脱敏形式（\`***\`），重放时需要你重新提供。
EOF
        for intent_file in "$HAO_STATE_DIR"/services/*.intent; do
            [ -f "$intent_file" ] || continue
            service="$(basename "$intent_file" .intent)"
            found=$((found + 1))
            printf '\n## %s\n\n' "$service"
            while IFS=$'\t' read -r key value; do
                [ -n "$key" ] || continue
                printf -- '- `%s`: %s\n' "$key" "${value:-（留空）}"
            done < "$intent_file"
        done
        [ "$found" -eq 0 ] && printf '\n（还没有记录任何部署意图。）\n'
    } > "$tmp"
    chmod 644 "$tmp"
    mv "$tmp" "$target"
}

cmd_intent() {
    local service="${1:-}"
    [ -n "$service" ] || die "intent 需要 <service> 以及至少一个 key=value"
    shift
    [ "$#" -gt 0 ] || die "intent 需要至少一个 key=value"

    [[ "$service" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
        || die "非法服务 ID（只允许小写字母、数字、连字符）: $service"

    init_state
    local intent_file="$HAO_STATE_DIR/services/$service.intent"
    local tmp
    tmp="$(mktemp "$HAO_STATE_DIR/services/.${service}.intent.XXXXXX")"

    local entry key value clean redacted=0 count=0
    for entry in "$@"; do
        case "$entry" in
            *=*) ;;
            *) rm -f "$tmp"; die "意图条目格式错误（应为 key=value）: $entry" ;;
        esac
        key="${entry%%=*}"
        value="${entry#*=}"
        if ! [[ "$key" =~ ^[a-z][a-z0-9_]*$ ]]; then
            rm -f "$tmp"
            die "非法 key 名（只允许小写字母、数字、下划线）: $key"
        fi
        # 意图文件是 0644 且要被带离本机的，凭据绝不能进来。
        if [[ "$key" =~ $HAO_INTENT_SECRETISH ]]; then
            rm -f "$tmp"
            die "拒绝把凭据写进意图文件: $key。意图文件权限 0644 且要交给用户带走，密钥请用 hao-secret.sh write。"
        fi
        case "$value" in
            *$'\n'*) rm -f "$tmp"; die "$key 的值包含换行，无法写入 key=value 格式" ;;
        esac
        clean="$(hao_redact_url_creds "$value")"
        [ "$clean" = "$value" ] || redacted=$((redacted + 1))
        printf '%s\t%s\n' "$key" "$clean" >> "$tmp"
        count=$((count + 1))
    done

    chmod 644 "$tmp"
    mv "$tmp" "$intent_file"
    rebuild_intent

    echo "已记录部署意图: $service（$count 项）"
    [ "$redacted" -gt 0 ] && echo "其中 $redacted 项的内嵌凭据已脱敏。"
    echo "意图文档: $HAO_STATE_DIR/DEPLOY-INTENT.md"
    echo "收尾时提醒用户把它存到自己的笔记或仓库里 —— 机器销毁后这份就没了。"
    return 0
}

# result 是否合法。record 用它拦新记录，services 用它标出存量的非法值 ——
# 两处必须是同一份清单，否则又会漂。
hao_result_legal() {
    local want="$1" r
    for r in $HAO_RESULTS; do
        [ "$want" = "$r" ] && return 0
    done
    return 1
}

# ==================== amend ====================
# 只改一个已有记录的 result，资源清单与哈希原样保留。
#
# 为什么需要它：record 是整体替换，所以"把 result 从一个词改成另一个词"过去只能
# 把全部资源重新列一遍 —— 少列一个就静默丢掉一个资源，而这个操作恰好最常发生在
# 「接手一台旧机器、发现存量记录里有非法 result」的时候，那时资源清单是唯一的
# 事实来源，最不该被手工重打一遍。
#
# recorded_at 不动：资源的哈希是那个时刻算的，改一个词不该让它看起来像刚重新采集过。
cmd_amend() {
    local service="${1:-}"
    [ -n "$service" ] || die "amend 需要 <service> --result <result>"
    shift
    local result=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --result)
                result="${2:-}"
                [ -n "$result" ] || die "--result 需要一个取值（$HAO_RESULTS）"
                shift 2
                ;;
            *) die "未知参数: $1（amend 只支持 --result）" ;;
        esac
    done
    [ -n "$result" ] || die "amend 需要 --result <result>"
    hao_result_legal "$result" || die "非法 result: $result（可用: $HAO_RESULTS）"

    local state_file="$HAO_STATE_DIR/services/$service.json"
    [ -f "$state_file" ] || die "没有 $service 的记录，amend 只能改已有记录。要新建用 record。"

    local old_result tmp
    old_result="$(sed -n 's/^[[:space:]]*"result": "\([^"]*\)",*$/\1/p' "$state_file" | head -1)"
    if [ "$old_result" = "$result" ]; then
        echo "$service 的 result 已经是 $result，没有改动。"
        return 0
    fi
    tmp="$(mktemp "$HAO_STATE_DIR/services/.${service}.json.XXXXXX")"
    sed 's|^\([[:space:]]*"result": "\)[^"]*\(",*\)$|\1'"$result"'\2|' "$state_file" > "$tmp"
    # 改完必须真的变了，否则说明这份 json 的形状和预期不一致，宁可不动
    if [ "$(sed -n 's/^[[:space:]]*"result": "\([^"]*\)",*$/\1/p' "$tmp" | head -1)" != "$result" ]; then
        rm -f "$tmp"
        die "改写 $state_file 的 result 失败（文件形状不符合预期），没有动它。"
    fi
    chmod 644 "$tmp"
    mv "$tmp" "$state_file"
    rebuild_manifest
    echo "已把 $service 的 result 从 ${old_result:-（空）} 改为 $result"
    echo "资源清单与哈希未变，recorded_at 保持原值。"
    echo "别忘了在收尾时运行: hao-state.sh handoff"
}

# ==================== remove ====================
# 删掉一个服务的记录（.json / .resources / .intent）并重建 manifest。
#
# 为什么需要它：卸载流程过去是手工 `rm -f /var/lib/hao/services/<svc>.*`，而
# 「服务还在、记录先没了」的后果很具体 —— 下一个 agent 会把主机上那些文件当成
# 无主资源，要么拒绝操作、要么在重建时覆盖掉。所以默认先检查记录里的资源是不是
# 还留在主机上，还在就拒绝删除。
#
# 确实要放弃归属时（服务转交用户自己维护、资源已在别处登记）才用 --force。
# 它只重建 manifest.json；HANDOFF.md 与 DEPLOY-INTENT.md 由 handoff 重建，
# 所以收尾仍要跑一次 handoff，输出里会提醒。
cmd_remove() {
    local service="${1:-}"
    [ -n "$service" ] || die "remove 需要 <service> [--force]"
    shift
    local force=false
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --force) force=true; shift ;;
            *) die "未知参数: $1（remove 只支持 --force）" ;;
        esac
    done

    local state_file="$HAO_STATE_DIR/services/$service.json"
    local resources_file="$HAO_STATE_DIR/services/$service.resources"
    local intent_file="$HAO_STATE_DIR/services/$service.intent"
    [ -f "$state_file" ] || [ -f "$resources_file" ] || [ -f "$intent_file" ] \
        || die "没有 $service 的记录，无需删除。"

    # 记录里的资源（含 secret 凭据）还留在主机上吗？
    local ownership hash path
    local -a still_there=()
    if [ -f "$resources_file" ]; then
        while IFS=$'\t' read -r ownership hash path || [ -n "$path" ]; do
            [ -n "$path" ] || continue
            if [ -e "$path" ]; then
                still_there+=("$ownership  $path")
            fi
        done < "$resources_file"
    fi

    if [ "${#still_there[@]}" -gt 0 ] && [ "$force" != true ]; then
        echo "拒绝删除 $service 的记录：它的资源还在主机上。" >&2
        printf '  %s\n' "${still_there[@]}" >&2
        cat >&2 <<'EOF'

先按 references/uninstall.md 把服务真正卸掉（删文件、停服务、删容器），再回来 remove。
如果这些资源是有意保留的（例如服务已转交用户自己维护），用
`remove <service> --force` 明确放弃归属 —— 之后它们归用户，不再受 HAO 管。

不加 --force 是为了避免"服务还在、记录先没了"：下一个 agent 会把它们当成无主资源，
要么拒绝操作，要么在重建时覆盖掉。
EOF
        return 1
    fi

    local msg="已删除服务 $service 的记录"
    if [ "${#still_there[@]}" -gt 0 ]; then
        msg="$msg（--force：${#still_there[@]} 个资源仍在主机上，归属已放弃）"
    fi
    rm -f "$state_file" "$resources_file" "$intent_file"
    rebuild_manifest
    echo "$msg"
    echo "别忘了在收尾时运行: hao-state.sh handoff（重建 HANDOFF.md 与 DEPLOY-INTENT.md）"
}

# ==================== orphans ====================
# 找出「带 HAO 归属头、但不在任何 services/*.resources 里」的文件。
#
# 为什么需要它：漏跑一次 record 的后果是静默的 —— 文件在主机上、归属头也在，
# 但 drift 不看它、manifest 里没有它、卸载流程也不会带走它。反过来说，归属头正是
# 反查这类漏记的钩子：hao-guard.sh 靠它判归属，这里靠它对账。
# 接手一台别人（或以前的自己）部署过的机器时，这一条比什么都实用。
#
# 只扫 HAO 可能写入的目录，不扫整个文件系统 —— 后者慢，而且会撞上无关的副本。
HAO_ORPHAN_DIRS_DEFAULT="${HAO_ORPHAN_DIRS_DEFAULT:-/etc/nginx /etc/apt /etc/systemd/system /etc/fail2ban /etc/sysctl.d /etc/security /etc/letsencrypt/renewal-hooks /etc/docker /etc/hao /usr/local/bin /opt:3}"
# /opt 可能包含大量站点源码和依赖，因此默认限深 3，以控制扫描开销。
# 这能覆盖 /opt/<服务>/<文件> 等浅层路径，但更深的配置或备份不会被扫描。
# 需要完整排查时显式运行 `orphans /opt`，递归扫描整个目录树。

# 列出一个目录里带归属头的文件。depth 为空 = 无限递归。
scan_hao_files() {
    local dir="$1" depth="$2"
    if [ -n "$depth" ]; then
        find "$dir" -maxdepth "$depth" -type f -exec grep -Il 'Managed by HAO' {} + 2>/dev/null || true
    else
        grep -rIl 'Managed by HAO' "$dir" 2>/dev/null || true
    fi
}

cmd_orphans() {
    local -a dirs=()
    if [ "$#" -gt 0 ]; then
        dirs=("$@")
    else
        # shellcheck disable=SC2206  # 有意做词分割：这是一份空格分隔的目录清单
        dirs=($HAO_ORPHAN_DIRS_DEFAULT)
    fi

    local recorded="" f d depth entry found=0
    if [ -d "$HAO_STATE_DIR/services" ]; then
        recorded="$(cut -f3 "$HAO_STATE_DIR"/services/*.resources 2>/dev/null | sort -u || true)"
    fi
    # 前后各补一个换行，下面用 *$'\n'路径$'\n'* 做整行匹配
    recorded=$'\n'"$recorded"$'\n'

    echo "带 HAO 归属头但没有被 record 记录的文件（只列路径，不打印内容）:"
    for entry in "${dirs[@]}"; do
        # <目录> 或 <目录>:<深度>
        d="${entry%%:*}"
        depth=""
        case "$entry" in
            *:*)
                depth="${entry##*:}"
                case "$depth" in
                    ''|*[!0-9]*) die "非法的扫描深度: $entry（形如 /opt:3）" ;;
                esac
                ;;
        esac
        [ -d "$d" ] || continue
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            # 下面两处判断都刻意**不用管道**。`printf … | grep -q` 和
            # `head … | grep -q` 在 set -o pipefail 下会咬人：grep -q 命中就立刻退出，
            # 左边还在写就收到 EPIPE，于是整条管道返回 141（非 0）——判断结果被反转。
            # 而它是否发生取决于左边的数据量有没有一次写完，所以在小样本的测试里
            # 永远看不到，真机上（记录几十条路径时）才冒出来：本来记录过的文件被
            # 报成"没记录"。用纯 bash 匹配没有这个问题，也不起子进程。
            case "$(head -n 12 "$f" 2>/dev/null)" in
                *"Managed by HAO"*) ;;
                *) continue ;;
            esac
            case "$recorded" in
                *$'\n'"$f"$'\n'*) continue ;;
            esac
            case "$f" in
                *.bak.*|*.disabled) echo "  $f  （像是备份/停用件，确认线上配置无误后可以删）" ;;
                *) echo "  $f" ;;
            esac
            found=$((found + 1))
        done < <(scan_hao_files "$d" "$depth")
    done
    if [ "$found" -eq 0 ]; then
        echo "  （无 —— 所有带归属头的文件都在记录里）"
        return 0
    fi
    echo "合计 $found 个。每一个都要么补进对应服务的 record，要么确认可以删掉。"
    echo "补记的办法：hao-state.sh record <service> <result> OWNERSHIP:PATH ...（记得把该服务原有的资源一起列上，record 是整体替换）"
    return 0
}

# ==================== record ====================
cmd_record() {
    local service="${1:-}" result="${2:-}"
    [ -n "$service" ] && [ -n "$result" ] || die "record 需要 <service> <result> 以及至少一个 OWNERSHIP:PATH"
    shift 2
    [ "$#" -gt 0 ] || die "record 需要至少一个 OWNERSHIP:PATH"

    [[ "$service" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
        || die "非法服务 ID（只允许小写字母、数字、连字符）: $service"
    hao_result_legal "$result" \
        || die "非法 result: $result（可用: $HAO_RESULTS）"

    init_state
    local state_file="$HAO_STATE_DIR/services/$service.json"
    local resources_file="$HAO_STATE_DIR/services/$service.resources"
    local state_tmp resources_tmp
    state_tmp="$(mktemp "$HAO_STATE_DIR/services/.${service}.json.XXXXXX")"
    resources_tmp="$(mktemp "$HAO_STATE_DIR/services/.${service}.resources.XXXXXX")"

    local entry ownership path hash first=true
    local managed_count=0 overall_ownership="observed" skipped=""

    for entry in "$@"; do
        case "$entry" in
            *:*) ;;
            *) rm -f "$state_tmp" "$resources_tmp"; die "资源条目格式错误（应为 OWNERSHIP:PATH）: $entry" ;;
        esac
        ownership="${entry%%:*}"
        path="${entry#*:}"
        case "$ownership" in
            managed|shared|observed|secret) ;;
            *) rm -f "$state_tmp" "$resources_tmp"; die "非法归属类别: $ownership（可用: managed shared observed secret）" ;;
        esac
        if [ ! -e "$path" ]; then
            skipped="$skipped $path"
            continue
        fi
        hash="$(hao_resource_hash "$path" "$ownership")"
        printf '%s\t%s\t%s\n' "$ownership" "$hash" "$path" >> "$resources_tmp"
        [ "$ownership" = "managed" ] && managed_count=$((managed_count + 1))
    done
    [ "$managed_count" -gt 0 ] && overall_ownership="managed"

    {
        printf '{\n'
        printf '  "schema_version": 1,\n'
        printf '  "managed_by": "HAO",\n'
        printf '  "service": "%s",\n' "$(hao_json_escape "$service")"
        printf '  "release": "%s",\n' "$(hao_json_escape "$HAO_RELEASE")"
        printf '  "recorded_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '  "result": "%s",\n' "$(hao_json_escape "$result")"
        printf '  "ownership": "%s",\n' "$overall_ownership"
        printf '  "resources": [\n'
        while IFS=$'\t' read -r ownership hash path; do
            [ -n "$path" ] || continue
            if [ "$first" = true ]; then first=false; else printf ',\n'; fi
            printf '    {"path": "%s", "ownership": "%s", "sha256": "%s"}' \
                "$(hao_json_escape "$path")" "$ownership" "$hash"
        done < "$resources_tmp"
        printf '\n  ]\n}\n'
    } > "$state_tmp"

    chmod 644 "$state_tmp" "$resources_tmp"
    mv "$state_tmp" "$state_file"
    mv "$resources_tmp" "$resources_file"
    rebuild_manifest

    echo "已记录服务 $service ($result, ownership=$overall_ownership)"
    [ -n "$skipped" ] && echo "跳过不存在的路径:$skipped"
    echo "清单: $HAO_STATE_DIR/manifest.json"
    echo "别忘了在收尾时运行: hao-state.sh handoff"
}

# ==================== drift ====================
cmd_drift() {
    local resources_file service ownership expected path actual
    local drift_count=0 service_drift
    echo "HAO 归属与漂移检查"
    if [ ! -d "$HAO_STATE_DIR/services" ]; then
        echo "  未找到 HAO 状态目录: $HAO_STATE_DIR"
        return 0
    fi
    for resources_file in "$HAO_STATE_DIR"/services/*.resources; do
        [ -f "$resources_file" ] || continue
        service="$(basename "$resources_file" .resources)"
        service_drift=0
        while IFS=$'\t' read -r ownership expected path; do
            [ "$ownership" = "managed" ] || continue
            if [ ! -e "$path" ]; then
                echo "  [漂移] $service: 资源缺失 $path"
                service_drift=$((service_drift + 1))
                continue
            fi
            actual="$(hao_resource_hash "$path" "$ownership")"
            if [ "$actual" != "$expected" ]; then
                echo "  [漂移] $service: 已被修改 $path"
                service_drift=$((service_drift + 1))
            fi
        done < "$resources_file"
        [ "$service_drift" -eq 0 ] && echo "  [正常] $service: managed 资源与记录一致"
        drift_count=$((drift_count + service_drift))
    done
    echo "漂移汇总: $drift_count 项 managed 资源发生变化"
    [ "$drift_count" -eq 0 ]
}

# ==================== ownership / services / credentials ====================
cmd_ownership() {
    local service="${1:-}"
    [ -n "$service" ] || die "ownership 需要 <service>"
    local state_file="$HAO_STATE_DIR/services/$service.json"
    if [ ! -r "$state_file" ]; then
        echo "untracked"
        return 0
    fi
    sed -n 's/^[[:space:]]*"ownership": "\([^"]*\)",*$/\1/p' "$state_file" | head -1
}

cmd_services() {
    local state_file service result recorded width=14
    local -a illegal=()
    if [ ! -d "$HAO_STATE_DIR/services" ]; then
        echo "未找到 HAO 状态目录: $HAO_STATE_DIR（这台机器还没有被 HAO 管理过）"
        return 0
    fi
    # 列宽按最长的 service ID 算，不用固定值：站点的 ID 是 site-<用户起的名字>，
    # 一长就会把后面几列挤错位，而这张表会被原样抄进 HANDOFF.md 交给下一个 agent。
    for state_file in "$HAO_STATE_DIR"/services/*.json; do
        [ -f "$state_file" ] || continue
        service="$(basename "$state_file" .json)"
        [ "${#service}" -gt "$width" ] && width="${#service}"
    done
    printf "%-${width}s %-10s %-10s %s\n" SERVICE RESULT OWNERSHIP RECORDED_AT
    for state_file in "$HAO_STATE_DIR"/services/*.json; do
        [ -f "$state_file" ] || continue
        service="$(basename "$state_file" .json)"
        result="$(sed -n 's/^[[:space:]]*"result": "\([^"]*\)",*$/\1/p' "$state_file" | head -1)"
        recorded="$(sed -n 's/^[[:space:]]*"recorded_at": "\([^"]*\)",*$/\1/p' "$state_file" | head -1)"
        # 存量记录可能是更早的版本写的，里面的 result 不一定是现在的合法取值。
        # record 只能拦新的，落盘的那些不会有人发现 —— 除了在这里点出来。
        hao_result_legal "$result" || illegal+=("$service=$result")
        printf "%-${width}s %-10s %-10s %s\n" \
            "$service" "$result" "$(cmd_ownership "$service")" "$recorded"
    done
    if [ "${#illegal[@]}" -gt 0 ]; then
        echo ""
        echo "记录异常：下面这些服务的 result 不在合法取值内（$HAO_RESULTS）。"
        echo "它们多半是更早的版本写下的，读到这种值说明记录不可信，先修正再据它做判断："
        local item
        for item in "${illegal[@]}"; do
            echo "  ${item%%=*}: \"${item#*=}\"  ->  hao-state.sh amend ${item%%=*} --result <合法词>"
        done
    fi
}

cmd_credentials() {
    local resources_file service ownership hash path found=0
    if [ ! -d "$HAO_STATE_DIR/services" ]; then
        echo "未找到 HAO 状态目录: $HAO_STATE_DIR"
        return 0
    fi
    echo "凭据文件路径（只列路径，永不打印内容）:"
    for resources_file in "$HAO_STATE_DIR"/services/*.resources; do
        [ -f "$resources_file" ] || continue
        service="$(basename "$resources_file" .resources)"
        while IFS=$'\t' read -r ownership hash path; do
            [ "$ownership" = "secret" ] || continue
            echo "  $service: $path"
            found=$((found + 1))
        done < "$resources_file"
    done
    [ "$found" -eq 0 ] && echo "  （无记录）"
    return 0
}

# ==================== handoff ====================
# 发现本机 AI 助手的全局指令文件。分两条路，都不绑定具体 runtime：
#   1. 已知配置目录约定（下表，可扩充）
#   2. 通用扫描：home 下点目录里已存在的 AGENTS.md / CLAUDE.md
# 表里没有、也还没建过指令文件的 runtime，用 --agent-file 显式指定。
HAO_AGENT_CANDIDATES=(
    ".claude:.claude/CLAUDE.md"
    ".pi/agent:.pi/agent/AGENTS.md"
    ".config/opencode:.config/opencode/AGENTS.md"
)

detect_agent_files() {
    local home="$1" entry conf_dir file dir
    {
        for entry in "${HAO_AGENT_CANDIDATES[@]}"; do
            IFS=':' read -r conf_dir file <<< "$entry"
            [ -d "$home/$conf_dir" ] && echo "$home/$file"
        done

        # 通用扫描：只看点目录，避免命中 home 下用户自己项目里的 AGENTS.md
        for dir in "$home"/.*/; do
            [ -d "$dir" ] || continue
            case "$(basename "$dir")" in .|..) continue ;; esac
            find "$dir" -maxdepth 2 -type f \
                \( -name 'AGENTS.md' -o -name 'CLAUDE.md' \) 2>/dev/null
        done
    } | sort -u
}

# 用 <!-- MARKER BEGIN/END --> 标记块幂等写入，块外内容保留
write_marker_block() {
    local file="$1" marker="$2" owner="$3"
    local begin="<!-- ${marker} BEGIN (managed by HAO, do not edit inside) -->"
    local end="<!-- ${marker} END -->"
    local dir tmp probe created_dir owner_group
    local -a missing_dirs=()
    local has_begin=false has_end=false

    # 标记块必须成对；只剩单边说明文件被手工改坏了，此时原地替换会吞掉
    # 标记之后的用户内容，必须拒绝写入。
    if [ -f "$file" ]; then
        grep -qF "$begin" "$file" && has_begin=true
        grep -qF "$end" "$file" && has_end=true
        if [ "$has_begin" != "$has_end" ]; then
            die "${marker} 标记块不成对（BEGIN/END 只找到一个），拒绝改写: $file。请手工修复或删除残留标记后重试。"
        fi
    fi

    dir="$(dirname "$file")"
    probe="$dir"
    while [ ! -d "$probe" ]; do
        missing_dirs+=("$probe")
        probe="$(dirname "$probe")"
    done
    mkdir -p "$dir"
    tmp="$(mktemp "${file}.hao.XXXXXX")"

    if [ -f "$file" ] && [ "$has_begin" = true ]; then
        awk -v begin="$begin" -v end="$end" '
            $0 == begin { skip=1; next }
            $0 == end   { skip=0; next }
            !skip { print }
        ' "$file" > "$tmp"
    elif [ -f "$file" ]; then
        cat "$file" > "$tmp"
        echo "" >> "$tmp"
    fi

    {
        echo "$begin"
        cat
        echo "$end"
    } >> "$tmp"

    chmod 644 "$tmp"
    mv "$tmp" "$file"

    if [ "${EUID:-$(id -u)}" -eq 0 ] && id "$owner" >/dev/null 2>&1; then
        owner_group="$owner:$(id -gn "$owner")"
        for created_dir in "${missing_dirs[@]}"; do
            chown "$owner_group" "$created_dir"
        done
        chown "$owner_group" "$file"
    fi
}

cmd_handoff() {
    local owner="${SUDO_USER:-root}" skip_agent_files=false
    local -a explicit_agent_files=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --user)
                owner="${2:-}"
                [ -n "$owner" ] || die "--user 需要用户名"
                shift 2
                ;;
            --agent-file)
                [ -n "${2:-}" ] || die "--agent-file 需要文件路径"
                explicit_agent_files+=("$2")
                shift 2
                ;;
            --skip-agent-files)
                skip_agent_files=true
                shift
                ;;
            *) die "未知参数: $1" ;;
        esac
    done
    id "$owner" >/dev/null 2>&1 || die "用户不存在: $owner"

    init_state
    # 每次 handoff 都重建 manifest 与意图文档：卸载流程会直接删 services/<svc>.*
    # （见 references/uninstall.md），只有在这里重建才能让它们不留下已经不存在的
    # 服务。下一个 agent 读到幻影服务会拒绝操作或误覆盖。
    rebuild_manifest
    rebuild_intent
    local handoff="$HAO_STATE_DIR/HANDOFF.md"
    local tmp
    tmp="$(mktemp "${handoff}.tmp.XXXXXX")"

    {
        cat <<EOF
# HAO 主机交接文档

> 本文件由 \`hao-state.sh handoff\` 生成，请勿手工编辑。
> 生成时间: $(date -u +%Y-%m-%dT%H:%M:%SZ)

任何接手这台主机的 AI agent，先读完本文件再动手。

## 这台机器的状态

EOF
        cmd_services | sed 's/^/    /'
        cat <<EOF

完整清单: \`$HAO_STATE_DIR/manifest.json\`
部署意图（怎么在新机器上重放）: \`$HAO_STATE_DIR/DEPLOY-INTENT.md\`

## 凭据

EOF
        cmd_credentials | sed 's/^/    /'
        cat <<'EOF'

凭据文件权限为 0600。**只汇报路径，永远不要读取、打印或转述其内容**，
包括用户主动要求时也先确认对方理解这会把密钥留在对话记录里。

## 接手规则

1. **先查后改**：动手前运行 `hao-state.sh drift`。如果报告了漂移，
   停下来向用户解释差异，不要直接覆盖。managed 资源的漂移意味着
   有人手工改过 HAO 管理的文件，覆盖会丢掉那些改动。
2. **归属分级**：`managed` 由 HAO 负责，可按流程重写；`shared` 和
   `observed` 属于周边系统，不要因为它出现在清单里就覆盖它。
3. **不碰无主资源**：如果目标路径已存在且不是 HAO 管理的，停下来问用户，
   不要覆盖。判断方法见 skill 的 `hao-guard.sh`。
4. **状态只经脚本写**：所有状态更新都必须通过 `hao-state.sh record`，
   收尾时运行 `hao-state.sh handoff` 刷新本文件。手写状态文件会让
   下一个接手的 agent 读到不可信的记录。
5. **root 操作要确认**：安装包、启用服务、改 Nginx/systemd 之前，
   先把将要发生的变更讲清楚并取得用户确认。
6. **站点更新用生成的脚本**：`/usr/local/bin/<站点ID>-update`，
   不要手工重复 clone/build/publish 流程。
7. **部署新东西后补记意图**：`hao-state.sh intent <service> key=value ...`，
   然后提醒用户把 `DEPLOY-INTENT.md` 存到他自己的笔记里。那份文件是这台机器
   销毁后唯一还能用的东西。意图文件里不许出现任何凭据。

## 这台机器上可用的更新命令

EOF
        # 更新脚本用通用命名 <id>-update，所以 glob 会撞上和 HAO 无关的脚本。
        # 靠脚本里的 `# Managed by HAO` 头筛一遍 —— 与 hao-guard.sh 同一个判据。
        local script found=0
        for script in /usr/local/bin/*-update; do
            [ -x "$script" ] || continue
            head -n 12 "$script" 2>/dev/null | grep -q 'Managed by HAO' || continue
            echo "    sudo $(basename "$script")"
            found=$((found + 1))
        done
        [ "$found" -eq 0 ] && echo "    （无）"
    } > "$tmp"

    chmod 644 "$tmp"
    mv "$tmp" "$handoff"
    echo "交接文档已生成: $handoff"

    # 把指针写进本机 AI 助手的全局指令文件，让下一个 agent 不必被告知就能发现
    if [ "$skip_agent_files" = true ]; then
        echo "已按要求跳过 AI 助手指令文件写入。"
        return 0
    fi

    local home agent_file wrote=0
    local -a agent_files=()
    if [ "${#explicit_agent_files[@]}" -gt 0 ]; then
        agent_files=("${explicit_agent_files[@]}")
    else
        home="$(getent passwd "$owner" | awk -F: '{print $6}')"
        if [ -z "$home" ] || [ ! -d "$home" ]; then
            echo "用户 $owner 没有可用 home 目录，跳过指令文件写入。"
            return 0
        fi
        while IFS= read -r agent_file; do
            [ -n "$agent_file" ] && agent_files+=("$agent_file")
        done < <(detect_agent_files "$home")
    fi

    for agent_file in "${agent_files[@]}"; do
        write_marker_block "$agent_file" "HAO-HANDOFF" "$owner" <<EOF

## 这台主机由 HAO 管理

部署、更新或排查本机服务前，先读 \`$handoff\`，并遵守其中的接手规则。
用 \`hao-state.sh drift\` 检查漂移，用 \`hao-state.sh services\` 看装了什么。
凭据文件只汇报路径，不要打印内容。
EOF
        echo "已写入指令文件: $agent_file"
        wrote=$((wrote + 1))
    done

    [ "$wrote" -eq 0 ] && echo "未检测到已安装的 AI 助手，跳过指令文件写入。"
    return 0
}

# ==================== convention ====================
# 把一段约定文本写进本机 AI 助手的指令文件（标记块，幂等）。
# 供工具类模块复用（uv 的 Python 约定、gh 的 GitHub 约定等）。
# 约定正文从 stdin 读入；marker 决定标记块身份，不同模块互不覆盖。
cmd_convention() {
    local marker="${1:-}"
    [ -n "$marker" ] || die "convention 需要 <MARKER-ID>，例如 HAO-UV"
    [[ "$marker" =~ ^[A-Z][A-Z0-9-]*$ ]] \
        || die "MARKER-ID 只允许大写字母、数字、连字符: $marker"
    shift

    local owner="${SUDO_USER:-root}" skip=false
    local -a explicit=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --user)
                owner="${2:-}"
                [ -n "$owner" ] || die "--user 需要用户名"
                shift 2
                ;;
            --agent-file)
                [ -n "${2:-}" ] || die "--agent-file 需要文件路径"
                explicit+=("$2")
                shift 2
                ;;
            --skip-agent-files) skip=true; shift ;;
            *) die "未知参数: $1" ;;
        esac
    done
    id "$owner" >/dev/null 2>&1 || die "用户不存在: $owner"

    if [ "$skip" = true ]; then
        echo "已按要求跳过约定写入。"
        return 0
    fi

    local body
    body="$(cat)"
    [ -n "$body" ] || die "约定正文为空（应从 stdin 传入）"

    local home agent_file wrote=0
    local -a agent_files=()
    if [ "${#explicit[@]}" -gt 0 ]; then
        agent_files=("${explicit[@]}")
    else
        home="$(getent passwd "$owner" | awk -F: '{print $6}')"
        if [ -z "$home" ] || [ ! -d "$home" ]; then
            die "用户 $owner 没有可用 home 目录"
        fi
        while IFS= read -r agent_file; do
            [ -n "$agent_file" ] && agent_files+=("$agent_file")
        done < <(detect_agent_files "$home")
    fi

    for agent_file in "${agent_files[@]}"; do
        printf '%s\n' "$body" | write_marker_block "$agent_file" "$marker" "$owner"
        echo "约定已写入: $agent_file"
        wrote=$((wrote + 1))
    done

    if [ "$wrote" -eq 0 ]; then
        echo "未检测到 AI 助手指令文件，约定未写入。"
        echo "装好助手后重跑，或用 --agent-file 显式指定。"
    fi
    return 0
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
    record)      shift; cmd_record "$@" ;;
    amend)       shift; cmd_amend "$@" ;;
    remove)      shift; cmd_remove "$@" ;;
    orphans)     shift; cmd_orphans "$@" ;;
    intent)      shift; cmd_intent "$@" ;;
    drift)       shift; cmd_drift "$@" ;;
    ownership)   shift; cmd_ownership "$@" ;;
    services)    shift; cmd_services "$@" ;;
    credentials) shift; cmd_credentials "$@" ;;
    handoff)     shift; cmd_handoff "$@" ;;
    convention)  shift; cmd_convention "$@" ;;
    -h|--help|"") usage ;;
    *) die "未知子命令: $1（可用: record amend remove intent drift orphans ownership services credentials handoff convention）" ;;
esac
