# fail2ban-nginx —— 站点扫站与后台爆破的自动封禁

`nginx-hardening` 拦下扫描（403）并限流（429），但 IP 明天还会回来。这个模块
让 fail2ban 读 nginx 访问日志，把反复出现的 IP 用 nftables 封 24 小时，再犯
翻倍：

| jail | 触发 | 封禁 |
|---|---|---|
| `hao-nginx-scan` | 60 秒内 15 次 403/404/429 | 24h，递增翻倍 |
| `hao-nginx-auth` | 10 分钟内 8 次 401 | 24h，递增翻倍 |

阈值为什么安全：正常访客点错几个链接远到不了 15 次/60 秒，扫描器动辄
一分钟上百次；401 只有装了后台 Basic Auth 网关（`references/nginx-hardening.md`
第 4 节）的机器才会产生，没装时这个 jail 空转，无害。

**诚实边界**：socket 级封禁只对**直连源站**的攻击者有效（这类攻击真实存在，
实测单 IP 一分钟 370 次）。经 Cloudflare 代理的攻击，真实 IP 不直连源站，
封不到——那部分靠 nginx 按真实 IP 限流压制 + 用户在 CF 边缘配规则。
"banned 列表是空的"不等于"没效果"，要看的是扫描流量有没有被 403/429 压下来。

## 1. 前置检查（只读）

```bash
fail2ban-client --version            # ≥ 0.10，bantime.increment 是 0.10 语法
systemctl is-active fail2ban
ls /var/log/nginx/*access.log        # nginx 得在写文件日志，jail 才有米下锅
"$SKILL/scripts/hao-guard.sh" managed-file /etc/fail2ban/jail.d/hao-nginx.local
```

- fail2ban 包没装 → 先走 `references/fail2ban.md`（那个模块装包 + sshd jail，
  本模块只加站点 jail，不重复装包、不重复 record，否则同一份状态出现两个主人）。
- `managed-file` 返回 `foreign` → 拒绝覆盖。那可能是用户自己或别的工具配的
  封禁策略，覆盖会改掉它。

## 2. 写三个文件

| 模板 | 目标路径 |
|---|---|
| `templates/fail2ban-nginx-scan.conf` | `/etc/fail2ban/filter.d/hao-nginx-scan.conf` |
| `templates/fail2ban-nginx-auth.conf` | `/etc/fail2ban/filter.d/hao-nginx-auth.conf` |
| `templates/fail2ban-nginx.local` | `/etc/fail2ban/jail.d/hao-nginx.local` |

三个都**没有占位符**，逐字写入。两个坑都写在 jail 模板的注释头里，这里
再说一遍因为它们都不报错：

- `backend = auto` 必须显式写。Debian/Ubuntu 的 fail2ban 把 [DEFAULT] backend
  设成了 systemd（读 journal），而 nginx 日志在文件里——不覆盖的话 jail
  装上了也一个 IP 都匹配不到，且没有任何报错。这是 sshd jail 用
  `backend = systemd` 的同一枚硬币的另一面。
- `logpath` 用 glob（`/var/log/nginx/*access.log`）在 fail2ban 启动/reload
  时解析一次，**之后新建的日志文件不会自动跟进**——每部署一个新站点要
  `fail2ban-client reload`（site.md 收尾会提醒，但这是最容易被漏的一步）。

## 3. 验证

先拿真实日志试 filter，再 reload。公网机器的历史日志里几乎必然有扫描行：

```bash
fail2ban-regex /var/log/nginx/access.log /etc/fail2ban/filter.d/hao-nginx-scan.conf
```

- 有匹配 → filter 与日志格式对上了。
- **0 匹配不一定是错**：日志可能刚轮转。手工造一条样本再试：

```bash
printf '203.0.113.7 - - [08/Sep/2026:10:00:00 +0800] "GET /.env HTTP/1.1" 404 153 "-" "curl/8.5.0"\n' > /tmp/f2b-sample.log
fail2ban-regex /tmp/f2b-sample.log /etc/fail2ban/filter.d/hao-nginx-scan.conf
rm -f /tmp/f2b-sample.log
```

0 匹配还硬要 reload，等于装了一套没人看得见的防护。

```bash
fail2ban-client reload
fail2ban-client status hao-nginx-scan
fail2ban-client status hao-nginx-auth
```

status 输出里有 jail 实际跟踪的日志文件清单——glob 展开对不对一眼可见。

真实封禁长这样（来自直连源站的扫描器，可能要等几天）：

```bash
fail2ban-client status hao-nginx-scan   # "Currently banned" 列出 IP
nft list tables                         # 出现 f2b 的表
```

装了 `nginx-hardening` 的机器，封禁的前提（真实 IP 还原）已在那边验证过；
没装的机器上 `<HOST>` 抓到的是 CF 边缘 IP，**封它会误伤正常访客**——所以
这个模块和 nginx-hardening 成对使用，不要单独推荐给 CF 后面的站点。

## 4. 日常运维（写进给用户的收尾）

```bash
sudo fail2ban-client status hao-nginx-scan               # 看封了谁
sudo fail2ban-client set hao-nginx-scan unbanip 1.2.3.4  # 误封解锁
sudo fail2ban-client set hao-nginx-scan banip 1.2.3.4    # 手工封
```

## 5. 记录状态并交接

```bash
"$SKILL/scripts/hao-state.sh" record fail2ban-nginx installed \
    managed:/etc/fail2ban/filter.d/hao-nginx-scan.conf \
    managed:/etc/fail2ban/filter.d/hao-nginx-auth.conf \
    managed:/etc/fail2ban/jail.d/hao-nginx.local
"$SKILL/scripts/hao-state.sh" intent fail2ban-nginx maxretry_scan=15 bantime=24h
"$SKILL/scripts/hao-state.sh" handoff
```

只记这三个文件。`/etc/fail2ban/jail.conf`、`jail.d/defaults-debian.conf` 是
包自带的，不碰也不记（同 fail2ban 模块的约定）。

## 6. 不要顺手做的事

- **不要往 `ignoreip` 加用户的家用 IP**——动态的，今天放行明天换地址；
  阈值（15 次/60 秒、8 次/10 分钟）本来就伤不到正常访客。
- **不要把 bantime 改成 -1**。永久封禁 + 递增意味着用户自己输错几次后台
  口令就永远进不来（和 sshd jail 同一条理由）。
- **不要单独给 CF 后面的站点装本模块**——先装 `nginx-hardening`，否则抓到
  并封掉的全是 CF 自己的出口 IP。
