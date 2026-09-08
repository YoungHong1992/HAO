# nginx-hardening —— 站点防护基线（防扫站/限流/安全响应头）

公网机器从站点上线当天就会被自动扫描：`.env`/`.git` 探测、WordPress 路径、
攻击工具 UA、直连源站的高频抓取（真实案例：CF 统计 24h 内 1.71k 请求里
1.34k 是 4xx；单 IP 直连源站一分钟 370 次）。这个模块给装了 nginx 的机器
一层通用基线，全部写进 nginx 自己，不动应用：

```
按真实客户端 IP 还原 → 扫站路径/恶意 UA 拦截(403) → 按真实 IP 限流(429) → 安全响应头
```

把反复扫描的 IP 直接封掉是另一个模块：`fail2ban-nginx`。两者独立安装、
独立记录；封禁 jail 的 403/429 计数靠本模块的拦截产生，没装本模块时 jail
也能靠 404 抓扫描器，只是钝一些。

## 0. 先讲清楚什么防不了（诚实边界）

| 层 | 防什么 | 防不了什么 |
|---|---|---|
| nginx 拦截/限流 | 扫站路径、恶意 UA、单 IP 超频 | 放慢速度的低频爬取；不封 IP |
| fail2ban（另一个模块） | 直连源站的攻击者，socket 级封掉 | **经 Cloudflare 代理的攻击**——真实 IP 不直连源站，封不到 |
| CF 边缘（用户自己配，见附录） | 经 CF 的攻击在到达源站之前拦下 | 需要用户有 CF 账号去后台点；agent 没有凭据不代劳 |

站点在不在 Cloudflare 后面**不改变**本模块写什么文件（CF 网段还原对非 CF
机器是无害的死配置），改变的是验证的解释和要不要做附录那步——所以要问。

## 1. 前置检查（只读）

前提：`nginx` 模块已装且健康（本模块的三个文件都要被 /etc/nginx include）。

```bash
nginx -v 2>&1 && systemctl is-active nginx
"$SKILL/scripts/hao-guard.sh" managed-file /etc/nginx/conf.d/00-hao-hardening.conf
"$SKILL/scripts/hao-guard.sh" managed-file /etc/nginx/snippets/scanner-blocks.conf
"$SKILL/scripts/hao-guard.sh" managed-file /etc/nginx/snippets/security-headers.conf
ls /etc/nginx/conf.d/
```

- `managed-file` 返回 `foreign` → 拒绝覆盖，报给用户。
- 顺手看一眼 conf.d 里有没有**别人的** http 级配置在定义同名东西
  （`limit_req_zone`、`geo`、`map`）：有冲突就停下来问用户，
  两套限流合并不是本模块的事。

问用户两件事，记进 intent：

1. 站点过 Cloudflare 吗？
2. 有没有带管理后台的站点要上 Basic Auth 网关（第 4 节）？

## 2. 写三个文件

| 模板 | 目标路径 |
|---|---|
| `templates/nginx-hardening-baseline.conf` | `/etc/nginx/conf.d/00-hao-hardening.conf` |
| `templates/nginx-scanner-blocks.conf` | `/etc/nginx/snippets/scanner-blocks.conf` |
| `templates/nginx-security-headers.conf` | `/etc/nginx/snippets/security-headers.conf` |

三个模板都**没有占位符**，逐字写入，不要"顺手优化"。两个命名都不是随意的：

- `00-` 前缀保证它在 conf.d 里最先被解析——`limit_req_zone` 必须先于引用
  它的 server 块存在，删掉前缀 nginx -t 会报 zero size shared memory zone。
- `scanner-blocks` / `security-headers` 这两个名字被站点内容块的
  **glob include**（`scanner-blocks*.conf`）引用，改名等于全站断线。

写入用备份-`nginx -t`-失败回滚的完整姿势，见 `references/site.md` 第 4 节
那段（备份不要留在 conf.d/snippets 里）。收尾：

```bash
nginx -t && systemctl reload nginx
```

## 3. 站点怎么接入（装完不等于生效）

拦截/限流/响应头都发生在 **server 级**，靠站点内容块里的两行 glob include：

```
include /etc/nginx/snippets/scanner-blocks*.conf;
include /etc/nginx/snippets/security-headers*.conf;
```

- **本模块装完之后新部署的站点**：自动生效。site 模块的两个 body 模板
  （`site-body-static.conf` / `site-body-node.conf`）已经带了这两行；glob
  无匹配时整行等于不存在，所以 body 模板并不依赖本模块。
- **装之前已经部署的站点**：内容块里没有那两行。把这两行补进该站点的
  `/etc/nginx/snippets/<CONF_NAME>.conf`（**加在现有 location 之前**——正则
  location 按出现顺序取第一个命中，排在前面，扫描 403 才由 scanner-blocks
  记账，fail2ban 才数得到；站点自带的 `location ~ /\. { deny all; }` 不用删，
  它继续兜底），然后 `nginx -t && systemctl reload nginx`。
  改的是该站点自己的 managed 文件——按 `references/handoff.md` 用
  `hao-state.sh ownership site-<ID>` 查出清单原样重跑 record 刷新哈希，
  否则 drift 从此天天报警。

## 4. 可选：后台 Basic Auth 网关

给带管理后台的 Node 站点在应用登录之外加一道门：私密路径 + Basic Auth +
5 r/s 限速。错 8 次/10 分钟就被 `hao-nginx-auth` jail 封 24 小时。

```bash
# 1. 口令落盘（值不进对话）
"$SKILL/scripts/hao-secret.sh" write /etc/hao/hardening.env 'ADMIN_PASS=@password:20'
# 2. 渲染 htpasswd（注释和属组处理的原因写在模板头部，照做）
"$SKILL/scripts/hao-secret.sh" render "$SKILL/templates/nginx-htpasswd.conf" \
    /etc/nginx/.htpasswd-<CONF_NAME> --from /etc/hao/hardening.env --mode 0640
sed -i '/^#/d' /etc/nginx/.htpasswd-<CONF_NAME> && chgrp nginx /etc/nginx/.htpasswd-<CONF_NAME>
```

然后把 `templates/nginx-admin-gateway.conf` 渲染（`@@ADMIN_PATH@@`、
`@@UPSTREAM@@`、`@@CONF_NAME@@`，token 含义见模板头）整段粘贴进该站点的内容
块，`nginx -t` 通过后 reload。这是在改站点的 managed 文件，重跑该站点的
record（同第 3 节）。

私密路径**不要用 `/admin`**——路径本身视同口令的一半，让用户起一个
扫不到的名字；要记进 DEPLOY-INTENT.md 与否，由用户拍板（那份文件 0644
且用户会带走）。

## 5. 验证（真实证据，nginx -t 通过不算数）

```bash
# 扫站路径 → 403
curl -s -o /dev/null -w '%{http_code}\n' -H "Host: $DOMAIN" http://127.0.0.1/.env
# 恶意 UA → 403；TRACE → 405
curl -s -o /dev/null -w '%{http_code}\n' -A sqlmap -H "Host: $DOMAIN" http://127.0.0.1/
curl -s -o /dev/null -w '%{http_code}\n' -X TRACE -H "Host: $DOMAIN" http://127.0.0.1/
# 正常页面 → 200
curl -s -o /dev/null -w '%{http_code}\n' -H "Host: $DOMAIN" http://127.0.0.1/
# ACME 探测 → 404（**不能是 403**，否则下次续期失败）
curl -s -o /dev/null -w '%{http_code}\n' -H "Host: $DOMAIN" \
    http://127.0.0.1/.well-known/acme-challenge/probe
# 安全响应头真的在
curl -sI -H "Host: $DOMAIN" http://127.0.0.1/ | grep -i x-content-type-options
# 403 落在该站点自己的 access_log 里（那一行同时是 fail2ban 的口粮）
tail -n 2 "/var/log/nginx/$CONF_NAME.access.log"
```

ACME 探测若是 403，说明 well-known 例外没生效，停下来修——带着
"下季度证书续期会莫名其妙失败"的状态收尾是不可接受的。

限流不要用本机 curl 轰（127.0.0.1 不触发 realip，还把日志刷脏）。真实 IP
还原的证据：站点在 CF 后面时，让用户浏览器打开一次站点，tail access.log，
`$remote_addr` 应是用户的真实出口 IP 而不是 `104.x/172.x` 这些 CF 网段。

## 6. 记录状态并交接

```bash
"$SKILL/scripts/hao-state.sh" record nginx-hardening installed \
    managed:/etc/nginx/conf.d/00-hao-hardening.conf \
    managed:/etc/nginx/snippets/scanner-blocks.conf \
    managed:/etc/nginx/snippets/security-headers.conf
"$SKILL/scripts/hao-state.sh" intent nginx-hardening behind_cloudflare=yes admin_gateway=no
"$SKILL/scripts/hao-state.sh" handoff
```

上了第 4 节网关的话：htpasswd 是凭据（`secret`，不记哈希），把它
`secret:/etc/nginx/.htpasswd-<CONF_NAME>` 加进 record；网关 location 所在的
那个站点也要重跑 record。

## 7. 不要顺手做的事

- **不要开"源站只允许 CF 回源"**（防火墙只放行 CF 网段）。certbot 的
  HTTP-01 验证服务器是直连 80 的，开了下次续期就死。要开，先把所有证书
  迁到 DNS-01——那是一次需要用户确认的独立变更。
- 不要往 `ignoreip` 加用户自己的 IP（本模块的 jail 没这条，但 fail2ban-nginx
  的有——见那边）。
- 不要为了放行某个爬虫/某条路径改共享文件的整体逻辑，按模板注释的方式
  收窄那一条，并如实告诉用户改了什么。
- CF 边缘规则让用户自己配（没有凭据，不要代劳），把附录的表达式给他。

## 8. 附录：Cloudflare 边缘规则（免费版够用）

源站三层只能拦"已经打到机器"的流量；经 CF 代理的攻击更该在边缘拦。把下面
几条给用户（Security → WAF → Custom rules，表达式用 Edit expression 粘贴）：

1. **Block 扫站路径**：`http.request.uri.path` contains `/wp-` / `.php` /
   `.env` / `/.git` / `phpmyadmin` / `adminer` / `/vendor/` / `/actuator`。
2. **Block 恶意 UA**：`http.user_agent` contains `sqlmap` / `nikto` /
   `masscan` / `zgrab` / `wpscan`（与 00-hao-hardening.conf 的 bad_ua 表一致）。
3. **Managed Challenge 可疑爬虫**：`cf.threat_score gt 10` 或
   Bytespider——质询页真浏览器能过、脚本过不了，比直接 Block 少误伤 SEO
   （Googlebot/Bingbot 在 CF 的已验证 bot 列表里，自动豁免）。

挨条和源站 scanner-blocks 的清单对齐，两边保持一致。Cloudflare 的 IP 段
（https://www.cloudflare.com/ips/）变化时，`00-hao-hardening.conf` 里的
`set_real_ip_from` 也要跟着更新——模板头部写着这条维护义务。
