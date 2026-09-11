#!/usr/bin/env bash
set -euo pipefail

# hao-state.sh 行为测试
#
# 这是交接契约的守卫：状态格式漂了，下一个接手的 agent 就读到不可信的记录。
# 所有用例都在临时 HAO_STATE_DIR 里跑，绝不碰真实 /var/lib/hao；
# 指令文件写入一律用 --agent-file 指向临时文件，绝不碰真实 home。

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$ROOT_DIR/skills/hao-deploy/scripts/hao-state.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export HAO_STATE_DIR="$WORK/state"
export HAO_RELEASE="test-release"

fail=0
note() { echo "ok   $1"; }
bad()  { echo "FAIL $1" >&2; fail=1; }

# ---------- 空状态下的只读命令必须能用 ----------
"$STATE" services >/dev/null && note "空状态下 services 不报错"
"$STATE" drift >/dev/null && note "空状态下 drift 不报错"
[ "$("$STATE" ownership nothing)" = "untracked" ] \
    && note "未记录的服务返回 untracked" || bad "未记录服务应返回 untracked"

# ---------- record ----------
mkdir -p "$WORK/res"
echo "managed content" > "$WORK/res/managed.conf"
echo "system content"  > "$WORK/res/shared.conf"
printf 'SECRET=x\n'    > "$WORK/res/creds.env"

"$STATE" record nginx installed \
    "managed:$WORK/res/managed.conf" \
    "shared:$WORK/res/shared.conf" \
    "secret:$WORK/res/creds.env" \
    "managed:$WORK/res/does-not-exist" >/dev/null

[ -f "$HAO_STATE_DIR/manifest.json" ] && note "manifest.json 已生成" || bad "manifest.json 缺失"
[ "$("$STATE" ownership nginx)" = "managed" ] \
    && note "含 managed 资源的服务整体归属为 managed" || bad "整体归属判断错误"

# manifest 结构与内容
python3 - "$HAO_STATE_DIR/manifest.json" "$WORK/res/creds.env" <<'PY' || fail=1
import json, sys
d = json.load(open(sys.argv[1]))
creds = sys.argv[2]
assert d["schema_version"] == 1, "schema_version 必须是 1"
assert d["managed_by"] == "HAO", "managed_by 必须是 HAO"
svc = [s for s in d["services"] if s["service"] == "nginx"]
assert len(svc) == 1, "应有且仅有一条 nginx 记录"
svc = svc[0]
assert svc["release"] == "test-release", "release 未取自 HAO_RELEASE"
assert svc["result"] == "installed"
paths = {r["path"]: r for r in svc["resources"]}
assert creds in paths, "secret 资源未记录"
assert paths[creds]["sha256"] == "redacted", "secret 资源的哈希必须是 redacted"
assert paths[creds]["ownership"] == "secret"
assert not any("does-not-exist" in p for p in paths), "不存在的路径不应写入清单"
print("ok   manifest 结构、redacted 哈希、跳过缺失路径")
PY

# 凭据只列路径、不列内容
cred_out="$("$STATE" credentials)"
printf '%s' "$cred_out" | grep -qF "$WORK/res/creds.env" \
    && note "credentials 列出凭据路径" || bad "credentials 未列出路径"
printf '%s' "$cred_out" | grep -qF "SECRET=x" \
    && bad "credentials 泄漏了凭据内容" || note "credentials 不含凭据内容"

# ---------- 非法输入 ----------
if "$STATE" record BadService installed "managed:$WORK/res/managed.conf" >/dev/null 2>&1; then
    bad "未拒绝非法服务 ID"
else
    note "拒绝非法服务 ID"
fi
if "$STATE" record ok-svc bogus-result "managed:$WORK/res/managed.conf" >/dev/null 2>&1; then
    bad "未拒绝非法 result"
else
    note "拒绝非法 result"
fi
if "$STATE" record ok-svc installed "bogus:$WORK/res/managed.conf" >/dev/null 2>&1; then
    bad "未拒绝非法归属类别"
else
    note "拒绝非法归属类别"
fi

# ---------- drift ----------
"$STATE" drift >/dev/null && note "记录后 drift 干净（退出码 0）" || bad "刚记录就报漂移"

echo "手工修改" >> "$WORK/res/managed.conf"
if "$STATE" drift >/dev/null 2>&1; then
    bad "managed 资源被改后 drift 未报警"
else
    note "managed 资源被改后 drift 报警（退出码非 0）"
fi

# shared 资源变化不该触发漂移（我们只负责其中一部分）
echo "别人改的" >> "$WORK/res/shared.conf"
drift_out="$("$STATE" drift 2>&1 || true)"
printf '%s' "$drift_out" | grep -qF "shared.conf" \
    && bad "shared 资源变化不应报漂移" || note "shared 资源变化不报漂移"

# 恢复后漂移消失
printf 'managed content\n' > "$WORK/res/managed.conf"
"$STATE" drift >/dev/null && note "内容恢复后漂移消失" || bad "内容恢复后仍报漂移"

# managed 资源被删也要报
rm -f "$WORK/res/managed.conf"
if "$STATE" drift >/dev/null 2>&1; then
    bad "managed 资源缺失未报警"
else
    note "managed 资源缺失报警"
fi
printf 'managed content\n' > "$WORK/res/managed.conf"

# ---------- handoff ----------
AGENT_FILE="$WORK/agent-CLAUDE.md"
printf '# 用户原有内容\n\n请保留我。\n' > "$AGENT_FILE"
"$STATE" handoff --user "$(id -un)" --agent-file "$AGENT_FILE" >/dev/null

HANDOFF="$HAO_STATE_DIR/HANDOFF.md"
[ -f "$HANDOFF" ] && note "HANDOFF.md 已生成" || bad "HANDOFF.md 缺失"
grep -q "nginx" "$HANDOFF" && note "HANDOFF.md 含服务清单" || bad "HANDOFF.md 缺服务清单"
grep -qF "$WORK/res/creds.env" "$HANDOFF" \
    && note "HANDOFF.md 含凭据路径" || bad "HANDOFF.md 缺凭据路径"
grep -qF "SECRET=x" "$HANDOFF" \
    && bad "HANDOFF.md 泄漏了凭据内容" || note "HANDOFF.md 不含凭据内容"

grep -q "请保留我" "$AGENT_FILE" \
    && note "指令文件保留了用户原有内容" || bad "指令文件的用户内容被吞掉"
[ "$(grep -c 'HAO-HANDOFF BEGIN' "$AGENT_FILE")" -eq 1 ] \
    && note "标记块只有一份" || bad "标记块数量不对"

# 重复运行必须原地替换而不是追加
"$STATE" handoff --user "$(id -un)" --agent-file "$AGENT_FILE" >/dev/null
[ "$(grep -c 'HAO-HANDOFF BEGIN' "$AGENT_FILE")" -eq 1 ] \
    && note "重跑 handoff 标记块不重复（幂等）" || bad "重跑 handoff 追加了重复标记块"
[ "$(grep -c '请保留我' "$AGENT_FILE")" -eq 1 ] \
    && note "重跑后用户内容未被复制" || bad "重跑后用户内容重复"

# 单边标记说明文件被改坏，必须拒绝写入而不是吞掉内容
printf '# x\n<!-- HAO-HANDOFF BEGIN (managed by HAO, do not edit inside) -->\n重要内容\n' \
    > "$WORK/broken.md"
if "$STATE" handoff --user "$(id -un)" --agent-file "$WORK/broken.md" >/dev/null 2>&1; then
    bad "未拒绝写入标记不成对的文件"
else
    note "拒绝写入标记不成对的文件"
fi
grep -q "重要内容" "$WORK/broken.md" \
    && note "被拒绝时未破坏原文件" || bad "被拒绝时破坏了原文件"

"$STATE" handoff --user "$(id -un)" --skip-agent-files >/dev/null \
    && note "--skip-agent-files 可用" || bad "--skip-agent-files 失败"

# ---------- handoff 必须重建 manifest ----------
# references/uninstall.md 的清理流程是「删 services/<svc>.* 然后 handoff」。
# 如果 handoff 不重建 manifest，清单里会留下一个已经不存在的服务，
# 下一个 agent 会把幻影服务当真。
"$STATE" record ghost installed "managed:$WORK/res/managed.conf" >/dev/null
grep -q '"service": "ghost"' "$HAO_STATE_DIR/manifest.json" \
    && note "manifest 含新记录的服务" || bad "manifest 缺新记录的服务"
rm -f "$HAO_STATE_DIR/services/ghost.json" "$HAO_STATE_DIR/services/ghost.resources"
"$STATE" handoff --user "$(id -un)" --skip-agent-files >/dev/null
grep -q '"service": "ghost"' "$HAO_STATE_DIR/manifest.json" \
    && bad "handoff 未重建 manifest，已删服务仍留在清单里" \
    || note "handoff 重建 manifest，已删服务不再出现"
grep -q '"service": "nginx"' "$HAO_STATE_DIR/manifest.json" \
    && note "重建后仍在的服务未被误删" || bad "重建 manifest 弄丢了仍在的服务"
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$HAO_STATE_DIR/manifest.json" \
    && note "重建后的 manifest 仍是合法 JSON" || bad "重建后的 manifest 不是合法 JSON"

# ---------- 多实例服务 ID 互不覆盖 ----------
# site 模块一台机器可以部署多个站点。service ID 带实例标识时两条记录必须共存；
# 都记成 site 会让先部署的那个静默从状态里消失（drift 从此不检查它）。
echo "blog conf" > "$WORK/res/site-blog.conf"
echo "shop conf" > "$WORK/res/site-shop.conf"
"$STATE" record site-blog installed "managed:$WORK/res/site-blog.conf" >/dev/null
"$STATE" record site-shop installed "managed:$WORK/res/site-shop.conf" >/dev/null
if grep -qF "$WORK/res/site-blog.conf" "$HAO_STATE_DIR/services/site-blog.resources" \
    && grep -qF "$WORK/res/site-shop.conf" "$HAO_STATE_DIR/services/site-shop.resources"; then
    note "多实例 service ID 的记录共存"
else
    bad "多实例 service ID 的记录互相覆盖"
fi
[ "$("$STATE" services | grep -c '^site-')" -eq 2 ] \
    && note "services 同时列出两个站点" || bad "services 未同时列出两个站点"
# 同一个 service ID 记第二次仍必须是整体替换（这是 record 的既有语义）
"$STATE" record site-blog installed "managed:$WORK/res/site-shop.conf" >/dev/null
grep -qF "$WORK/res/site-blog.conf" "$HAO_STATE_DIR/services/site-blog.resources" \
    && bad "同一 service ID 重记未整体替换" || note "同一 service ID 重记是整体替换"

# ---------- intent（部署意图） ----------
# 意图是机器销毁后唯一还有用的东西，而且它是 0644、要交给用户带走的，
# 所以「不含密钥」必须由脚本强制，不能靠 agent 自觉。
"$STATE" intent site-blog \
    type=static \
    repo='https://alice:ghp_tok3nvalue@github.com/me/blog.git' \
    branch=main \
    build_cmd='npm ci && npm run build' \
    domain= >/dev/null

INTENT_DOC="$HAO_STATE_DIR/DEPLOY-INTENT.md"
[ -f "$INTENT_DOC" ] && note "DEPLOY-INTENT.md 已生成" || bad "DEPLOY-INTENT.md 缺失"
grep -q 'site-blog' "$INTENT_DOC" && note "意图文档含服务段" || bad "意图文档缺服务段"
grep -q 'npm ci && npm run build' "$INTENT_DOC" \
    && note "意图文档保留了构建命令原文" || bad "意图文档丢了构建命令"

# 内嵌凭据必须脱敏，落盘和文档两处都不能有原值
grep -q 'ghp_tok3nvalue' "$INTENT_DOC" \
    && bad "意图文档泄漏了仓库地址里的 token" || note "意图文档已脱敏内嵌凭据"
grep -q 'ghp_tok3nvalue' "$HAO_STATE_DIR/services/site-blog.intent" \
    && bad "意图落盘文件泄漏了 token" || note "意图落盘文件已脱敏"
grep -q 'https://\*\*\*@github.com/me/blog.git' "$INTENT_DOC" \
    && note "脱敏后仍保留了可辨认的仓库地址" || bad "脱敏把仓库地址弄没了"

# 凭据类 key 必须被拒绝
for badkey in admin_password api_token session_secret my_apikey db_credential; do
    if "$STATE" intent site-blog "$badkey=x" >/dev/null 2>&1; then
        bad "未拒绝凭据类 key: $badkey"
    else
        note "拒绝凭据类 key: $badkey"
    fi
done
# 被拒绝时不能破坏已有意图
grep -q 'type' "$HAO_STATE_DIR/services/site-blog.intent" \
    && note "拒绝后原有意图未被破坏" || bad "拒绝时破坏了原有意图文件"

if "$STATE" intent site-blog Type=static >/dev/null 2>&1; then
    bad "未拒绝大写 key"
else
    note "拒绝非法 key 名"
fi
if "$STATE" intent site-blog nokeyvalue >/dev/null 2>&1; then
    bad "未拒绝缺少 = 的条目"
else
    note "拒绝格式错误的条目"
fi
if "$STATE" intent BadService type=x >/dev/null 2>&1; then
    bad "未拒绝非法 service ID"
else
    note "intent 拒绝非法 service ID"
fi

# 多服务共存 + handoff / 卸载生命周期
"$STATE" intent site-shop type=node domain=shop.example.com >/dev/null
[ "$(grep -c '^## ' "$INTENT_DOC")" -eq 2 ] \
    && note "意图文档同时列出两个服务" || bad "意图文档未同时列出两个服务"
rm -f "$HAO_STATE_DIR/services/site-shop.intent"
"$STATE" handoff --user "$(id -un)" --skip-agent-files >/dev/null
[ "$(grep -c '^## ' "$INTENT_DOC")" -eq 1 ] \
    && note "handoff 重建意图文档，已删服务不再出现" || bad "handoff 未重建意图文档"
grep -q 'DEPLOY-INTENT' "$HANDOFF" \
    && note "HANDOFF.md 指向意图文档" || bad "HANDOFF.md 未指向意图文档"

# ---------- convention ----------
CONV_FILE="$WORK/conv-AGENTS.md"
printf '# 已有\n\n保留这行。\n' > "$CONV_FILE"
printf '## 测试约定\n\n内容 A。\n' \
    | "$STATE" convention HAO-TEST --user "$(id -un)" --agent-file "$CONV_FILE" >/dev/null
grep -q "内容 A" "$CONV_FILE" && note "convention 写入约定正文" || bad "convention 未写入正文"
grep -q "保留这行" "$CONV_FILE" && note "convention 保留用户内容" || bad "convention 吞掉用户内容"

printf '## 测试约定\n\n内容 B。\n' \
    | "$STATE" convention HAO-TEST --user "$(id -un)" --agent-file "$CONV_FILE" >/dev/null
[ "$(grep -c 'HAO-TEST BEGIN' "$CONV_FILE")" -eq 1 ] \
    && note "convention 重跑原地替换" || bad "convention 重跑追加了重复块"
grep -q "内容 B" "$CONV_FILE" && note "convention 内容已更新" || bad "convention 内容未更新"
grep -q "内容 A" "$CONV_FILE" && bad "convention 旧内容残留" || note "convention 旧内容已清除"

# 不同 marker 互不覆盖
printf '## 另一个约定\n' \
    | "$STATE" convention HAO-OTHER --user "$(id -un)" --agent-file "$CONV_FILE" >/dev/null
[ "$(grep -c 'HAO-TEST BEGIN' "$CONV_FILE")" -eq 1 ] && grep -q 'HAO-OTHER BEGIN' "$CONV_FILE" \
    && note "不同 marker 的约定块共存" || bad "不同 marker 互相覆盖"

if "$STATE" convention lowercase-marker --agent-file "$CONV_FILE" </dev/null >/dev/null 2>&1; then
    bad "未拒绝非法 marker"
else
    note "拒绝非法 marker"
fi

# ---------- amend：只改 result，不能弄丢资源 ----------
# 存量记录里出现过更早版本写下的非法 result（例如 "success"）。修它过去只能把全部
# 资源重新列一遍 record，少列一个就静默丢掉一个资源 —— 而这个操作恰好最常发生在
# 接手旧机器的时候，那时资源清单是唯一的事实来源。
"$STATE" record amendsvc installed managed:"$WORK/res/site-blog.conf" observed:"$WORK/res" >/dev/null
sed -i 's/"result": "installed"/"result": "success"/' "$HAO_STATE_DIR/services/amendsvc.json"

svc_out="$("$STATE" services)"
printf '%s' "$svc_out" | grep -q '记录异常' \
    && note "services 点出了非法的 result" || bad "services 没有发现非法的 result"
printf '%s' "$svc_out" | grep -q 'amend amendsvc --result' \
    && note "services 给出了修正命令" || bad "services 没给出修正办法"

before_res="$(cat "$HAO_STATE_DIR/services/amendsvc.resources")"
"$STATE" amend amendsvc --result updated >/dev/null
python3 - "$HAO_STATE_DIR/services/amendsvc.json" <<'PY' || fail=1
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["result"] == "updated", f'result 没改成 updated: {d["result"]}'
assert len(d["resources"]) == 2, f'amend 弄丢了资源: {d["resources"]}'
print("ok   amend 改了 result 且资源数不变")
PY
[ "$(cat "$HAO_STATE_DIR/services/amendsvc.resources")" = "$before_res" ] \
    && note "amend 没有动 .resources 文件" || bad "amend 改写了 .resources"
"$STATE" services | grep -q '记录异常' \
    && bad "amend 之后仍报记录异常" || note "amend 之后记录异常消失"

for bad_case in "amend amendsvc --result bogus" "amend nosuchsvc --result installed" "amend amendsvc"; do
    # shellcheck disable=SC2086  # 有意做词分割：这里就是要把一整条命令行拆成参数
    if "$STATE" $bad_case >/dev/null 2>&1; then
        bad "amend 未拒绝: $bad_case"
    else
        note "amend 拒绝: $bad_case"
    fi
done

# ---------- orphans：带归属头却没被记录的文件 ----------
# 漏跑一次 record 的后果是静默的：文件在主机上、归属头也在，但 drift 不看它、
# manifest 里没有它、卸载也不会带走它。归属头正是反查这类漏记的钩子。
ORPH="$WORK/orph"
mkdir -p "$ORPH/sub"
printf '# Managed by HAO\n# Service: amendsvc\nx=1\n' > "$ORPH/tracked.conf"
printf '# Managed by HAO\n# Service: ghostsvc\ny=2\n' > "$ORPH/sub/untracked.conf"
printf '# Managed by HAO\n# Service: amendsvc\nz=3\n' > "$ORPH/sub/old.conf.bak.20260101_000000"
printf 'not ours at all\n' > "$ORPH/sub/foreign.conf"
"$STATE" record amendsvc updated managed:"$ORPH/tracked.conf" >/dev/null

orph_out="$("$STATE" orphans "$ORPH")"
printf '%s' "$orph_out" | grep -qF "$ORPH/sub/untracked.conf" \
    && note "orphans 找出了没被记录的 HAO 文件" || bad "orphans 漏了没被记录的文件"
printf '%s' "$orph_out" | grep -qF "$ORPH/tracked.conf" \
    && bad "orphans 把已记录的文件也列了出来" || note "orphans 不列已记录的文件"
printf '%s' "$orph_out" | grep -qF "$ORPH/sub/foreign.conf" \
    && bad "orphans 列了不带归属头的文件" || note "orphans 只看带归属头的文件"
printf '%s' "$orph_out" | grep -q '备份/停用件' \
    && note "orphans 把 .bak 标注成可清理" || bad "orphans 没有标注备份件"

"$STATE" record amendsvc updated managed:"$ORPH/tracked.conf" \
    managed:"$ORPH/sub/untracked.conf" managed:"$ORPH/sub/old.conf.bak.20260101_000000" >/dev/null
"$STATE" orphans "$ORPH" | grep -q '（无' \
    && note "全部补记之后 orphans 为空" || bad "补记之后 orphans 仍有输出"

# 记录条数多的时候也必须准。
# 回归测试：orphans 曾经用 `printf '%s\n' "$recorded" | grep -qxF "$f"` 做比对。
# grep -q 一命中就立刻退出，左边的 printf 还在写就收到 EPIPE，而 set -o pipefail
# 会把整条管道判为失败 —— 判断结果被反转，**已经记录过的文件被报成"没记录"**。
# 它只在 recorded 列表大于一个 stdio 缓冲区时才发作：几条路径永远看不到，
# 一台装了十几个服务的真机（每个服务十来个资源）就够了。所以这里故意堆到 ~25 KB。
# 数字选 300 是因为它在旧写法下稳定复现（实测误报十几条），而新写法是纯 bash
# 匹配、不起子进程、没有管道，恒定为 0。
MANY="$WORK/many"
mkdir -p "$MANY"
many_args=()
for i in $(seq 1 300); do
    f="$MANY/long-enough-name-to-push-the-recorded-list-past-one-stdio-buffer-$i.conf"
    printf '# Managed by HAO\n# Service: manysvc\nn=%s\n' "$i" > "$f"
    many_args+=("managed:$f")
done
"$STATE" record manysvc installed "${many_args[@]}" >/dev/null
many_out="$("$STATE" orphans "$MANY")"
many_false="$(printf '%s' "$many_out" | grep -c "^  $MANY/" || true)"
if [ "$many_false" -eq 0 ]; then
    note "记录条数多时 orphans 仍然准（不受 EPIPE / pipefail 影响）"
else
    bad "orphans 把 $many_false 个已记录的文件误报成 orphan（EPIPE 回归）"
fi

# ---------- orphans 默认清单：限深 vs 无限递归 ----------
# 默认清单允许写 <目录>:<深度>，以控制大目录树的扫描开销。
# 验证限深扫描的边界，以及不带深度的清单项和显式目录的完整递归行为。
TREE="$WORK/tree"
mkdir -p "$TREE/a/b/c"
printf '# Managed by HAO\n# Service: deepsvc\n' > "$TREE/shallow.conf"
printf '# Managed by HAO\n# Service: deepsvc\n' > "$TREE/a/b/c/deep.conf"

deep_out="$(HAO_ORPHAN_DIRS_DEFAULT="$TREE:2" "$STATE" orphans)"
case "$deep_out" in
    *"$TREE/shallow.conf"*) note "限深清单扫到了浅层文件" ;;
    *) bad "限深清单漏了浅层文件" ;;
esac
case "$deep_out" in
    *"$TREE/a/b/c/deep.conf"*) bad "限深清单扫到了深度之外的文件" ;;
    *) note "限深清单遵守深度上限" ;;
esac

wide_out="$(HAO_ORPHAN_DIRS_DEFAULT="$TREE" "$STATE" orphans)"
case "$wide_out" in
    *"$TREE/a/b/c/deep.conf"*) note "不带深度的清单项无限递归" ;;
    *) bad "不带深度的清单项没有递归到底" ;;
esac

explicit_out="$("$STATE" orphans "$TREE")"
case "$explicit_out" in
    *"$TREE/a/b/c/deep.conf"*) note "显式传目录时无限递归" ;;
    *) bad "显式传目录未递归到底" ;;
esac

if HAO_ORPHAN_DIRS_DEFAULT="$TREE:abc" "$STATE" orphans >/dev/null 2>&1; then
    bad "未拒绝非法的扫描深度"
else
    note "拒绝非法的扫描深度"
fi

# ---------- remove：删记录前先确认资源真的没了 ----------
# 卸载流程过去是手工 `rm -f services/<svc>.*`。而"服务还在、记录先没了"会让下一个
# agent 把主机上那些文件当成无主资源，要么拒绝操作、要么在重建时覆盖掉。
echo "still here" > "$WORK/res/rm-live.conf"
"$STATE" record rmsvc installed "managed:$WORK/res/rm-live.conf" >/dev/null
if "$STATE" remove rmsvc >/dev/null 2>&1; then
    bad "remove 在资源仍在主机上时没有拒绝"
else
    note "remove 拒绝删除资源仍在主机上的记录"
fi
[ -f "$HAO_STATE_DIR/services/rmsvc.json" ] \
    && note "被拒绝时记录未被删除" || bad "被拒绝时记录已丢失"

"$STATE" remove rmsvc --force >/dev/null \
    && note "remove --force 可显式放弃归属" || bad "remove --force 失败"
[ ! -f "$HAO_STATE_DIR/services/rmsvc.json" ] \
    && note "remove 删掉了记录文件" || bad "remove 未删掉记录文件"
grep -q '"service": "rmsvc"' "$HAO_STATE_DIR/manifest.json" \
    && bad "remove 未重建 manifest（幻影服务还在清单里）" || note "remove 重建了 manifest"

echo "gone soon" > "$WORK/res/rm-gone.conf"
"$STATE" record rmsvc2 installed "managed:$WORK/res/rm-gone.conf" >/dev/null
"$STATE" intent rmsvc2 type=static >/dev/null
rm -f "$WORK/res/rm-gone.conf"
"$STATE" remove rmsvc2 >/dev/null && note "资源已删时 remove 正常执行" || bad "remove 执行失败"
[ ! -f "$HAO_STATE_DIR/services/rmsvc2.json" ] && [ ! -f "$HAO_STATE_DIR/services/rmsvc2.resources" ] \
    && [ ! -f "$HAO_STATE_DIR/services/rmsvc2.intent" ] \
    && note "remove 连 .resources 与 .intent 一起删" || bad "remove 漏了记录文件"

if "$STATE" remove nosuchsvc >/dev/null 2>&1; then
    bad "remove 未拒绝不存在的服务"
else
    note "remove 拒绝不存在的服务"
fi

[ "$fail" -eq 0 ] || { echo "hao-state 测试失败" >&2; exit 1; }
echo "hao-state 测试通过"
