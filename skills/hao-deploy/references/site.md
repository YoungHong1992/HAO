# site —— 从 Git 仓库部署自有站点

这是小白用户最常走的一条链路：给一个仓库地址和域名，得到一个能访问的网站。
支持两种类型：`static`（构建产物直接由 Nginx 提供）和 `node`（起一个 Node
进程，Nginx 反代）。

前置：Nginx 已装（见 `references/nginx.md`）、`git` 可用；node 类型还需要
`/usr/bin/node`（见 `references/node.md`）。

## 路径约定：一律用业内通用位置

HAO 部署出来的东西必须让**不知道 HAO 存在的运维人员**也能维护。所以路径和文件名
全部用通用形式，没有 `hao-` 前缀：

| 用途 | 路径 |
|---|---|
| 源码检出 / Node 应用 | `/opt/<站点ID>` |
| 静态站产物（docroot） | `/var/www/<域名>`，无域名时 `/var/www/<站点ID>` |
| vhost | `/etc/nginx/conf.d/<CONF_NAME>.conf` |
| 站点内容块 | `/etc/nginx/snippets/<CONF_NAME>.conf` |
| 证书 | `/etc/letsencrypt/live/<域名>/`（certbot 标准） |
| systemd 单元 | `/etc/systemd/system/<站点ID>.service` |
| 更新脚本 | `/usr/local/bin/<站点ID>-update` |

`<CONF_NAME>` = 有域名时填域名，无域名时填站点 ID。同一个站点的 vhost 和
snippet 必须用同一个值。

**归属判断不受影响**：`hao-guard.sh` 读的是文件里的 `# Managed by HAO` /
`# HAO-SITE:` 注释头，不看文件名。那行注释也不是"特化"——certbot 写
`# managed by Certbot`，Ansible 写 `# Ansible managed`，在生成的配置里标明出处
是通行做法，对接手的人是帮助。**模板里的注释头一行都不能删。**

## 0. 先问清楚（不要猜）

| 要素 | 说明 | 猜错的后果 |
|---|---|---|
| 站点 ID | 小写字母/数字/连字符，如 `blog`、`blog-v2` | 决定所有路径和单元名 |
| 仓库地址 | ssh / https / 本地路径 | 私有仓库要先能拉取 |
| 类型 | `static` 还是 `node` | 完全不同的部署路径 |
| 域名 | 留空 = 80 端口默认站点，不申请证书 | 影响证书与跳转 |
| 分支 | 默认 `main` | 拉错分支等于发错版本 |
| 构建命令 | static 用，如 `npm ci && npm run build` | 留空则直接发布仓库内容 |
| 产物目录 | static 用，默认 `build`；无构建命令时默认 `.` | 填错发布出空站点 |
| 入口文件 | node 用，默认 `server.js` | 服务起不来 |
| 运行用户 | 默认 `$SUDO_USER`，否则 root | 决定文件归属 |

### 变量命名：**不要**用 `$USER`

这一节的命令一律用 `TARGET_USER` / `TARGET_GROUP` / `TARGET_HOME`，和其他 reference
以及模板里的 `@@TARGET_USER@@` 保持一致。原因很具体：

```bash
$ sudo bash -c 'echo $USER'
USER=root
```

`USER`、`HOME`、`GROUPS` 在任何 root/sudo shell 里**本来就有值**。如果用 `$USER`
装运行用户，忘了赋值时 `runuser -u "$USER"` 就变成 `runuser -u root`，
"不要用 root 拉代码"这条约束被完整违反，而且**退出码是 0**，什么都不报。
`intent run_user="$USER"` 还会把 `run_user=root` 记进意图文件，换机器重放也是错的。

一开始就显式派生一次，后面全用这三个变量：

```bash
TARGET_USER="${SUDO_USER:-root}"          # 用户指定了别的就用他给的
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_GROUP="$(id -gn "$TARGET_USER")"
[ -n "$TARGET_HOME" ] || { echo "取不到 $TARGET_USER 的 home，停下来问用户"; exit 1; }
```

**同一台机器只能有一个无域名的默认站点**（`server_name _`）。已经有一个了，
就必须给新站点一个域名。

站点 ID 现在同时是 systemd 单元名，所以**不能用 `nginx`、`docker`、`cron`、`ssh`
这类已有系统单元的名字**，第 1 步的 `unit-free` 会拦住。

## 1. 前置检查（只读）

```bash
"$SKILL/scripts/hao-guard.sh" vhost-owner "$DOMAIN"      # 域名是否被占
"$SKILL/scripts/hao-guard.sh" repo-identity "/opt/$ID" "$REPO"
"$SKILL/scripts/hao-guard.sh" cert-issuer "/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
"$SKILL/scripts/hao-guard.sh" unit-free "$ID"            # node 类型必查
```

**`vhost-owner` 只看一个目录，默认 `/etc/nginx/conf.d`（且不递归）。** 它有第二个
可选参数就是为此：机器上原先装过发行版 nginx（第 1 节明确支持这种机器）时，
冲突的 `server_name` 可能在 `sites-enabled/` 里，默认那次调用**看不见**，
于是返回 `free`，我们写出第二个同名 server_name —— nginx 只打一条 warning，
然后其中一个静默生效。所以那个目录存在时要再查一遍：

```bash
[ -d /etc/nginx/sites-enabled ] && \
    "$SKILL/scripts/hao-guard.sh" vhost-owner "$DOMAIN" /etc/nginx/sites-enabled
```

无域名的默认站点查的是 `_`（`vhost-owner ""` 会直接报错退出）：

```bash
"$SKILL/scripts/hao-guard.sh" vhost-owner _      # 已有默认站点就必须给新站点一个域名
```

**`vhost-owner` 的判断规则（最重要的一道闸）**：

| 输出 | 含义 | 该怎么做 |
|---|---|---|
| `free` | 没人占用 | 继续 |
| `hao-site <本站ID> <path>` | 本站点自己的配置 | 继续，原地更新 |
| `hao-site <别的ID> <path>` | 另一个 HAO 站点占用了这个域名 | **停下**，让用户换域名 |
| `hao <service> <path>` | 别的 HAO 服务占用 | **停下**，让用户换域名 |
| `foreign <path>` | 非 HAO 管理的配置占用 | **停下**，绝不覆盖，报告路径 |

**`unit-free` 的判断规则（node 类型必查）**：输出词汇和 `vhost-owner` 一样。
只有 `free` 或 `hao-site <本站ID>` 才能继续。

单元名不带前缀是通用做法，代价是 `/etc/systemd/system/<name>.service` 会
**静默覆盖** `/usr/lib/systemd/system/` 下的同名单元。站点 ID 撞上 `nginx` 就会
把 Nginx 的单元顶掉，而且不报错。所以这一步不能跳。

`repo-identity` 的判断规则：

- `absent`：目录不存在，正常克隆。
- `ok`：已是同一仓库的检出，走更新流程。
- `not-git`：目录存在但不是 Git 检出 → **停下**，报告路径让用户处理，不要
  `rm -rf`。里面可能是用户自己放的东西。
- `remote-mismatch <脱敏地址>`：同名目录指向别的仓库 → **停下**。要换仓库
  必须由用户确认后手工移除目录。

`/opt` 下可能已经有用户自己放的同名目录（比如手工部署过的应用），`repo-identity`
返回 `not-git` 就是这种情况，一定要停。

`cert-issuer` 有**四**种输出，别只准备两种：

| 输出 | 含义 | 该怎么做 |
|---|---|---|
| `missing` | 还没有证书 | 正常签发 |
| `letsencrypt` | 已有真实证书 | 跳过签发（有速率限制），直接用 |
| `selfsigned` | 上次是自签名兜底 | 可以重试真实签发 |
| `other <issuer>` / `other unreadable` | 那张证书**不是本流程签的**（别的 CA、别的工具、或读不出来） | 当成 `foreign` 处理：**停下**，把 issuer 报给用户。不要覆盖，也不要重签（certbot 会另起一个 `-0001` 的 lineage，之后两张证书谁在续期都说不清） |

域名模式还要确认 DNS 已经指过来，否则证书申请一定失败：

```bash
getent hosts "$DOMAIN" | awk '{print $1}'    # 解析结果
curl -s --connect-timeout 5 https://api.ipify.org   # 本机公网 IP
```

两者不一致就先让用户去改 DNS，不要硬申请证书（失败会退化成自签名，用户看到
浏览器警告后更困惑）。用户不知道怎么配 DNS 时，指给他
`docs/cloudflare-dns-guide.md`（在 skill 所在仓库根的 `docs/` 下）。

**一个例外**：域名走了 Cloudflare 橙云（代理开启）时，解析出来的是 Cloudflare
边缘节点 IP，和本机公网 IP 天然不一致。这不是配错了，不要因此停下——
证书申请仍能通过（走 80 端口的 ACME HTTP 校验）。判断方法：解析结果不是本机 IP，
但用户确认域名托管在 Cloudflare 且开了代理。

## 2. 同步代码

以目标用户身份操作，不要用 root 拉代码（否则文件归属错乱，之后构建会失败）：

```bash
DIR="/opt/$ID"
# 首次克隆
install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_GROUP" "$DIR"
runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" \
    git clone --branch "$BRANCH" "$REPO" "$DIR"

# 已存在（repo-identity == ok）则更新
runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" git -C "$DIR" fetch --prune origin
runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" git -C "$DIR" checkout -f -B "$BRANCH" "origin/$BRANCH"
runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" git -C "$DIR" reset --hard "origin/$BRANCH"
```

克隆失败要把半成品目录删掉再报错，不要留下空目录（下次重跑会被误判为已存在）。

**仓库地址可能内嵌凭据**（`https://user:token@github.com/...`）。在对话、日志、
报错里一律用脱敏形式：`sed -E 's#(://)[^/@]+@#\1***@#'`。

## 3a. static 类型：构建与发布

`DOCROOT` = `/var/www/$DOMAIN`，无域名时 `/var/www/$ID`。

```bash
# 构建（以目标用户执行，CI=true 让多数前端工具进入非交互模式）
runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" CI=true \
    bash -c "cd /opt/$ID && $BUILD_CMD"
```

**先校验产物，再动 docroot。顺序不能反。**「产物目录填错」是这条链路上最常见的
配置错误，而清空 docroot 是不可逆的：先清后拷的话，填错时线上内容已经没了，
`cp` 才失败，站点直接变 404。

```bash
SRC="/opt/$ID/$OUTPUT"
case "$OUTPUT" in
    /*|*..*) echo "产物目录必须是仓库内的相对路径且不含 ..：$OUTPUT"; exit 1 ;;
esac
[ -d "$SRC" ] || { echo "产物目录不存在：$SRC"; exit 1; }
[ -n "$(ls -A "$SRC")" ] || { echo "产物目录是空的：$SRC，拒绝用空内容覆盖站点"; exit 1; }
```

任一条不过就**停下来**，把 `构建命令 / 产物目录` 两个值回显给用户核对，不要继续。

发布用「旁边建好再整体换过去」，中途失败时线上目录一直是完整的旧版本：

```bash
STAGE="$DOCROOT.new.$$"
install -d -m 0755 "$STAGE"
cp -a "$SRC/." "$STAGE/"
[ "$OUTPUT" = "." ] && rm -rf "$STAGE/.git"   # 别把 .git 发到公网
chown -R "$TARGET_USER:$TARGET_GROUP" "$STAGE"
chmod 755 "$STAGE"

if [ -d "$DOCROOT" ]; then
    mv "$DOCROOT" "$DOCROOT.old.$$"
fi
mv "$STAGE" "$DOCROOT"
rm -rf "$DOCROOT.old.$$"
```

`templates/site-update-static.sh.tmpl` 里是同一套顺序（那个脚本以后每次更新都
**无人值守**地跑，更需要这层保护）。

**`DOCROOT` 里可能有用户自己放的东西**：`/var/www/<域名>` 是通用路径，不是 HAO 专有。
上面那段的 `mv "$DOCROOT" "$DOCROOT.old.$$"` 加 `rm -rf` 会把原内容删掉，所以第一次
部署到一个**非空**的 docroot 之前必须先确认它属于本站点。判断依据只有两个：

- 这个站点在 `/var/lib/hao/services/site-<ID>.resources` 里已经登记过这个 docroot；
- 或者用户明确说"那个目录里的东西可以删"。

**`vhost-owner` 不能当这个证据用** —— 它回答的是"谁占用了这个 server_name"，
和"谁往 `/var/www/<域名>` 里放了文件"完全是两件事。

## 3b. node 类型：systemd 服务

端口分配（**幂等关键**）：用户没指定端口时，先从既有单元里读回来复用，
避免每次重跑都换端口：

```bash
PORT="$("$SKILL/scripts/hao-guard.sh" unit-port "/etc/systemd/system/$ID.service")"
# 读不到再从 8100 起找第一个空闲端口
[ -n "$PORT" ] || for p in $(seq 8100 8200); do
    [ "$("$SKILL/scripts/hao-guard.sh" port-free "$p")" = free ] && { PORT="$p"; break; }
done
# 一个都没空出来就停下来，不要带着空 PORT 继续往下写单元和 nginx 配置
[ -n "$PORT" ] || { echo "8100-8200 全被占用，让用户指定一个端口"; exit 1; }
```

同一批部署的多个站点之间也不能撞端口，自己记账。

**写单元之前先确认单元名没被占**（第 1 步已经查过，这里是最后一道）：

```bash
"$SKILL/scripts/hao-guard.sh" unit-free "$ID"   # 必须 free 或 hao-site <本站ID>
```

然后用 `templates/site-node.service` 生成单元文件：

- `@@NODE_BIN@@` **必须是 `/usr/bin/node`**。不要用 `command -v node` 的结果——
  那可能取到家目录里的 node（nvm 或各种版本管理器装的）。真实事故：
  `/home/<user>/.hermes/node/bin/node` 被一个以 root 运行的服务依赖，
  用户清理家目录时服务就坏了，而且 systemd 环境下那个路径本来就不该出现。
  见 `references/node.md` 开头。取不到 `/usr/bin/node` 就先跑 `node` 模块。
- **权限必须 0640**：额外环境变量可能含敏感值
- 不要在 `@@EXTRA_ENV@@` 里设 `PORT`，端口由专门的字段控制

```bash
[ -x /usr/bin/node ] || { echo "缺少 /usr/bin/node，先执行 node 模块"; exit 1; }
NODE_BIN=/usr/bin/node

chmod 0640 "/etc/systemd/system/$ID.service"
systemctl daemon-reload
systemctl enable "$ID.service"
systemctl restart "$ID.service"
```

启动后**必须确认端口真的在监听**（服务 active 不等于应用起来了）。
循环要有一个明确的成功标记，否则失败和成功走的是同一条路径：

```bash
ready=0
for _ in $(seq 1 15); do
    if timeout 2 bash -c ">/dev/tcp/127.0.0.1/$PORT" 2>/dev/null; then
        ready=1; break
    fi
    sleep 2
done
[ "$ready" = 1 ] || {
    journalctl -u "$ID.service" -n 50 --no-pager
    echo "端口 $PORT 在约 60 秒内没有就绪，停下来把上面的日志给用户"
    exit 1
}
```

每轮最多 2 秒探测 + 2 秒等待，15 轮的预算是**约 60 秒**（不是 30）。
`templates/site-update-node.sh.tmpl` 里是同一套写法。

没起来就停下来，把 `journalctl -u $ID.service -n 50` 的输出给用户，
不要继续往下写 Nginx 配置。

### 再回读一次实际绑定地址

应用绑 `0.0.0.0` 还是 `127.0.0.1` 由它自己的代码决定，HAO 的单元管不了。
但**必须查一下并如实告诉用户**：

```bash
ss -tlnH "sport = :$PORT" | awk '{print $4}'
```

结果是 `0.0.0.0:<port>` 或 `*:<port>` 时，说明这个端口绕过 Nginx 直接可达——
TLS、访问控制、限流全都被跳过，此时唯一挡着的是云安全组。告诉用户：

> 你的应用监听在所有网卡上（`0.0.0.0:8100`），意味着有人直接访问
> `http://<你的IP>:8100` 就能绕过 HTTPS 打到它。现在挡住它的只有云服务商的
> 安全组，一旦规则放开就暴露了。建议改代码里的监听地址为 `127.0.0.1`。

不要自己去改用户的代码，也不要因此停下——只是必须说清楚。

## 4. Nginx 配置与证书

顺序很重要：**先让站点在 HTTP 上活起来，再申请证书**。这样 ACME 的 HTTP 校验
路径天然可达，不需要临时配置腾挪。

`CONF_NAME` = 有域名时 `$DOMAIN`，无域名时 `$ID`。

### 占位符：每个模板的 token 都要替换，写完必须自己查一遍

模板里的 `@@TOKEN@@` **一个都不能留**。权威清单在每个模板自己的头部注释里
（那里也解释了每个 token 的含义），这里给个总表便于核对：

| 模板 | 占位符 |
|---|---|
| `site-vhost-http.conf` | `SITE_ID` `CONF_NAME` `SERVER_NAME` |
| `site-vhost-tls.conf` | `SITE_ID` `CONF_NAME` `SERVER_NAME` `DOMAIN` `PORT80_BODY` `QUIC_LISTEN` `ALT_SVC` |
| `site-body-static.conf` | `SITE_ID` `CONF_NAME` `DOCROOT` |
| `site-body-node.conf` | `SITE_ID` `CONF_NAME` `PORT` |
| `site-node.service` | `SITE_ID` `TARGET_USER` `TARGET_HOME` `NODE_BIN` `START_FILE` `PORT` `EXTRA_ENV` |
| `site-update-static.sh.tmpl` | `SITE_ID` `BRANCH` `TARGET_USER` `TARGET_GROUP` `TARGET_HOME` `BUILD_CMD` `OUTPUT_DIR` `DOCROOT` |
| `site-update-node.sh.tmpl` | `SITE_ID` `BRANCH` `TARGET_USER` `TARGET_HOME` `PORT` |

本文里的变量名和 token 名不完全同名，对应关系：
`$ID`→`@@SITE_ID@@`、`$ENTRY`→`@@START_FILE@@`、`$OUTPUT`→`@@OUTPUT_DIR@@`、
`$TARGET_USER`/`$TARGET_GROUP`/`$TARGET_HOME`→同名 token。

**每写完一个文件，`nginx -t` / `daemon-reload` 之前先查残留：**

```bash
grep -n '@@[A-Z]' "$FILE" && { echo "还有占位符没替换，停下来"; exit 1; }
```

漏掉的后果不只是配置不对。`@@SITE_ID@@` 出现在归属头 `# HAO-SITE:` 里，
残留会让 `hao-guard.sh vhost-owner` 报 `hao-site @@SITE_ID@@` ——
按第 1 节的规则那意味着"另一个 HAO 站点占用了这个域名"，于是**本站点以后
再也无法更新自己**，而且现象和原因毫不相关。

**第一步**：写内容块和 HTTP 版 vhost。

- `templates/site-body-static.conf` 或 `site-body-node.conf`
  → `/etc/nginx/snippets/$CONF_NAME.conf`
- `templates/site-vhost-http.conf` → `/etc/nginx/conf.d/$CONF_NAME.conf`
  （无域名时 `@@SERVER_NAME@@` 填 `_`，`@@CONF_NAME@@` 填站点 ID）

写之前备份，`nginx -t` 失败要能回滚：

```bash
CONF="/etc/nginx/conf.d/$CONF_NAME.conf"
BAK=""
[ -f "$CONF" ] && { BAK="$CONF.bak.$(date +%Y%m%d_%H%M%S)"; cp -a "$CONF" "$BAK"; }
# ... 写入 ...
if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx || systemctl start nginx
else
    nginx -t 2>&1            # 原始输出给用户看
    # 有备份就恢复，没备份才删。**不要**写成 `[ -n "$BAK" ] && cp … || rm -f …`：
    # 那个形式在 cp 本身失败时也会执行 rm，把还在服务的配置删掉。
    if [ -n "$BAK" ]; then
        cp -a "$BAK" "$CONF"
    else
        rm -f "$CONF"
    fi
    nginx -t >/dev/null 2>&1 && systemctl reload nginx
    echo "nginx -t 未通过，已回滚。把上面的原始输出给用户，不要继续。"
    exit 1
fi
```

**站点能否真的取到内容要自己验一次**，别停在 `nginx -t` 通过就报成功：

```bash
# 有域名（TLS 还没配好时先验 80）
curl -sS -o /dev/null -w '%{http_code}\n' -H "Host: $DOMAIN" http://127.0.0.1/
# 无域名的默认站点
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1/
```

不是 2xx/3xx 就停下来：static 看 `ls "$DOCROOT"`（多半是产物目录填错），
node 看 `journalctl -u "$ID.service" -n 50`（多半是应用没起来）。

无域名或 `CERT=no` 的站点到这里就结束了，跳到第 5 步。

**第二步**：申请证书，用 **certbot**。已有真实证书就不要重复申请
（`cert-issuer` 返回 `letsencrypt` 即跳过；返回 `selfsigned` 说明上次是兜底的，
可以重试真实申请）。

certbot 而不是 acme.sh，理由是"通用"这三个字的具体含义：它来自发行版仓库
（不用 `curl | sh`）、续期 timer 随包安装、证书落在所有人预期的
`/etc/letsencrypt/live/<域名>/`，接手的运维不需要学任何 HAO 特有的东西。

```bash
export DEBIAN_FRONTEND=noninteractive
command -v certbot >/dev/null || { apt-get update -y -qq; apt-get install -y -qq certbot; }
```

**不要装 `python3-certbot-nginx`。** 那个插件会去改 nginx 配置，和 HAO 的模板
打架，还会让 `drift` 天天报警。用 `certonly --webroot`：certbot 只负责签发，
配置仍由模板负责，两边职责清楚。

```bash
# 账户邮箱不能是 example.com / localhost / test.com 这类占位域名，
# 否则 Let's Encrypt 会拒绝注册。用主域名推导一个：
MAIN="$(echo "$DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')"
EMAIL="admin@$MAIN"

# webroot 必须和 snippets/acme-challenge.conf 里的 root 一致
install -d -m 0755 /var/www/html

certbot certonly --webroot -w /var/www/html -d "$DOMAIN" \
    --non-interactive --agree-tos -m "$EMAIL"
```

certbot 2.x 默认就是 ECDSA 密钥，不用额外指定。

**续期不需要 HAO 做任何事**：`certbot.timer` 随包安装并自动启用。验证一下并把
结果告诉用户：

```bash
systemctl list-timers certbot.timer --no-pager
```

续期后重载 Nginx 的 deploy 钩子**由 `nginx` 模块安装**（它对所有证书生效，
不是某个站点专属的），见 `references/nginx.md` 第 4 节。这里只确认它在：

```bash
[ -x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh ] \
    || echo "钩子不在，按 references/nginx.md 第 4 节装上，否则续期后 Nginx 仍用旧证书"
```

申请失败时降级为自签名（站点仍可用，只是浏览器告警），并**如实告诉用户这是
自签名证书**，不要说成"证书已配置好"。自签名证书放 Debian 标准位置，
**不要塞进 `/etc/letsencrypt/`**——那个目录归 certbot 管，混进手工文件会让它
和续期逻辑都变得难以理解：

```bash
install -d -m 0755 /etc/ssl/certs
install -d -m 0700 /etc/ssl/private
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "/etc/ssl/private/$DOMAIN.key" \
    -out    "/etc/ssl/certs/$DOMAIN.pem" \
    -subj "/CN=$DOMAIN" -addext "subjectAltName=DNS:$DOMAIN"
chmod 600 "/etc/ssl/private/$DOMAIN.key"
chmod 644 "/etc/ssl/certs/$DOMAIN.pem"
```

走自签名分支时，TLS vhost 里**只**把那两行证书路径换成上面这两个，别的不用动：
协议、套件、会话、HSTS 都在 `snippets/ssl-hardening.conf` 里，两种证书都适用。

**第三步**：改写成 TLS 版 vhost（`templates/site-vhost-tls.conf`），同样是
备份 → 写入 → 查 `@@` 残留 → `nginx -t` → reload/回滚。写完再验一次真实内容：

```bash
curl -sS -o /dev/null -w '%{http_code}\n' --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/"
# 自签名证书时加 -k（那本身就说明客户端会看到告警，要如实告诉用户）
```

### ⚠️ 522 教训：什么时候才允许 80→443 跳转

只有**同时**满足以下三条，才填入 301 跳转：

1. `cert-issuer` 确认是 `letsencrypt`（真实证书，不是自签名）；
2. 用户没有明确要求关闭跳转；
3. **用户已经确认云服务器安全组/防火墙放行了 443/TCP**。

第 3 条必须真的问一句。很多 VPS 面板默认只开 80，一旦启用跳转，浏览器被 301
到打不通的 443，站点会**完全不可访问**（典型现象：Cloudflare 522 超时）。
这个故障对小白来说极难自查——站点刚才还好好的，配完证书就全白了。

自签名证书**永不跳转**，80 端口直接提供服务。

无论是否跳转，`/.well-known/acme-challenge/` 都必须留在 80 上
（模板里的 `include /etc/nginx/snippets/acme-challenge.conf` 已经保证了这点），
否则证书续期会失败。

## 5. 生成更新脚本

用 `templates/site-update-static.sh.tmpl` 或 `site-update-node.sh.tmpl`
生成 `/usr/local/bin/$ID-update`，权限 0755。占位符清单见第 4 节的总表，
写完照样 `grep -n '@@[A-Z]'` 查一遍——这个脚本以后是无人值守跑的，
一个残留占位符会在几周后的某次更新里才炸。

脚本内嵌解析后的字面量，不依赖本 skill，用户之后自己 `sudo $ID-update`
就能更新站点。值里含单引号要转义成 `'\''`。

## 6. 记录状态并交接

```bash
"$SKILL/scripts/hao-state.sh" record "site-$ID" installed \
    managed:/etc/nginx/conf.d/$CONF_NAME.conf \
    managed:/etc/nginx/snippets/$CONF_NAME.conf \
    managed:/usr/local/bin/$ID-update \
    observed:/opt/$ID
# node 类型再加：managed:/etc/systemd/system/$ID.service
# static 类型再加：observed:$DOCROOT
# 真实证书再加：observed:/etc/letsencrypt/live/$DOMAIN/fullchain.pem
"$SKILL/scripts/hao-state.sh" handoff
```

`record` 会**静默跳过不存在的路径**（只在输出里打一行"跳过不存在的路径: …"）。
那行不是提示信息，是**证据**：它说明你以为写了的东西其实没写成，回去查那一步。

`result` 用哪个词：第一次装完 `installed`；已有站点重新部署 `updated`；
只做了检查没改东西 `verified`；中途失败 `failed`；因为归属检查或用户拒绝而
没做 `skipped`。别一律写 `installed` —— 下一个 agent 靠这个词判断这台机器
上次到底发生了什么。

**service ID 必须是 `site-$ID` 而不是 `site`。** `record` 是整体替换，都记成 `site`
会让先部署的站点静默从状态里消失，理由和完整说明见 `references/handoff.md`
「一个 service ID 只有一条记录」。

克隆目录记 `observed` 而不是 `managed`：里面的内容由用户的仓库决定，每次
更新都会变，记 managed 会让 `drift` 天天误报。同理，`DOCROOT` 里是构建产物、
证书由 certbot 续期时替换，两者都记 `observed`。

然后把用户给的那些回答记成部署意图——这是新机器上重放这次部署的唯一依据：

```bash
# CERT_STATE 填 cert-issuer 的实际结果：letsencrypt / selfsigned / none
"$SKILL/scripts/hao-state.sh" intent "site-$ID" \
    type="$TYPE" \
    repo="$REPO" \
    branch="$BRANCH" \
    domain="${DOMAIN:-}" \
    build_cmd="${BUILD_CMD:-}" \
    output_dir="${OUTPUT:-}" \
    entry="${ENTRY:-}" \
    run_user="$TARGET_USER" \
    cert="$CERT_STATE"
```

`repo` 里内嵌的凭据会被自动脱敏,不用自己处理。**不要**往里塞任何密钥——
key 名**含有** `password`/`passwd`/`token`/`secret`/`apikey`/`api_key`/`credential`/`private_key`
任一子串的会被直接拒绝（所以 `token_ttl` 这种无害的名字也会被拒，换个词）。
key 还必须**以小写字母开头**，只含小写字母、数字、下划线。
node 类型不填 `build_cmd`/`output_dir`，static 类型不填 `entry`，留空即可。

## 7. 汇报给用户

至少说清这几件事，用普通话而不是路径清单：

- 访问地址（真实证书 `https://域名`；自签名要说明浏览器会告警；无域名给 `http://IP`）
- 是否启用了跳转，以及 443 放行的提醒
- 更新命令：`sudo $ID-update`
- 代码目录 `/opt/$ID`、发布目录 / 服务单元 `$ID.service` 与端口
- 证书由 certbot 自动续期（`certbot.timer`），**不需要他做任何事**
- node 站点若绑在 `0.0.0.0`，把第 3b 节那段提醒讲给他
- **让他把 `/var/lib/hao/DEPLOY-INTENT.md` 存一份到自己的笔记或仓库里**——
  机器销毁后，那是重建这个站点的唯一依据

## 常见问题

- **站点 404**：static 产物目录填错，`ls $DOCROOT` 看是不是空的。
- **502 Bad Gateway**：node 服务没起来，看 `journalctl -u $ID.service`。
- **配好证书后站点全白 / 522**：跳转启用了但 443 没放行。改成不跳转先恢复可用，
  再让用户去开安全组。
- **`nginx -t` 报找不到 `/etc/letsencrypt/options-ssl-nginx.conf`**：那个文件由
  `python3-certbot-nginx` 提供，而本 skill 不装那个插件，所以**它永远不会出现**。
  说明 vhost 里还有那行 include（旧版本模板的遗留）——删掉它，TLS 参数在
  `snippets/ssl-hardening.conf` 里。`ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem`
  同理。**这跟证书签没签成功无关**，别去查 certbot。
- **`nginx -t` 报某个 `@@TOKEN@@` 附近语法错误**：占位符没替换完，
  `grep -n '@@[A-Z]' <文件>` 找出来。
- **本站点更新时被自己拦住（`vhost-owner` 报 `hao-site @@SITE_ID@@`）**：
  上次写入时 `@@SITE_ID@@` 没被替换，归属头成了字面量。改掉那一行即可。
- **证书申请失败**：先查 DNS 是否指向本机、80 是否可从公网访问、`-w` 的 webroot
  和 `snippets/acme-challenge.conf` 里的 `root` 是否一致、域名是否被另一个
  server 块抢走（`hao-guard.sh vhost-owner`）。
- **`systemctl enable $ID.service` 之后系统服务出问题了**：站点 ID 撞上了发行版
  单元名，`/etc/systemd/system/$ID.service` 把它覆盖了。第 1 步的 `unit-free`
  就是拦这个的。删掉该文件、`daemon-reload`，然后换一个站点 ID。
- **重跑一次端口变了**：没有先用 `unit-port` 读回既有端口。
- **`drift` 不检查某个站点**：那个站点的状态被后来部署的站点覆盖了——两次都记成
  了 `site` 而不是 `site-<id>`。重跑一次 `record "site-$ID" ...` 补回来。
