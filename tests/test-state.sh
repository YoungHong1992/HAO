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

[ "$fail" -eq 0 ] || { echo "hao-state 测试失败" >&2; exit 1; }
echo "hao-state 测试通过"
