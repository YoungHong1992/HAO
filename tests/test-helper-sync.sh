#!/usr/bin/env bash
# 守护 install.sh 与 lib/ 中重复实现的共享助手不发生分叉（CLAUDE.md 记录的一致性风险）。
# install.sh 为支持单文件自举而复制了 lib 的若干函数；此测试断言两份逐字节一致，
# 并对修复后的 validate_ip 结构校验做行为回归。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT_DIR/install.sh"
fail=0

# 从文件中提取 `name() { ... }`（函数体在第 0 列以 } 收尾）。
extract_fn() {
    local name="$1" file="$2"
    awk -v n="$name" 'index($0, n"() {")==1 {p=1} p{print} p && $0=="}" {exit}' "$file"
}

assert_parity() {
    local name="$1" libfile="$2"
    local a b
    a="$(extract_fn "$name" "$INSTALL")"
    b="$(extract_fn "$name" "$libfile")"
    if [ -z "$a" ]; then echo "FAIL: $name 未在 install.sh 中找到" >&2; fail=1; return; fi
    if [ -z "$b" ]; then echo "FAIL: $name 未在 $(basename "$libfile") 中找到" >&2; fail=1; return; fi
    if [ "$a" != "$b" ]; then
        echo "FAIL: $name 在 install.sh 与 $(basename "$libfile") 之间已分叉：" >&2
        diff <(printf '%s\n' "$b") <(printf '%s\n' "$a") >&2 || true
        fail=1
        return
    fi
    echo "ok parity: $name"
}

# 1) 逐字节一致性：install.sh 复制的助手必须与 lib 权威实现相同
for fn in hao_random_alnum generate_password generate_session_secret generate_api_key; do
    assert_parity "$fn" "$ROOT_DIR/lib/crypto.sh"
done
for fn in is_supported_os_release validate_ip validate_domain check_port_available; do
    assert_parity "$fn" "$ROOT_DIR/lib/common.sh"
done

# 2) 行为回归：source lib 版本，断言 validate_ip 的结构校验正确
# shellcheck source=../lib/common.sh
source "$ROOT_DIR/lib/common.sh"

expect_valid()   { if validate_ip "$1" >/dev/null 2>&1; then echo "ok valid:   $1"; else echo "FAIL: 应接受但被拒: $1" >&2; fail=1; fi; }
expect_invalid() { if validate_ip "$1" >/dev/null 2>&1; then echo "FAIL: 应拒绝但被接受: $1" >&2; fail=1; else echo "ok invalid: $1"; fi; }

expect_valid   "192.168.0.1"
expect_valid   "8.8.8.8"
expect_valid   "::1"
expect_valid   "::"
expect_valid   "2001:db8::1"
expect_valid   "2001:0db8:0000:0000:0000:0000:0000:0001"
expect_invalid "256.0.0.1"
expect_invalid "1.2.3"
expect_invalid ":::"
expect_invalid "1:2:3"
expect_invalid "12345::1"
expect_invalid "not-an-ip"
expect_invalid "2001:db8:::1"

if [ "$fail" -ne 0 ]; then
    echo "helper-sync 测试失败" >&2
    exit 1
fi
echo "helper-sync 测试通过"
