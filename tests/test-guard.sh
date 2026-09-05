#!/usr/bin/env bash
set -euo pipefail

# hao-guard.sh 行为测试（全部只读，可在任意环境运行）

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT_DIR/skills/hao-deploy/scripts/hao-guard.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
check() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "ok   $label"
    else
        echo "FAIL $label: 期望 '$expected'，实际 '$actual'" >&2
        fail=1
    fi
}

# ---------- vhost-owner ----------
mkdir -p "$WORK/confd"
cat > "$WORK/confd/foreign.conf" <<'EOF'
server {
    listen 80;
    server_name legacy.example.com;
}
EOF
cat > "$WORK/confd/hao-site-blog.conf" <<'EOF'
# Managed by HAO
# Service: site
# HAO-SITE: blog
server {
    listen 80;
    server_name blog.example.com;
}
EOF
cat > "$WORK/confd/hao-other.conf" <<'EOF'
# Managed by HAO
# Service: some-other-service
server {
    listen 80;
    server_name api.example.com;
}
EOF

check "vhost-owner 未占用" \
    "free" "$("$GUARD" vhost-owner unused.example.com "$WORK/confd")"
check "vhost-owner 非 HAO 配置占用" \
    "foreign $WORK/confd/foreign.conf" "$("$GUARD" vhost-owner legacy.example.com "$WORK/confd")"
check "vhost-owner HAO site 占用" \
    "hao-site blog $WORK/confd/hao-site-blog.conf" \
    "$("$GUARD" vhost-owner blog.example.com "$WORK/confd")"
check "vhost-owner 其他 HAO 服务占用" \
    "hao some-other-service $WORK/confd/hao-other.conf" \
    "$("$GUARD" vhost-owner api.example.com "$WORK/confd")"
# 子串不得误命中：blog.example 是 blog.example.com 的前缀
check "vhost-owner 子串不误命中" \
    "free" "$("$GUARD" vhost-owner blog.example "$WORK/confd")"
check "vhost-owner conf 目录不存在" \
    "free" "$("$GUARD" vhost-owner any.example.com "$WORK/nope")"

# ---------- managed-file ----------
check "managed-file 不存在" "missing" "$("$GUARD" managed-file "$WORK/nope.conf")"
check "managed-file HAO 管理" "managed site" "$("$GUARD" managed-file "$WORK/confd/hao-site-blog.conf")"
check "managed-file 非 HAO" "foreign" "$("$GUARD" managed-file "$WORK/confd/foreign.conf")"

# ---------- cert-issuer ----------
check "cert-issuer 缺失" "missing" "$("$GUARD" cert-issuer "$WORK/none.pem")"
if command -v openssl >/dev/null 2>&1; then
    openssl req -x509 -nodes -days 3 -newkey rsa:2048 \
        -keyout "$WORK/k.pem" -out "$WORK/self.pem" \
        -subj "/CN=t.example.com" >/dev/null 2>&1
    check "cert-issuer 自签名" "selfsigned" "$("$GUARD" cert-issuer "$WORK/self.pem")"
else
    echo "skip cert-issuer 自签名（缺 openssl）"
fi

# ---------- repo-identity ----------
check "repo-identity 目录不存在" "absent" \
    "$("$GUARD" repo-identity "$WORK/norepo" git@example.com:me/x.git)"
mkdir -p "$WORK/notgit"
check "repo-identity 非 git 目录" "not-git" \
    "$("$GUARD" repo-identity "$WORK/notgit" git@example.com:me/x.git)"
if command -v git >/dev/null 2>&1; then
    git init -q "$WORK/repo"
    git -C "$WORK/repo" remote add origin "https://user:tok3n@example.com/me/x.git"
    check "repo-identity 一致" "ok" \
        "$("$GUARD" repo-identity "$WORK/repo" "https://user:tok3n@example.com/me/x.git")"
    # 不一致时必须脱敏内嵌凭据
    check "repo-identity 不一致且脱敏" \
        "remote-mismatch https://***@example.com/me/x.git" \
        "$("$GUARD" repo-identity "$WORK/repo" git@example.com:other/y.git)"
else
    echo "skip repo-identity git 用例（缺 git）"
fi

# ---------- port-free ----------
check "port-free 空闲端口" "free" "$("$GUARD" port-free 64999)"
port_state="$("$GUARD" port-free 22)"
case "$port_state" in
    free|busy) echo "ok   port-free 返回合法状态 ($port_state)" ;;
    *) echo "FAIL port-free 返回非法状态: $port_state" >&2; fail=1 ;;
esac
if "$GUARD" port-free 99999 >/dev/null 2>&1; then
    echo "FAIL port-free 未拒绝越界端口" >&2
    fail=1
else
    echo "ok   port-free 拒绝越界端口"
fi

# ---------- unit-port ----------
cat > "$WORK/unit.service" <<'EOF'
[Service]
ExecStart=/usr/bin/node server.js 8137
EOF
check "unit-port 读回端口" "8137" "$("$GUARD" unit-port "$WORK/unit.service")"
check "unit-port 单元不存在" "" "$("$GUARD" unit-port "$WORK/nounit.service")"

# ---------- os-supported ----------
printf 'ID=ubuntu\nVERSION_ID="24.04"\n' > "$WORK/os-ok"
check "os-supported 受支持" "ubuntu 24.04 supported" \
    "$(HAO_OS_RELEASE_FILE="$WORK/os-ok" "$GUARD" os-supported)"
printf 'ID=arch\nVERSION_ID="rolling"\n' > "$WORK/os-bad"
check "os-supported 不受支持" "arch rolling unsupported" \
    "$(HAO_OS_RELEASE_FILE="$WORK/os-bad" "$GUARD" os-supported)"

# ---------- 未知子命令 ----------
if "$GUARD" bogus-subcommand >/dev/null 2>&1; then
    echo "FAIL 未知子命令未报错" >&2
    fail=1
else
    echo "ok   未知子命令报错退出"
fi

[ "$fail" -eq 0 ] || { echo "hao-guard 测试失败" >&2; exit 1; }
echo "hao-guard 测试通过"
