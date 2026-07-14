#!/usr/bin/env bash
# AI 助手指令文件约定写入助手（供工具模块复用）
#
# 提供两个函数：
#   hao_detect_agent_files <home>
#       按候选表检测已安装（命令存在或配置目录已存在）的 AI 助手，
#       逐行输出其全局指令文件的绝对路径。
#   hao_write_agent_convention <file> <marker-id> <owner-user>
#       把 stdin 的约定内容用 <!-- <marker-id> BEGIN/END --> 标记块写入
#       指令文件。已有同名标记块则原地替换（幂等），文件其余内容保留；
#       新建的目录与文件在以 root 运行时归属 owner-user。
#
# 使用方（uv、git-github）各自定义约定文本与 marker-id，互不覆盖。

# 候选表：检测命令:配置目录:指令文件相对 home 的路径
HAO_AGENT_CANDIDATES=(
    "claude:.claude:.claude/CLAUDE.md"
    "pi:.pi/agent:.pi/agent/AGENTS.md"
    "codex:.codex:.codex/AGENTS.md"
    "opencode:.config/opencode:.config/opencode/AGENTS.md"
)

hao_detect_agent_files() {
    local home="$1" entry cmd conf_dir file
    for entry in "${HAO_AGENT_CANDIDATES[@]}"; do
        IFS=':' read -r cmd conf_dir file <<< "$entry"
        if command -v "$cmd" &>/dev/null || [ -d "$home/$conf_dir" ]; then
            echo "$home/$file"
        fi
    done
}

hao_write_agent_convention() {
    local file="$1" marker="$2" owner="$3"
    local begin="<!-- ${marker} BEGIN (managed by HAO, do not edit inside) -->"
    local end="<!-- ${marker} END -->"
    local dir tmp probe missing_dirs=() created_dir owner_group

    dir="$(dirname "$file")"
    # 记录将要新建的目录层级，写入后归属目标用户，避免留下 root 属主的用户目录
    probe="$dir"
    while [ ! -d "$probe" ]; do
        missing_dirs+=("$probe")
        probe="$(dirname "$probe")"
    done
    mkdir -p "$dir"
    tmp="$(mktemp "${file}.hao.XXXXXX")"

    if [ -f "$file" ] && grep -qF "$begin" "$file"; then
        # 原地替换已有标记块
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

    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        owner_group="$owner:$(id -gn "$owner")"
        for created_dir in "${missing_dirs[@]}"; do
            chown "$owner_group" "$created_dir"
        done
        chown "$owner_group" "$file"
    fi
}
