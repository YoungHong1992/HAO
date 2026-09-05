#!/usr/bin/env bash
set -euo pipefail

# hao-secret.sh 行为测试
#
# 重点验证三条安全属性：
#   1. 幂等复用 —— 重跑不会换掉已有密钥
#   2. 拒绝命令行字面量 —— argv 对同机任意用户可见
#   3. render 缺 key 时不产出半成品配置

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRET="$ROOT_DIR/skills/hao-deploy/scripts/hao-secret.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v openssl >/dev/null 2>&1 || { echo "skip hao-secret 测试（缺 openssl）"; exit 0; }

fail=0
note() { echo "ok   $1"; }
bad()  { echo "FAIL $1" >&2; fail=1; }

CRED="$WORK/creds.env"

# ---------- 生成 ----------
"$SECRET" write "$CRED" DB_PASSWORD=@password SESSION_SECRET=@session:64 API_KEY=@apikey >/dev/null
[ -f "$CRED" ] || bad "凭据文件未生成"

perm="$(stat -c '%a' "$CRED")"
[ "$perm" = "600" ] && note "凭据文件权限 0600" || bad "凭据文件权限应为 600，实际 $perm"

# 值不得出现在 stdout
out="$("$SECRET" write "$CRED" DB_PASSWORD=@password 2>&1)"
value="$(sed -n 's/^DB_PASSWORD=//p' "$CRED")"
if printf '%s' "$out" | grep -qF "$value"; then
    bad "stdout 泄漏了密钥值"
else
    note "stdout 不含密钥值"
fi

# 长度符合请求
sess="$(sed -n 's/^SESSION_SECRET=//p' "$CRED")"
[ "${#sess}" -eq 64 ] && note "session 长度符合请求 (64)" || bad "session 长度应为 64，实际 ${#sess}"

# API key 前缀
apikey="$(sed -n 's/^API_KEY=//p' "$CRED")"
case "$apikey" in
    sk-*) note "API key 带默认前缀" ;;
    *) bad "API key 缺少 sk- 前缀" ;;
esac

# 生成值必须是纯字母数字（要能安全放进数据库 DSN）
if printf '%s' "$value" | grep -qE '^[a-zA-Z0-9]+$'; then
    note "生成的密码是纯字母数字（DSN 安全）"
else
    bad "生成的密码含非字母数字字符，放进 DSN 会出错"
fi

# ---------- 幂等 ----------
before="$(sha256sum "$CRED" | awk '{print $1}')"
"$SECRET" write "$CRED" DB_PASSWORD=@password SESSION_SECRET=@session:64 API_KEY=@apikey >/dev/null
after="$(sha256sum "$CRED" | awk '{print $1}')"
[ "$before" = "$after" ] && note "重跑复用已有密钥（幂等）" || bad "重跑改写了已有密钥"

# ---------- 显式轮换 ----------
"$SECRET" write "$CRED" DB_PASSWORD=@password SESSION_SECRET=@session:64 API_KEY=@apikey \
    --rotate DB_PASSWORD >/dev/null
rotated="$(sed -n 's/^DB_PASSWORD=//p' "$CRED")"
[ "$rotated" != "$value" ] && note "--rotate 轮换了指定 key" || bad "--rotate 未生效"
# 未指定的 key 不能被轮换
[ "$(sed -n 's/^SESSION_SECRET=//p' "$CRED")" = "$sess" ] \
    && note "--rotate 未波及其他 key" || bad "--rotate 误改了其他 key"

# ---------- keys / has ----------
keys="$("$SECRET" keys "$CRED" | tr '\n' ' ')"
case "$keys" in
    *API_KEY*DB_PASSWORD*SESSION_SECRET*) note "keys 列出全部 key 名" ;;
    *) bad "keys 输出不完整: $keys" ;;
esac
"$SECRET" has "$CRED" API_KEY && note "has 命中已存在 key" || bad "has 未命中 API_KEY"
if "$SECRET" has "$CRED" NOT_THERE 2>/dev/null; then
    bad "has 对不存在的 key 返回了成功"
else
    note "has 对不存在的 key 返回失败"
fi

# ---------- 拒绝字面量 ----------
if "$SECRET" write "$WORK/bad.env" PASS=hunter2 >/dev/null 2>&1; then
    bad "未拒绝命令行字面量密钥"
else
    note "拒绝命令行字面量密钥"
fi
[ ! -f "$WORK/bad.env" ] && note "被拒绝时未产出文件" || bad "被拒绝仍写出了文件"

# ---------- 非法 key 名 ----------
if "$SECRET" write "$WORK/bad2.env" lowercase=@password >/dev/null 2>&1; then
    bad "未拒绝小写 key 名"
else
    note "拒绝非法 key 名"
fi

# ---------- @file 来源 ----------
printf 'user-token-value\n' > "$WORK/token.txt"
"$SECRET" write "$WORK/fromfile.env" CC_TOKEN=@file:"$WORK/token.txt" >/dev/null
[ "$(sed -n 's/^CC_TOKEN=//p' "$WORK/fromfile.env")" = "user-token-value" ] \
    && note "@file 读取用户提供的密钥" || bad "@file 读取失败"

if "$SECRET" write "$WORK/f2.env" X=@file:"$WORK/missing.txt" >/dev/null 2>&1; then
    bad "未拒绝不存在的 @file 路径"
else
    note "拒绝不存在的 @file 路径"
fi

# ---------- render ----------
cat > "$WORK/tmpl.yml" <<'EOF'
dsn: "postgresql://root:@@DB_PASSWORD@@@postgres:5432/db"
secret: "@@SESSION_SECRET@@"
EOF
"$SECRET" render "$WORK/tmpl.yml" "$WORK/out.yml" --from "$CRED" --mode 0600 >/dev/null
grep -qF "postgresql://root:${rotated}@postgres:5432/db" "$WORK/out.yml" \
    && note "render 正确注入 DSN（占位符紧邻 @ 也能解析）" || bad "render 注入 DSN 失败"
grep -qF "$sess" "$WORK/out.yml" && note "render 注入第二个 key" || bad "render 漏了第二个 key"
[ "$(stat -c '%a' "$WORK/out.yml")" = "600" ] && note "render 尊重 --mode" || bad "render 权限不对"

render_out="$("$SECRET" render "$WORK/tmpl.yml" "$WORK/out2.yml" --from "$CRED" 2>&1)"
if printf '%s' "$render_out" | grep -qF "$rotated"; then
    bad "render 的 stdout 泄漏了密钥值"
else
    note "render 的 stdout 不含密钥值"
fi

# 缺 key 必须拒绝，且不留半成品
printf 'x: "@@NOT_PRESENT@@"\n' > "$WORK/bad.tmpl"
if "$SECRET" render "$WORK/bad.tmpl" "$WORK/never.yml" --from "$CRED" >/dev/null 2>&1; then
    bad "render 未拒绝缺失的 key"
else
    note "render 拒绝缺失的 key"
fi
[ ! -f "$WORK/never.yml" ] && note "render 被拒绝时未产出半成品" || bad "render 产出了半成品文件"

[ "$fail" -eq 0 ] || { echo "hao-secret 测试失败" >&2; exit 1; }
echo "hao-secret 测试通过"
