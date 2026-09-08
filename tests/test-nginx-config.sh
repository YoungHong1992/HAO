#!/usr/bin/env bash
set -euo pipefail

# 把 nginx 相关的模板渲染成一套完整配置，交给**真的 nginx -t** 检查。
#
# 为什么需要这条：模板里的每一行都是 nginx 语法，而 shellcheck 和结构测试都看不懂
# 它们。历史上真的漏出去过这几类问题，全都只有 nginx -t 能抓：
#   - `http2 on;` 是 nginx 1.25.1 才有的独立指令，老版本上 unknown directive；
#   - include 了一个在目标机上永远不存在的文件（certbot nginx 插件的产物）；
#   - 占位符没替换干净，`@@TOKEN@@` 进了配置。
#
# 不碰主机：所有路径都在临时 prefix 里，只跑 `nginx -t`，不启动任何服务，
# 不需要 root（用 -p/-c 指定 prefix 和配置文件）。
# 没装 nginx 就跳过 —— 本地开发机上不该为跑测试而装一个 nginx。

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPL="$ROOT_DIR/skills/hao-deploy/templates"

if ! command -v nginx >/dev/null 2>&1; then
    echo "== nginx 配置测试跳过：本机没有 nginx ==" >&2
    echo "   要跑这条：apt-get install -y nginx（CI 里已经装了）" >&2
    exit 0
fi

fail=0
note() { echo "  ✓ $1"; }
bad()  { echo "  ✗ $1" >&2; fail=1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

NGINX_VER="$(nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9.]*\).*|\1|p')"
# 和 references/site.md 第 4 节同一个判断：<= 1.25.0 表示没有独立的 http2 指令
if printf '%s\n1.25.0\n' "$NGINX_VER" | sort -V -C; then
    HTTP2=""
    http2_note="（本机 nginx $NGINX_VER 没有 http2 指令，按老版本渲染）"
else
    HTTP2="http2 on;"
    http2_note="（本机 nginx $NGINX_VER 支持 http2 指令）"
fi
echo "== nginx 配置测试 $http2_note =="

# ---------- 临时 prefix ----------
mkdir -p "$WORK"/{conf/conf.d,conf/snippets,logs,www/site,www/html,cache}
DOMAIN="test.example.com"
SITE_ID="testsite"

# 自签一张证书给 TLS vhost 用（nginx -t 会真的去读证书文件）
openssl req -x509 -nodes -days 2 -newkey rsa:2048 \
    -keyout "$WORK/conf/test.key" -out "$WORK/conf/test.pem" \
    -subj "/CN=$DOMAIN" >/dev/null 2>&1

# mime.types 从系统那份借用：模板里 include 的是绝对路径 /etc/nginx/mime.types
MIME_SRC=/etc/nginx/mime.types
[ -f "$MIME_SRC" ] || MIME_SRC=""

render() {   # render <模板> <输出> <KEY=VALUE>...
    local tmpl="$1" out="$2" content
    shift 2
    content="$(cat "$TMPL/$tmpl")"
    local pair key value
    for pair in "$@"; do
        key="${pair%%=*}"
        value="${pair#*=}"
        # 和脚本里一样做纯字面替换，不用 ${//}（替换串里的 & 有特殊语义）
        local out_acc="" rest="$content" needle="@@${key}@@"
        while [ -n "$rest" ]; do
            case "$rest" in
                *"$needle"*)
                    out_acc="${out_acc}${rest%%"$needle"*}${value}"
                    rest="${rest#*"$needle"}"
                    ;;
                *) out_acc="${out_acc}${rest}"; rest="" ;;
            esac
        done
        content="$out_acc"
    done
    printf '%s\n' "$content" > "$out"
    if grep -q '@@[A-Z]' "$out"; then
        bad "$tmpl 渲染后仍有占位符: $(grep -o '@@[A-Z][A-Z0-9_]*@@' "$out" | sort -u | tr '\n' ' ')"
    fi
}

# 共享片段：acme 片段里的 root 指到临时目录
sed "s#/var/www/html#$WORK/www/html#" "$TMPL/nginx-acme-location.conf" \
    > "$WORK/conf/snippets/acme-challenge.conf"
cp "$TMPL/nginx-ssl-hardening.conf" "$WORK/conf/snippets/ssl-hardening.conf"
cp "$TMPL/nginx-redirect-https.conf" "$WORK/conf/snippets/redirect-to-https.conf"

# 站点内容块（static 与 node 各一份，分别挂到两个 server_name 上）
render site-body-static.conf "$WORK/conf/snippets/$DOMAIN.conf" \
    "SITE_ID=$SITE_ID" "CONF_NAME=$DOMAIN" "DOCROOT=$WORK/www/site"
render site-body-node.conf "$WORK/conf/snippets/node.$DOMAIN.conf" \
    "SITE_ID=nodesite" "CONF_NAME=node.$DOMAIN" "PORT=8123"
# 日志路径改到临时目录
sed -i "s#/var/log/nginx#$WORK/logs#g" \
    "$WORK/conf/snippets/$DOMAIN.conf" "$WORK/conf/snippets/node.$DOMAIN.conf"
# 片段和 vhost 里的 include 都要指到临时 snippets 目录 —— **内容块也不例外**。
# body 里的 glob include 是绝对路径（/etc/nginx/snippets/...），不改写的话，
# 在真的部署过 nginx-hardening 的机器上（CI 之外还包括开发机本机），
# 测试会把宿主机的线上配置吸进来 —— "模板正确性"就变成了"宿主机配置正确性"，
# 两个方向都会被污染。
fix_includes() { sed -i "s#/etc/nginx/snippets#$WORK/conf/snippets#g" "$@"; }
fix_includes "$WORK/conf/snippets/$DOMAIN.conf" "$WORK/conf/snippets/node.$DOMAIN.conf"

# ---------- vhost：HTTP 版（无域名默认站点，带 default_server）----------
render site-vhost-http.conf "$WORK/conf/conf.d/$SITE_ID.conf" \
    "SITE_ID=$SITE_ID" "CONF_NAME=$DOMAIN" "SERVER_NAME=_" "DEFAULT= default_server"
sed -i -e "s#listen 80 #listen 8080 #" -e "s#listen \[::\]:80 #listen [::]:8080 #" \
    "$WORK/conf/conf.d/$SITE_ID.conf"
fix_includes "$WORK/conf/conf.d/$SITE_ID.conf"

# ---------- vhost：TLS 版（跳转分支 + 本机 nginx 支持的 HTTP/2 写法）----------
if nginx -V 2>&1 | grep -q http_v3_module; then
    QUIC_LISTEN="listen 8443 quic;"
    ALT_SVC="add_header Alt-Svc 'h3=\":8443\"; ma=86400';"
else
    QUIC_LISTEN=""
    ALT_SVC=""
fi
render site-vhost-tls.conf "$WORK/conf/conf.d/node.$DOMAIN.conf" \
    "SITE_ID=nodesite" "CONF_NAME=node.$DOMAIN" "SERVER_NAME=node.$DOMAIN" \
    "DOMAIN=$DOMAIN" \
    "PORT80_BODY=include /etc/nginx/snippets/redirect-to-https.conf;" \
    "HTTP2=$HTTP2" "QUIC_LISTEN=$QUIC_LISTEN" "ALT_SVC=$ALT_SVC"
# 端口和证书路径换成临时的（80/443 不需要 root 才能 -t，但两份 vhost 不能撞端口）
sed -i \
    -e "s#listen 80;#listen 8081;#" -e "s#listen \[::\]:80;#listen [::]:8081;#" \
    -e "s#listen 443 ssl;#listen 8443 ssl;#" -e "s#listen \[::\]:443 ssl;#listen [::]:8443 ssl;#" \
    -e "s#/etc/letsencrypt/live/$DOMAIN/fullchain.pem#$WORK/conf/test.pem#" \
    -e "s#/etc/letsencrypt/live/$DOMAIN/privkey.pem#$WORK/conf/test.key#" \
    "$WORK/conf/conf.d/node.$DOMAIN.conf"
fix_includes "$WORK/conf/conf.d/node.$DOMAIN.conf"

# ---------- 主配置 ----------
{
    sed -e "s#^user .*#\# user 指令在非 root 的 -t 里没意义，测试里去掉#" \
        -e "s#/var/log/nginx#$WORK/logs#g" \
        -e "s#/run/nginx.pid#$WORK/nginx.pid#" \
        -e "s#/etc/nginx/conf.d#$WORK/conf/conf.d#" \
        "$TMPL/nginx.conf"
} > "$WORK/conf/nginx.conf"
if [ -z "$MIME_SRC" ]; then
    sed -i 's#include *\(/etc/nginx/mime.types\);#\# mime.types 不存在，测试里跳过#' \
        "$WORK/conf/nginx.conf"
fi

# ---------- 真的跑一次 nginx -t ----------
# -e 不可省：nginx 在解析配置**之前**就打开编译进去的默认 error log 路径，
# 非 root 跑会先来一句 permission denied。
if out="$(nginx -t -p "$WORK" -c "$WORK/conf/nginx.conf" -e "$WORK/logs/startup-error.log" 2>&1)"; then
    note "nginx -t 通过（主配置 + 共享片段 + static/node 两份 vhost，未装 hardening，glob 为空操作）"
else
    bad "nginx -t 未通过:"
    printf '%s\n' "$out" >&2
fi

# ---------- hardening 场景：装上 nginx-hardening 三件套，再 -t 一次 ----------
# 上面那次 -t 验证的是"没装 hardening 时，内容块的 glob include 是无害空操作"；
# 这一次验证"装了就自动生效"。文件用模块部署时的真名真位置 ——
# conf.d 里的 00- 前缀必须先于 vhost 解析（zone 定义先于引用），
# 见 templates/nginx-hardening-baseline.conf 的头部说明。
cp "$TMPL/nginx-hardening-baseline.conf" "$WORK/conf/conf.d/00-hao-hardening.conf"
cp "$TMPL/nginx-scanner-blocks.conf" "$WORK/conf/snippets/scanner-blocks.conf"
cp "$TMPL/nginx-security-headers.conf" "$WORK/conf/snippets/security-headers.conf"
if out="$(nginx -t -p "$WORK" -c "$WORK/conf/nginx.conf" -e "$WORK/logs/startup-error.log" 2>&1)"; then
    note "nginx -t 也通过（装上 hardening 三件套，限流/扫站拦截/安全响应头随 glob 生效）"
else
    bad "hardening 场景 nginx -t 未通过:"
    printf '%s\n' "$out" >&2
fi

# ---------- 顺带守住几条内容约定 ----------
# 静态资源那个 location 里不能有 add_header：nginx 的 add_header 不累加，
# 本层出现一个就不再继承 server 层的，HSTS 会在所有静态资源响应上丢失。
if awk '/location ~\* \\\.\(/,/^}/' "$TMPL/site-body-static.conf" | grep -q '^[[:space:]]*add_header'; then
    bad "site-body-static.conf 的静态资源 location 里有 add_header，会吃掉继承来的 HSTS"
else
    note "静态资源 location 没有 add_header（HSTS 能继承下来）"
fi

# 点文件必须被挡掉：产物目录填 "." 时整个仓库都在 docroot 里
grep -q 'location ~ /\\\.' "$TMPL/site-body-static.conf" \
    && note "static 内容块挡掉了点文件（.env / .npmrc 之类）" \
    || bad "static 内容块没有挡点文件，产物目录填 . 时 .env 会被公网下载"

# acme 片段必须用 ^~：否则上面那条点文件正则会把 challenge 抢走并 403
grep -q 'location \^~ /\.well-known/acme-challenge/' "$TMPL/nginx-acme-location.conf" \
    && note "acme 片段用了 ^~（不会被点文件正则抢走）" \
    || bad "acme 片段没用 ^~，会被 location ~ /\\. 抢走，证书续期失败"

[ "$fail" -eq 0 ] || { echo "nginx 配置测试失败" >&2; exit 1; }
echo "nginx 配置测试通过"
