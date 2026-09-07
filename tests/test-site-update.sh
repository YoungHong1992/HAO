#!/usr/bin/env bash
set -euo pipefail

# 渲染 site-update-static.sh.tmpl 并真的跑一遍，覆盖三个分支：
#   1. 产物目录填错   -> 必须失败，且**线上目录内容不变**（这条是那个 P1 的回归测试：
#                        旧版本先 find -delete 再 cp，填错时线上内容已经没了）
#   2. 产物目录是空的 -> 必须失败，线上目录不变
#   3. 正常           -> 发布成功，旧内容被换掉
#
# 不碰主机：git 用本地裸仓库当 origin，systemctl 用 PATH 里的桩件顶掉。

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPL="$ROOT_DIR/skills/hao-deploy/templates/site-update-static.sh.tmpl"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "  ✗ $*" >&2; exit 1; }
ok()   { echo "  ✓ $*"; }

# ---------- 桩件：systemctl / runuser 都不真的动系统 ----------
mkdir -p "$WORK/bin"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/systemctl"
chmod +x "$WORK/bin/systemctl"
export PATH="$WORK/bin:$PATH"

# ---------- 一个真的 git 仓库当 origin ----------
git init -q --bare "$WORK/origin.git"
git -c init.defaultBranch=main init -q "$WORK/src"
(
    cd "$WORK/src"
    git config user.email t@example.com
    git config user.name test
    mkdir -p build
    echo "v1" > build/index.html
    git add -A
    git commit -qm init
    git branch -M main
    git remote add origin "$WORK/origin.git"
    git push -q origin main
)
git clone -q "$WORK/origin.git" "$WORK/clone"

render() {                       # render <输出> <产物目录> [额外的 sed 式替换…]
    local out="$1" output_dir="$2" content
    shift 2
    content="$(cat "$TMPL")"
    content="${content//@@SITE_ID@@/testsite}"
    content="${content//@@BRANCH@@/main}"
    content="${content//@@TARGET_USER@@/$(id -un)}"
    content="${content//@@TARGET_GROUP@@/$(id -gn)}"
    content="${content//@@TARGET_HOME@@/$HOME}"
    content="${content//@@BUILD_CMD@@/}"
    content="${content//@@OUTPUT_DIR@@/$output_dir}"
    content="${content//@@DOCROOT@@/$WEB}"
    # 模板里的路径是写死的 /opt/<id>，沙箱里指到临时克隆目录
    content="${content//\/opt\/testsite/$WORK/clone}"
    # 沙箱里没有 root，去掉 EUID 检查（被测的是发布逻辑，不是权限检查）
    content="${content//if \[ \"\$\{EUID:-\$(id -u)\}\" -ne 0 \]; then/if false; then}"
    # 可选：注入一处人为失败，用来测「中途炸掉」
    local sub
    for sub in "$@"; do
        content="${content//${sub%%|*}/${sub#*|}}"
    done
    printf '%s\n' "$content" > "$out"
    chmod +x "$out"
}

WEB="$WORK/web"
mkdir -p "$WEB"
echo "线上旧内容" > "$WEB/index.html"

echo "== 1. 产物目录填错 =="
render "$WORK/u-wrong.sh" "dist-typo"
if "$WORK/u-wrong.sh" >"$WORK/log1" 2>&1; then
    fail "产物目录不存在时应该失败"
fi
grep -q "产物目录不存在" "$WORK/log1" || fail "错误信息应说明产物目录不存在，实际: $(cat "$WORK/log1")"
[ "$(cat "$WEB/index.html")" = "线上旧内容" ] || fail "线上内容被破坏了 —— 这正是那个 P1"
ok "失败且线上内容完好"

echo "== 2. 产物目录是空的 =="
mkdir -p "$WORK/clone/empty"
render "$WORK/u-empty.sh" "empty"
if "$WORK/u-empty.sh" >"$WORK/log2" 2>&1; then
    fail "产物目录为空时应该失败"
fi
grep -q "产物目录是空的" "$WORK/log2" || fail "错误信息应说明产物目录为空，实际: $(cat "$WORK/log2")"
[ "$(cat "$WEB/index.html")" = "线上旧内容" ] || fail "线上内容被空目录覆盖了"
ok "失败且线上内容完好"

echo "== 3. 正常发布 =="
render "$WORK/u-ok.sh" "build"
"$WORK/u-ok.sh" >"$WORK/log3" 2>&1 || fail "正常情况下应该成功: $(cat "$WORK/log3")"
[ "$(cat "$WEB/index.html")" = "v1" ] || fail "没有发布成新内容，实际: $(cat "$WEB/index.html")"
[ -z "$(ls -d "$WEB".new.* 2>/dev/null || true)" ] || fail "留下了临时的 .new 目录"
[ -z "$(ls -d "$WEB".old.* 2>/dev/null || true)" ] || fail "留下了临时的 .old 目录"
ok "发布成功且没留临时目录"

echo "== 4. 发布中途炸掉 =="
# 把 chown 换成一条必然失败的命令，模拟磁盘满/权限错之类的中途失败
echo "v1-live" > "$WEB/index.html"
render "$WORK/u-boom.sh" "build" 'chown -R "$TARGET_USER:$TARGET_GROUP" "$STAGE"|false'
if "$WORK/u-boom.sh" >"$WORK/log4" 2>&1; then
    fail "中途失败时脚本不该返回成功"
fi
[ "$(cat "$WEB/index.html")" = "v1-live" ] || fail "中途失败时线上内容被破坏了"
[ -z "$(ls -d "$WEB".new.* 2>/dev/null || true)" ] || fail "中途失败后留下了 .new 临时目录"
[ -z "$(ls -d "$WEB".old.* 2>/dev/null || true)" ] || fail "中途失败后留下了 .old 临时目录"
ok "失败、线上内容完好、没留临时目录"

echo ""
echo "site 更新脚本测试通过"
