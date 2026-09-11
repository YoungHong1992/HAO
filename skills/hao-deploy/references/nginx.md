# nginx —— 检查与安装过程

安装来源是 nginx.org 官方仓库（不是发行版自带包），因为需要 HTTP/3 与较新的
稳定版本。所有配置文件模板在 `templates/`，不要凭记忆手写配置内容。

## 1. 前置检查（只读，先全部做完再动手）

```bash
"$SKILL/scripts/hao-guard.sh" os-supported          # 期望 "<id> <version> supported"
"$SKILL/scripts/hao-guard.sh" managed-file /etc/nginx/nginx.conf
"$SKILL/scripts/hao-guard.sh" port-free 80
"$SKILL/scripts/hao-guard.sh" port-free 443
ss -tlnp | grep -E ':(80|443)\s' || true            # busy 时靠这条看清占用者是谁
command -v nginx >/dev/null && nginx -v 2>&1        # 是否已装
systemctl is-active nginx 2>/dev/null || true       # 是否在跑
```

判断规则：

- `os-supported` 的输出是三段（`ubuntu 24.04 supported`），不是单词。判断要匹配
  结尾：`case "$(...)" in *" supported") ;; *) 停下 ;; esac`。返回 unsupported
  就停下来告诉用户。支持的是 Debian 13/12 与 Ubuntu 26.04/24.04/22.04 LTS。
- **已装且健康**（`nginx -t` 通过且服务 active）：**跳过第 3 节的安装**。主配置
  **默认不重写**：第 4 节里除了「写主配置」那一小步之外全都照做（建目录、写三个
  共享片段、装证书续期钩子），然后去 `references/site.md` 加站点。
  用户问起或明确要求重写主配置时，先把第 4 节「重写主配置要先讲清的代价」那段
  念给他听，得到确认再动手。
- `managed-file /etc/nginx/nginx.conf` 返回 `foreign`：这份主配置不是 HAO 写的。
  覆盖会丢掉别人的配置，必须先备份并取得用户确认。
- 80/443 `busy` 时用上面那条 `ss -tlnp` 看占用者（`port-free` 只回答 free/busy/unknown，
  说不出是谁）。不是 nginx 就停下来问用户，不要杀进程。
- `port-free` 返回 **`unknown`** 表示这台机器上既没有 `ss` 也没有 `netstat`，
  **查不了**——它不等于 `free`。先 `apt-get install -y iproute2` 再重新检查，
  不要当成空闲继续往下装。

## 2. 系统调优（可独立于 Nginx 安装先做）

这两个文件都是独立 drop-in，不要去改系统主配置文件：

| 模板 | 目标路径 | 写入后 |
|---|---|---|
| `templates/nginx-sysctl-optimize.conf` | `/etc/sysctl.d/99-hao-nginx.conf` | `sysctl -p /etc/sysctl.d/99-hao-nginx.conf` |
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

### 先处理包自带的 default.conf

nginx.org 的包会装一个 `/etc/nginx/conf.d/default.conf`（`server_name localhost`
的欢迎页，docroot 是 `/usr/share/nginx/html`）。**它必须处理掉**，否则：

- `conf.d/*.conf` 按文件名排序 include，`default.conf` 往往排在站点 vhost 前面，
  于是它成了 `:80` 的 default server；
- 「无域名的默认站点」（`server_name _`）只能靠 default server 收流量，被它抢走
  就等于**站点是死的**；
- 而 `curl http://127.0.0.1/` 会拿到欢迎页的 **200** —— 验证步骤看起来通过了，
  这是最坏的一种失败。

改名而不是删除（可逆，且 nginx 只 include `*.conf`）：

```bash
DEF=/etc/nginx/conf.d/default.conf
if [ -f "$DEF" ]; then
    # 用户改过它就不要动：那是他的配置，报路径让他决定
    if grep -qE 'server_name[[:space:]]+localhost;' "$DEF" \
        && ! grep -q 'Managed by HAO' "$DEF"; then
        mv "$DEF" "$DEF.disabled"
        echo "已停用包自带的欢迎页 vhost（改名为 $DEF.disabled，随时可改回来）"
    else
        echo "$DEF 不是包自带的原版，停下来把它的内容报给用户，由他决定"
    fi
fi
```

## 4. 目录与共享片段

```bash
mkdir -p /etc/nginx/snippets /var/log/nginx /var/www/html
chown root:root /etc/nginx/snippets /var/log/nginx
chmod 755 /etc/nginx/snippets /var/log/nginx /var/www/html

mkdir -p /var/cache/nginx/{client_temp,proxy_temp,fastcgi_temp,uwsgi_temp,scgi_temp}
chown -R nginx:nginx /var/cache/nginx
```

`/etc/nginx/snippets/` 是 Debian nginx 的目录约定，nginx.org 的包不建它，要自己建。
共享片段和每站点内容块都放这里——**运维人员会去这个目录找**。

`/var/www/html` 用作 certbot 的 ACME webroot（见 `references/site.md` 第 4 节）。
它是 **Debian 系的 docroot 惯例**，也是 `certbot --webroot` 最常见的位置；
nginx.org 包自己的默认 docroot 其实是 `/usr/share/nginx/html`，两者不是一回事，
所以上面那行 `mkdir -p /var/www/html` 不能省。

证书目录**不由 HAO 创建**：真实证书归 certbot 管（`/etc/letsencrypt/`，它自己会建
并设好权限），自签名兜底走 Debian 标准的 `/etc/ssl/certs` + `/etc/ssl/private`。
HAO 不再有自己的 `/etc/nginx/ssl`。

三个共享片段**总是写**（被各站点 `include`，只写一份）：

- `templates/nginx-ssl-hardening.conf` → `/etc/nginx/snippets/ssl-hardening.conf`
- `templates/nginx-acme-location.conf` → `/etc/nginx/snippets/acme-challenge.conf`
- `templates/nginx-redirect-https.conf` → `/etc/nginx/snippets/redirect-to-https.conf`

第三个是 80→443 的跳转块。它是共享片段而不是站点私有内容，这样站点的 vhost 里
那个"跳不跳转"的选择就是**一行 include 的有无**，而不是往模板里塞一段多行配置
（占位符的值必须是单行，理由见 `templates/site-vhost-tls.conf` 的头部注释）。
什么时候才 include 它，见 `references/site.md` 的「522 教训」。

`ssl-hardening.conf` 是 **TLS 配置的唯一权威处**：协议、套件、会话、HSTS 都在里面。
**不要**让站点 vhost 去 include `/etc/letsencrypt/options-ssl-nginx.conf`，也不要加
`ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem`。那两个文件是
`python3-certbot-nginx` 插件的产物（`dpkg -S options-ssl-nginx.conf` 一查就知道），
而本 skill 只装 `certbot` 并用 `certonly`——它们在这样的机器上**永远不会出现**，
include 一个不存在的文件会让 `nginx -t` 失败，而且失败发生在证书**签发成功之后**，
现象和原因看起来毫不相关。所有 TLS 参数都在 `ssl-hardening.conf` 里
（内容取自 Mozilla intermediate，去掉了 DHE 套件，所以也不需要 dhparam）。

### 主配置：只在这台机器上还没有可用主配置、或用户明确要求时才写

```bash
[ -f /etc/nginx/nginx.conf ] && cp -a /etc/nginx/nginx.conf \
    "/etc/nginx/nginx.conf.bak.$(date +%Y%m%d_%H%M%S)"
```

然后 `templates/nginx.conf` → `/etc/nginx/nginx.conf`。

**重写主配置要先讲清的代价**：`templates/nginx.conf` 只
`include /etc/nginx/conf.d/*.conf;`，**没有** `include /etc/nginx/sites-enabled/*`。
发行版 nginx 的站点都挂在 `sites-enabled/` 下，所以覆盖主配置会让那些站点
**当场全部下线**，而且 `nginx -t` 照样通过、日志里一句话都没有。动手前先看一眼：

```bash
ls -l /etc/nginx/sites-enabled/ 2>/dev/null
```

里面有东西就**停下来**，把清单念给用户，三条路让他选：

1. 不重写主配置（默认，也是绝大多数情况的正确选择）——站点照旧，HAO 只加自己的
   vhost 到 `conf.d/`；
2. 重写，并在写完后手工把 `include /etc/nginx/sites-enabled/*;` 加回 `http` 块——
   注意加回来之后 `drift` 会报这个文件被改过（那是对的，如实解释）；
3. 重写，并由用户确认那些旧站点可以下线。

### certbot 续期后重载 Nginx 的钩子

装在这里而不是 site 模块：它对**所有**证书生效，和某一个站点无关。
逐字安装，无占位符：

```bash
install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
install -m 0755 "$SKILL/templates/certbot-deploy-hook.sh.tmpl" \
    /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
```

放这个目录而不是用 `--deploy-hook`：任何运维都能在这里找到它，也不用在每个域名的
签发命令里重复一遍。`certbot` 还没装也可以先放——目录不存在时上面的 `install -d`
会建好，certbot 装上后自动生效。

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

# nginx.conf 的归属分两种情况填，不要一律 managed：
#   这次真的由 HAO 写了主配置        -> managed:/etc/nginx/nginx.conf
#   第 1 节判断为已就绪/foreign 而跳过 -> observed:/etc/nginx/nginx.conf
# 记错的后果很具体：把别人的主配置记成 managed，下一个 agent 会理所当然地重写它
# （见 references/handoff.md 的归属类别）。
"$SKILL/scripts/hao-state.sh" record nginx installed \
    managed:/etc/nginx/nginx.conf \
    managed:/etc/nginx/snippets/ssl-hardening.conf \
    managed:/etc/nginx/snippets/acme-challenge.conf \
    managed:/etc/nginx/snippets/redirect-to-https.conf \
    managed:/etc/sysctl.d/99-hao-nginx.conf \
    managed:/etc/security/limits.d/90-hao-nofile.conf \
    managed:/etc/systemd/system/nginx.service.d/limits.conf \
    managed:/etc/apt/sources.list.d/nginx.list \
    managed:/etc/apt/preferences.d/99nginx \
    managed:/usr/share/keyrings/nginx-archive-keyring.gpg \
    managed:/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh \
    observed:/etc/nginx/conf.d
"$SKILL/scripts/hao-state.sh" intent nginx \
    source=nginx.org branch=stable http3="$(nginx -V 2>&1 | grep -q http_v3_module && echo yes || echo no)"
"$SKILL/scripts/hao-state.sh" handoff
```

#### 机器上原来就有 nginx（不是本 skill 装的）

上面那串 `record` 是**HAO 装了 nginx 之后**的形态，别照抄到别人的机器上：把那一串
都记成 `managed`，等于告诉下一个 agent"apt 源、sysctl、keyring、续期钩子都是 HAO 的"，
它就会理所当然地去重写它们。

只记**这次真的写了**的文件，其余按其真实归属记：

```bash
"$SKILL/scripts/hao-state.sh" record nginx installed \
    managed:/etc/nginx/snippets/ssl-hardening.conf \
    managed:/etc/nginx/snippets/acme-challenge.conf \
    managed:/etc/nginx/snippets/redirect-to-https.conf \
    observed:/etc/nginx/nginx.conf \
    observed:/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
```

- 主配置是发行版或别人写的 → `observed`（第 1 节判断为"已就绪/foreign 而跳过"时就是
  这种情况）。
- 「只改了其中几个键」的文件（`daemon.json`、`.gitconfig`、`/etc/fstab`）→ `shared`，
  见 `references/docker.md` 的同类说明。
- 续期钩子：机器上已经有的话记 `observed`，但**要确认它真的能跑**
  （直接执行 `/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh`，退出码 0 才算通）。
  没有这个钩子，证书续期后 nginx 会继续用旧证书，而这件事要到下次有人看才被发现。
- `intent` 也别写 `source=nginx.org`：那是假的，会变成一条误导下一台机器的重放依据。
  整套 nginx 都不是 HAO 装的机器，只为 HAO 写过的那几个片段记 `intent`（或不记）。

`record` 会静默跳过不存在的路径并打印一行"跳过不存在的路径: …"。那行是**证据**：
钩子或 keyring 出现在里面，说明那一步其实没做成，回去查。

HTTP/3 不可用不是错误，如实汇报即可（stable 分支某些构建不带该模块）。

## 常见问题

- **`apt-get install nginx` 卡住不动**：忘了 `DEBIAN_FRONTEND=noninteractive`。
- **装完 `systemctl start nginx` 报 `unknown user "nginx"`**：跳过了建用户那步。
- **访问服务器 IP 看到 "Welcome to nginx!"**：包自带的
  `/etc/nginx/conf.d/default.conf` 还在，它抢了 `:80` 的 default server。
  按第 3 节末尾把它改名成 `.disabled`（nginx 只 include `*.conf`）。
- **重写主配置之后，机器上原有的站点全都打不开了**：那些站点挂在
  `/etc/nginx/sites-enabled/` 下，而 `templates/nginx.conf` 只 include `conf.d/`。
  `nginx -t` 不会报错。恢复办法：用第 4 节留下的
  `/etc/nginx/nginx.conf.bak.<时间戳>` 覆盖回去、`nginx -t` 通过后 reload；
  或者在 `http` 块里把 `include /etc/nginx/sites-enabled/*;` 加回来。
- **配置改了没生效**：`systemctl reload nginx` 只在 `nginx -t` 通过时才有意义，
  先测试再重载。
- **`nginx -t` 报 conf.d 里某个文件出错**：那是站点配置的问题，不要去改主配置，
  按 `references/site.md` 排查对应站点。
- **`nginx -t` 报找不到 `/etc/letsencrypt/options-ssl-nginx.conf`**：某个 vhost 里
  还留着那行 include（旧模板的遗留）。那个文件由 `python3-certbot-nginx` 提供，
  本 skill 不装它，所以文件永远不会出现。删掉那行（以及 `ssl_dhparam
  /etc/letsencrypt/ssl-dhparams.pem`），TLS 参数在 `snippets/ssl-hardening.conf` 里。
