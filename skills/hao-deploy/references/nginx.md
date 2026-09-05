# nginx —— 检查与安装过程

安装来源是 nginx.org 官方仓库（不是发行版自带包），因为需要 HTTP/3 与较新的
稳定版本。所有配置文件模板在 `templates/`，不要凭记忆手写配置内容。

## 1. 前置检查（只读，先全部做完再动手）

```bash
"$SKILL/scripts/hao-guard.sh" os-supported          # 必须 supported
"$SKILL/scripts/hao-guard.sh" managed-file /etc/nginx/nginx.conf
"$SKILL/scripts/hao-guard.sh" port-free 80
"$SKILL/scripts/hao-guard.sh" port-free 443
command -v nginx >/dev/null && nginx -v 2>&1        # 是否已装
systemctl is-active nginx 2>/dev/null || true       # 是否在跑
```

判断规则：

- `os-supported` 返回 unsupported：停下来告诉用户。支持的是 Debian 13/12 与
  Ubuntu 26.04/24.04/22.04 LTS。不要在别的系统上硬装。
- **已装且健康**（`nginx -t` 通过且服务 active）：默认**不要**覆盖
  `/etc/nginx/nginx.conf`。告诉用户 Nginx 已就绪，问清是否真的要重写主配置。
  只有用户明确同意才继续第 3 步；否则跳到第 4 步只加站点配置。
- `managed-file /etc/nginx/nginx.conf` 返回 `foreign`：这份主配置不是 HAO 写的。
  覆盖会丢掉别人的配置，必须先备份并取得用户确认。
- 80/443 被别的进程占用（非 nginx）：停下来问用户，不要杀进程。

## 2. 系统调优（可独立于 Nginx 安装先做）

这两个文件都是独立 drop-in，不要去改系统主配置文件：

| 模板 | 目标路径 | 写入后 |
|---|---|---|
| `templates/nginx-sysctl-optimize.conf` | `/etc/sysctl.d/99-vps-optimize.conf` | `sysctl -p /etc/sysctl.d/99-vps-optimize.conf` |
| `templates/nginx-limits-nofile.conf` | `/etc/security/limits.d/90-hao-nofile.conf` | 无需重载，下次登录生效 |

还有第三个 drop-in（`nginx-systemd-limits.conf`）只在装了 Nginx 之后才有意义，
见第 3 节末尾——`limits.d` 对 systemd 启动的服务不生效。

**BBR 要回读确认**，写进文件不等于生效（内核 < 4.9 会静默失败）：

```bash
sysctl -n net.ipv4.tcp_congestion_control    # 期望输出 bbr
```

不是 `bbr` 就如实告诉用户"BBR 未开启，需要内核 >= 4.9"，不要报告成功。

## 3. 安装 Nginx

```bash
export DEBIAN_FRONTEND=noninteractive     # 必须：否则 dpkg 的 conffile 交互提示会挂住整个流程
apt-get update -y -qq
apt-get install -y -qq curl gnupg2 ca-certificates lsb-release

curl -fsSL --connect-timeout 30 https://nginx.org/keys/nginx_signing.key \
    | gpg --dearmor --yes -o /usr/share/keyrings/nginx-archive-keyring.gpg

. /etc/os-release
# Debian 少数镜像缺 VERSION_CODENAME，需要兜底
[ -n "${VERSION_CODENAME:-}" ] || VERSION_CODENAME="$(lsb_release -cs 2>/dev/null || echo bookworm)"

# 默认用 stable 分支：生产更稳，nginx 1.26+ 一样支持 HTTP/3。
# 确实需要主线特性时才换成 mainline（路径加 "mainline/"）。
printf '# Managed by HAO\n# Service: nginx\ndeb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/%s/ %s nginx\n' \
    "$ID" "$VERSION_CODENAME" > /etc/apt/sources.list.d/nginx.list
```

再把 `templates/nginx-apt-preferences` 写到 `/etc/apt/preferences.d/99nginx`
（让 nginx.org 的包优先，否则以后升级可能被换回发行版旧版），然后：

```bash
apt-get update -y -qq
apt-get install -y -o Dpkg::Options::=--force-confold nginx
```

`--force-confold` 保留机器上已有的配置文件，不要去掉。

### 运行用户与 systemd 限制

nginx.org 的包用 `nginx` 用户，某些镜像里不存在，要先建：

```bash
getent group nginx >/dev/null || groupadd --system nginx
id -u nginx >/dev/null 2>&1 || useradd --system --no-create-home \
    --shell /usr/sbin/nologin --gid nginx nginx
```

`/etc/security/limits.d` **对 systemd 启动的服务不生效**，必须另外写 override：
把 `templates/nginx-systemd-limits.conf` 写到
`/etc/systemd/system/nginx.service.d/limits.conf`，然后 `systemctl daemon-reload`。

## 4. 目录与主配置

```bash
mkdir -p /etc/nginx/ssl /var/log/nginx /var/www/acme
chown root:root /etc/nginx/ssl /var/log/nginx
chmod 755 /etc/nginx/ssl /var/log/nginx /var/www/acme

# 私钥必须 600，证书 644
find /etc/nginx/ssl -type d -exec chmod 755 {} + 2>/dev/null || true
find /etc/nginx/ssl -type f -name 'key.pem' -exec chmod 600 {} + 2>/dev/null || true
find /etc/nginx/ssl -type f -name 'fullchain.pem' -exec chmod 644 {} + 2>/dev/null || true

mkdir -p /var/cache/nginx/{client_temp,proxy_temp,fastcgi_temp,uwsgi_temp,scgi_temp}
chown -R nginx:nginx /var/cache/nginx
```

写主配置前**先备份**：

```bash
[ -f /etc/nginx/nginx.conf ] && cp -a /etc/nginx/nginx.conf \
    "/etc/nginx/nginx.conf.bak.$(date +%Y%m%d_%H%M%S)"
```

然后写三个文件：

- `templates/nginx.conf` → `/etc/nginx/nginx.conf`
- `templates/nginx-ssl-params.conf` → `/etc/nginx/hao-ssl-params.conf`
- `templates/nginx-acme-location.conf` → `/etc/nginx/hao-acme-location.conf`

后两个是共享片段，被各站点 `include`，只写一份。

## 5. 测试与启动（顺序不能反）

```bash
nginx -t                       # 必须先测试
systemctl enable nginx
systemctl restart nginx
```

`nginx -t` 失败：**不要** restart。把 `nginx -t` 的原始输出给用户，从备份恢复
主配置，再确认服务仍是原状。带着坏配置重启会让所有站点一起下线。

## 6. 验证并记录

```bash
nginx -v 2>&1
nginx -V 2>&1 | grep -q http_v3_module && echo "HTTP/3 可用" || echo "HTTP/3 不可用"
systemctl is-active nginx
sysctl -n net.ipv4.tcp_congestion_control

"$SKILL/scripts/hao-state.sh" record nginx installed \
    managed:/etc/nginx/nginx.conf \
    managed:/etc/nginx/hao-ssl-params.conf \
    managed:/etc/nginx/hao-acme-location.conf \
    managed:/etc/sysctl.d/99-vps-optimize.conf \
    managed:/etc/security/limits.d/90-hao-nofile.conf \
    managed:/etc/systemd/system/nginx.service.d/limits.conf \
    managed:/etc/apt/sources.list.d/nginx.list \
    managed:/etc/apt/preferences.d/99nginx \
    observed:/etc/nginx/conf.d
```

HTTP/3 不可用不是错误，如实汇报即可（stable 分支某些构建不带该模块）。

## 常见问题

- **`apt-get install nginx` 卡住不动**：忘了 `DEBIAN_FRONTEND=noninteractive`。
- **装完 `systemctl start nginx` 报 `unknown user "nginx"`**：跳过了建用户那步。
- **配置改了没生效**：`systemctl reload nginx` 只在 `nginx -t` 通过时才有意义，
  先测试再重载。
- **`nginx -t` 报 conf.d 里某个文件出错**：那是站点配置的问题，不要去改主配置，
  按 `references/site.md` 排查对应站点。
