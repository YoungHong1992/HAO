# fail2ban-nginx —— 站点扫站与后台爆破的自动封禁

`nginx-hardening` 拦下扫描（403）并限流（429），但 IP 明天还会回来。这个模块
让 fail2ban 读 nginx 日志，把反复出现的 IP 封 24 小时，再犯翻倍：

| jail | 读哪个日志 | 触发 | 封禁 |
|---|---|---|---|
| `hao-nginx-scan` | `*access.log` | 60 秒内 15 次 403/404 | 24h，递增翻倍 |
| `hao-nginx-auth` | `*error.log` | 10 分钟内 8 次真实认证失败 | 24h，递增翻倍 |

**两个 jail 读不同的日志，这不是笔误。** 403/404 只出现在访问日志；而 Basic Auth
的真实失败（密码错、用户不存在）只写 error log。

阈值为什么安全，以及两条刻意的"不做"：

- 正常访客点错几个链接远到不了 15 次/60 秒，扫描器动辄一分钟上百次。
- **scan jail 不数 429。** 限流是毫秒级自愈的软控制，封禁是 24 小时的硬控制。
  把软信号接到硬控制上，一个正常首屏的并发就能凑够阈值——实测一个拉 120 个
  静态资源的页面（30 并发）在 `burst=50` 下打出 69 个 429，是 `maxretry=15` 的
  4.6 倍，共享出口（公司/学校/CGNAT）的访客会因为打开一次首页被封一天。
  而真实扫描器实测只有 ~6 r/s，根本到不了 30 r/s 的限流线，它是靠 403/404
  被抓的。（`nginx-hardening` 那边把 `burst` 放到 200 是同一件事的另一半。）
- **auth jail 读 error log，不数访问日志里的 401。** 访问日志的 401 分不出
  "密码错"和"浏览器还没带凭据时的正常挑战响应"，而后者每次新开标签/隐身
  窗口/curl/监控探测都会产生一个——按它计数，管理员自己 10 分钟内访问 8 次
  后台就把自己封了。用 fail2ban 自带的 `nginx-http-auth` filter 就没有这个
  问题：它只匹配 error log 里的 `password mismatch` 和 `was not found in`。
  没装后台网关时这个 jail 空转，无害。

**诚实边界**：socket 级封禁只对**直连源站**的攻击者有效（这类攻击真实存在，
实测单 IP 一分钟 370 次）。经 Cloudflare 代理的攻击，真实 IP 不直连源站，
封不到——那部分靠 nginx 按真实 IP 限流压制 + 用户在 CF 边缘配规则。
"banned 列表是空的"不等于"没效果"，要看的是扫描流量有没有被 403/429 压下来。

## 1. 前置检查（只读）

```bash
fail2ban-client --version            # ≥ 0.10，bantime.increment 是 0.10 语法
systemctl is-active fail2ban
ls /var/log/nginx/*access.log        # scan jail 的口粮
ls /var/log/nginx/*error.log         # auth jail 的口粮
# auth jail 用的是自带 filter，确认包里真的有（各发行版都有，缺了就是包不完整）
ls /etc/fail2ban/filter.d/nginx-http-auth.conf
"$SKILL/scripts/hao-guard.sh" managed-file /etc/fail2ban/jail.d/hao-nginx.local
```

- fail2ban 包没装 → 先走 `references/fail2ban.md`（那个模块装包 + sshd jail，
  本模块只加站点 jail，不重复装包、不重复 record，否则同一份状态出现两个主人）。
- `managed-file` 返回 `foreign` → 拒绝覆盖。那可能是用户自己或别的工具配的
  封禁策略，覆盖会改掉它。

## 2. 写两个文件

| 模板 | 目标路径 |
|---|---|
| `templates/fail2ban-nginx-scan.conf` | `/etc/fail2ban/filter.d/hao-nginx-scan.conf` |
| `templates/fail2ban-nginx.local` | `/etc/fail2ban/jail.d/hao-nginx.local` |

**只有 scan 需要自己的 filter。** auth jail 用 fail2ban 自带的
`nginx-http-auth`（和 sshd jail 用自带 `filter = sshd` 同一个理由：上游维护、
久经使用，而且它已经正确地只匹配 error log 里的真实认证失败）。曾经这里有
第三个模板 `fail2ban-nginx-auth.conf`，它数访问日志的 401，会把管理员自己封掉。

两个都**没有占位符**，逐字写入。三个坑写在模板注释头里，这里再说一遍因为
它们**都不报错**：

- `backend = auto` 必须显式写。Debian/Ubuntu 的 fail2ban 把 [DEFAULT] backend
  设成了 systemd（读 journal），而 nginx 日志在文件里——不覆盖的话 jail
  装上了也一个 IP 都匹配不到，且没有任何报错。这是 sshd jail 用
  `backend = systemd` 的同一枚硬币的另一面。
- `datepattern` 必须是 nginx 的实际时间格式，**不能用 `{^LN-BEG}`**。访问日志
  的时间戳在行中间的 `[...]` 里，不在行首。写错的表现极具欺骗性：
  `fail2ban-regex` 报 "Failregex: 1 total" 但 "Date template hits:" 是空的，
  每条命中都走 noDate 分支——0.10 直接丢弃（一个 IP 都封不掉），0.11+ 用读取
  时的墙上时钟顶替（findtime 不再反映日志时间）。配套地，failregex 里的方括号
  要写成 `\[\]`：fail2ban 先把日期从行里剥掉再套 failregex。**两处必须一起
  改**，只改一个会掉到 0 匹配。第 3 节的验证专门看这个。
- `logpath` 用 glob 在 fail2ban 启动/reload 时解析一次，**之后新建的日志文件
  不会自动跟进**——每部署一个新站点要 `fail2ban-client reload`
  （`references/site.md` 第 6 节的收尾会提醒，但这是最容易被漏的一步）。

## 3. 验证

### 3.1 filter 对得上日志（**匹配数和日期都要看**）

```bash
fail2ban-regex /var/log/nginx/access.log /etc/fail2ban/filter.d/hao-nginx-scan.conf
```

日志刚轮转时 0 匹配不一定是错，手工造样本再试：

```bash
printf '203.0.113.7 - - [08/Sep/2026:10:00:00 +0800] "GET /.env HTTP/1.1" 404 153 "-" "curl/8.5.0"\n' > /tmp/f2b-sample.log
fail2ban-regex /tmp/f2b-sample.log /etc/fail2ban/filter.d/hao-nginx-scan.conf
rm -f /tmp/f2b-sample.log
```

要看的是**两个**数字，只看第一个会漏掉最阴的那种坏法：

```
Failregex: 1 total            ← 必须 ≥ 1
Date template hits:
|  [1] Day/MON/Year:...       ← **必须有这一行**
```

`Date template hits:` 下面是空的 → `datepattern` 没对上（见第 2 节）。这种状态下
`fail2ban-client status` 依然全绿、`Failregex` 依然有数，但**一个 IP 都不会被
封**。0 匹配还硬要 reload，等于装了一套没人看得见的防护。

auth jail 用自带 filter，同样试一条（error log 的格式）：

```bash
printf '2026/09/08 10:00:01 [error] 1#1: *1 user "admin": password mismatch, client: 203.0.113.9, server: x, request: "GET /_gate/ HTTP/1.1", host: "x"\n' > /tmp/f2b-auth.log
fail2ban-regex /tmp/f2b-auth.log /etc/fail2ban/filter.d/nginx-http-auth.conf
rm -f /tmp/f2b-auth.log
```

### 3.2 jail 起来了，日志文件也认对了

```bash
fail2ban-client reload
fail2ban-client status hao-nginx-scan
fail2ban-client status hao-nginx-auth
```

status 输出里有 jail 实际跟踪的日志文件清单——glob 展开对不对一眼可见，
顺便确认 scan 跟的是 `*access.log`、auth 跟的是 `*error.log`。

### 3.3 封禁后端真的可用（**这一步最容易被跳过**）

jail 显示 enabled 只说明规则加载了，而 ban 动作（iptables / nftables）是
**第一次真的要封人时**才执行的。后端不可用的机器上，jail 一路绿灯，直到某天
该封的时候什么也没发生：

```bash
fail2ban-client get hao-nginx-scan banaction     # 看继承到的是哪个后端
journalctl -u fail2ban -n 30 --no-pager | grep -iE 'error|failed' || echo "启动日志无报错"
```

`banaction` 是 `iptables-*` 就确认 `command -v iptables`，是 `nftables-*` 就确认
`command -v nft`。对不上就装对应的包，或在 jail 里显式指定另一个 `banaction`，
然后 `systemctl restart fail2ban` 再看一次日志。

本模块的 jail **刻意不写 `banaction`**，继承 `[DEFAULT]`，和 `hao-sshd.local`
一致。写死 `banaction = nftables` 有三个代价：统一的 `action.d/nftables.conf`
要 fail2ban ≥ 0.11（第 1 节放行 ≥ 0.10），没装 `nft` 的机器上照样全绿，
而且会让同一台机器的 sshd jail 走 iptables、nginx jail 走 nftables。

### 3.4 真实封禁长这样（来自直连源站的扫描器，可能要等几天）

```bash
fail2ban-client status hao-nginx-scan   # "Currently banned" 列出 IP
nft list tables 2>/dev/null || iptables -S | grep -i f2b   # 按上面查到的后端选一个
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
    managed:/etc/fail2ban/jail.d/hao-nginx.local
"$SKILL/scripts/hao-state.sh" intent fail2ban-nginx maxretry_scan=15 bantime=24h
"$SKILL/scripts/hao-state.sh" handoff
```

只记这两个文件。`/etc/fail2ban/filter.d/nginx-http-auth.conf`（auth jail 用的
自带 filter）、`/etc/fail2ban/jail.conf`、`jail.d/defaults-debian.conf` 都是
包自带的，不碰也不记（同 fail2ban 模块的约定）。

## 6. 不要顺手做的事

- **不要往 `ignoreip` 加用户的家用 IP**——动态的，今天放行明天换地址；
  阈值（15 次/60 秒、8 次/10 分钟）本来就伤不到正常访客。
- **不要把 429 加回 scan filter 的 failregex**，理由见开头那条和模板注释：
  实测正常首屏就能打出 69 个 429。要给限流加自动封禁，得先有一个只在
  "持续超频数分钟"时才计数的信号，那不是现在这套阈值。
- **不要把 auth jail 改成读访问日志的 401**——那会把管理员自己封掉，
  这是删掉旧 `fail2ban-nginx-auth.conf` 模板的原因。
- **不要把 bantime 改成 -1**。永久封禁 + 递增意味着用户自己输错几次后台
  口令就永远进不来（和 sshd jail 同一条理由）。
- **不要单独给 CF 后面的站点装本模块**——先装 `nginx-hardening`，否则抓到
  并封掉的全是 CF 自己的出口 IP。
