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

**vhost 的文件名不只是名字**：`conf.d/*.conf` 按文件名排序 include，而没人显式写
`default_server` 时，某个地址上的第一个 server 块就是默认站点。所以在一台已有站点
的机器上加一个新 vhost，可能仅因为文件名排在前面就把"未知域名落到谁身上"换掉了。
第 4 节有一步专门查这件事。

**别照用户仓库里的部署文档改路径。** 仓库里常有一份为**上一台机器**写的
`DEPLOYMENT.md` / `deploy/` 目录（写着 `/root/projects/…`、源码编译的
`/usr/local/nginx/…` 之类）。那是历史，不是这台机器的现实：照它走会把东西装到
和本表不一致的地方，接手的人两头都找不到。做法是 —— **用本表的路径，不改用户的
仓库文件，但在收尾汇报里明确说一句"你仓库里的那份部署文档和这次的实际布局不一致"**。
不说的话，用户下次照那份文档操作会扑空。

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
| 域名走不走 CDN | 走了就再问一句「CDN 到源站是 HTTP 还是 HTTPS」（Cloudflare 叫 SSL/TLS 模式） | 回源走 HTTP 时源站开跳转 = 无限重定向，站点完全打不开，见第 4 节 |
| 证书联系邮箱 | 有域名时问一句，可以不给（那就明确地不注册联系方式）。**不要从域名拼一个** | 拼出来的地址多半不存在，多级后缀还会算成别人的域名，见第 4 节 |
| 分支 | 默认 `main` | 拉错分支等于发错版本 |
| 构建命令 | **两种类型都要问**。先看仓库用哪个包管理器（第 3a 节有判据表，`pnpm-lock.yaml` 的仓库用 `npm ci` 是装不对的）。static 如 `pnpm install --frozen-lockfile && pnpm run build`；node 至少要装依赖，如 `npm ci --omit=dev` | node 站点漏了它服务根本起不来（缺 node_modules）；包管理器用错则依赖树不对或被 `preinstall` 钩子拦住；static 留空则直接发布仓库内容 |
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

**一个例外**：域名走了 CDN（Cloudflare 橙云这类代理模式）时，解析出来的是 CDN
边缘节点 IP，和本机公网 IP 天然不一致。这不是配错了，不要因此停下——
证书申请仍能通过（走 80 端口的 ACME HTTP 校验）。判断方法：解析结果不是本机 IP，
但用户确认域名托管在 CDN 且开了代理。

**但要记住这件事，第 4 节还要用到它**：走了 CDN 就必须额外问一句"CDN 到源站是
HTTP 还是 HTTPS"，那个答案决定源站能不能开 80→443 跳转（回源走 HTTP 时开跳转
= 无限重定向，站点完全打不开）。一次问完，别等配到一半再回头问。

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

### 先看这个仓库用哪个包管理器（**不要一律 npm**）

前端项目锁定 pnpm / yarn / bun 的很常见，而用错包管理器的表现是"装了一堆依赖但
构建失败"，或者仓库的 `preinstall` 钩子直接把你拦住（`only-allow pnpm` 就是干
这个的）。判据在仓库里，按顺序看：

```bash
# 1. package.json 的 packageManager 字段是最权威的（Node 的 corepack 认它）
sed -n 's/.*"packageManager"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "/opt/$ID/package.json"
# 2. 没有那个字段就看 lockfile
ls "/opt/$ID" | grep -E '^(pnpm-lock\.yaml|yarn\.lock|bun\.lockb?|package-lock\.json)$'
```

| 看到 | 构建命令用 | 装法 |
|---|---|---|
| `package-lock.json` / 什么都没有 | `npm ci && npm run build` | 已经有了（`node` 模块带 npm） |
| `pnpm-lock.yaml` 或 `packageManager: pnpm@x` | `pnpm install --frozen-lockfile && pnpm run build` | corepack，见下 |
| `yarn.lock` 或 `packageManager: yarn@x` | `yarn install --immutable && yarn build` | corepack，见下 |
| `bun.lockb` | `bun install --frozen-lockfile && bun run build` | 上游没有 apt 源，**停下来问用户**是否接受 `curl \| bash` 装 bun |

pnpm / yarn 用 **corepack**，它随 Node 一起装好了，不引入第三方源，而且版本由仓库
的 `packageManager` 字段决定（比我们自己挑一个版本更对）：

```bash
# shim 装 /usr/local/bin，和 uv 模块同一个约定 —— 不要装进 /usr/bin，那是 apt 的地盘
corepack enable pnpm --install-directory /usr/local/bin      # 或 yarn
command -v pnpm
```

**构建命令里必须带 `COREPACK_ENABLE_DOWNLOAD_PROMPT=0`。** corepack 第一次取某个
版本的包管理器时会弹一个确认提示；更新脚本是**无人值守**跑的，那个提示会让它
永久挂住，而且日志里看不出在等什么。仓库以后升级 `packageManager` 版本就会再触发
一次，所以这个环境变量不是只在首次装的时候需要：

```bash
BUILD_CMD='COREPACK_ENABLE_DOWNLOAD_PROMPT=0 pnpm install --frozen-lockfile && COREPACK_ENABLE_DOWNLOAD_PROMPT=0 pnpm run build'
```

corepack 的 shim 记 **`observed` 而不是 `managed`**：`/usr/local/bin/pnpm` 是个指向
corepack 内部文件的符号链接，内容由 `nodejs` 包决定，Node 一升级它就变 ——
记 `managed` 会让 `drift` 从此天天误报。记在 `node` 服务下（它是 Node 工具链的一
部分，下一个站点也能直接用），不要记在某个站点下。

### 构建前看一眼内存

小内存 VPS 上跑前端构建被 OOM killer 杀掉是经典故障，而它的报错只有一个词
`Killed` —— 和"依赖装错""配置写错"看起来毫无区别，极难自查：

```bash
free -m | awk '/^Mem:/{print "内存 " $2 " MB"} /^Swap:/{print "swap " $2 " MB"}'
```

内存 < 2 GB 且没有 swap，**先跑 `swap` 模块再回来构建**（见 `references/swap.md`）。
这是 swap 模块存在的主要理由之一，别等构建被杀了才想起来。

### 构建

```bash
# 以目标用户执行，CI=true 让多数前端工具进入非交互模式
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
OLD="$DOCROOT.old.$$"
# 注意：这一段必须在**同一次** shell 调用里跑完。trap 是进程级的，分成两次
# Bash 调用的话第一次结束时就会把 $STAGE 删掉，后面 mv 到一个不存在的目录。
trap 'rm -rf "$STAGE"' EXIT      # 中途失败别在 /var/www 下留一堆 .new.<pid>
install -d -m 0755 "$STAGE"
cp -a "$SRC/." "$STAGE/"
[ "$OUTPUT" = "." ] && rm -rf "$STAGE/.git"   # 别把 .git 发到公网
chown -R "$TARGET_USER:$TARGET_GROUP" "$STAGE"
# 权限要显式放开，不能只靠 cp -a 带过来的。`cp -a` 保留源文件的模式，而仓库里
# 的文件可能是 0600（umask 077 下 clone 出来的就是），Nginx 以 nginx 用户读，
# 于是站点 403 —— 现象和"产物目录填错"的 404 不一样，容易查错方向。
# 目录要 755（要能进），文件 644 就够。
find "$STAGE" -type d -exec chmod 755 {} +
find "$STAGE" -type f -exec chmod 644 {} +

[ -d "$DOCROOT" ] && mv "$DOCROOT" "$OLD"
if ! mv "$STAGE" "$DOCROOT"; then
    [ -d "$OLD" ] && mv "$OLD" "$DOCROOT"     # 还原，宁可不更新也不能让站点空着
    echo "发布失败，已还原原有内容"; exit 1
fi
rm -rf "$OLD"
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

### 先装依赖（漏了这一步服务一定起不来）

`git clone` 只拿到源码，`node_modules` 不在仓库里。**先装依赖再写单元**，
否则 `systemctl start` 之后进程立刻退出，现象是 Nginx 502，而真正的原因
（`Cannot find module 'express'`）只在 journal 里：

**包管理器同样先按第 3a 节那张表判一次**（`pnpm-lock.yaml` 的仓库用 `npm ci` 装不出
正确的依赖树），node 类型对应的是 `--omit=dev` / `--prod` 那一档。

```bash
# BUILD_CMD 是第 0 节问来的，node 类型至少是 `npm ci --omit=dev`
# （pnpm 仓库则是 `pnpm install --frozen-lockfile --prod`）。
# 以目标用户执行：root 装出来的 node_modules 归 root，之后以目标用户运行的服务
# 可能写不进缓存目录，而且和"不要用 root 拉代码"是同一个理由。
[ -n "$BUILD_CMD" ] || echo "警告：node 类型没有构建命令，只有零依赖的单文件脚本才可能是对的，回去和用户确认一次"
runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" CI=true \
    bash -c "cd /opt/$ID && $BUILD_CMD"
```

失败就**停在这里**，把原始输出给用户（多半是 Node 主版本不对、私有依赖拉不到、
或者 `package-lock.json` 没提交）。不要带着装不上的依赖继续往下写单元，
那样错误会推迟到"端口不就绪"才暴露，排查方向也被带偏。

`npm ci` 需要 `package-lock.json`；只有 `package.json` 时它会直接报错，
这时改用 `npm install --omit=dev` 并告诉用户为什么（锁文件没提交，
版本不可重现）。

### 端口分配

端口分配（**幂等关键**）：用户没指定端口时，先从既有单元里读回来复用，
避免每次重跑都换端口：

```bash
PORT="$("$SKILL/scripts/hao-guard.sh" unit-port "/etc/systemd/system/$ID.service")"
# 读不到再从 8100 起找第一个空闲端口。
# 只接受 `free`：`unknown` 表示 ss/netstat 都不在、根本查不了，那种情况下不能
# 假定端口空闲（先 apt-get install -y iproute2）。
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
| `site-vhost-http.conf` | `SITE_ID` `CONF_NAME` `SERVER_NAME` `DEFAULT` |
| `site-vhost-tls.conf` | `SITE_ID` `CONF_NAME` `SERVER_NAME` `DOMAIN` `PORT80_BODY` `HTTP2` `QUIC_LISTEN` `ALT_SVC` |
| `site-body-static.conf` | `SITE_ID` `CONF_NAME` `DOCROOT` |
| `site-body-node.conf` | `SITE_ID` `CONF_NAME` `PORT` |
| `site-node.service` | `SITE_ID` `TARGET_USER` `TARGET_HOME` `NODE_BIN` `START_FILE` `PORT` `EXTRA_ENV` |
| `site-update-static.sh.tmpl` | `SITE_ID` `BRANCH` `TARGET_USER` `TARGET_GROUP` `TARGET_HOME` `BUILD_CMD` `OUTPUT_DIR` `DOCROOT` |
| `site-update-node.sh.tmpl` | `SITE_ID` `BRANCH` `TARGET_USER` `TARGET_HOME` `BUILD_CMD` `PORT` |

本文里的变量名和 token 名不完全同名，对应关系：
`$ID`→`@@SITE_ID@@`、`$ENTRY`→`@@START_FILE@@`、`$OUTPUT`→`@@OUTPUT_DIR@@`、
`$TARGET_USER`/`$TARGET_GROUP`/`$TARGET_HOME`→同名 token。

内容块模板里的两行 glob include（`scanner-blocks*.conf` /
`security-headers*.conf`）属于 `nginx-hardening` 模块：装了就自动生效，
没装就是无匹配的空操作。**照模板原样保留，不要因为"机器上没这个文件"
删掉**——删了，之后装 hardening 时这个站点不会自动受保护，得手工补
（步骤见 `references/nginx-hardening.md` 第 3 节）。装了 `fail2ban-nginx`
的机器还要在收尾 `fail2ban-client reload` 一次，那一步在第 6 节。

### 先探测这台机器上的 nginx 能力（决定三个占位符怎么填）

**不要假设 nginx 是本 skill 从 nginx.org 装的那个。** 第 1 节明确支持"机器上原先
装过发行版 nginx"，而发行版仓库里的版本往往落后好几年。`http2 on;` 这个独立指令
是 **nginx 1.25.1 才引入的**，更老的版本上 `nginx -t` 会直接报
`unknown directive "http2"` —— 而这一步失败发生在证书签发**之后**，很容易被当成
证书问题去查。所以版本要**现场探测**，不要按发行版猜：

```bash
NGINX_VER="$(nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9.]*\).*|\1|p')"
# 1.25.1 起才有独立的 http2 指令。比的是「<= 1.25.0」——nginx 的版本号只有三段，
# 所以这等价于「< 1.25.1」，而 sort -V -C 在相等时也算有序，直接跟 1.25.1 比会把
# 1.25.1 自己判成老版本。
if printf '%s\n1.25.0\n' "$NGINX_VER" | sort -V -C; then
    HTTP2=""                    # 老版本：整行删掉，HTTP/2 不开
else
    HTTP2="http2 on;"
fi
# HTTP/3 另外要看模块编译进去了没有
if nginx -V 2>&1 | grep -q http_v3_module; then
    QUIC_LISTEN="listen 443 quic;"
    ALT_SVC="add_header Alt-Svc 'h3=\":443\"; ma=86400';"
else
    QUIC_LISTEN=""; ALT_SVC=""
fi
echo "nginx $NGINX_VER / http2=${HTTP2:-off} / http3=${QUIC_LISTEN:+on}"
```

（`sort -V -C` 在"第一行 ≤ 第二行"时退出 0，所以上面那个判断的意思是
"版本 <= 1.25.0"，也就是"没有 http2 指令"。）三个都可能是空串——**填空串就是把
那一行删掉**，不要留下空的 `@@TOKEN@@`。HTTP/2 或 HTTP/3 没开不是失败，
收尾时如实说一句就行。

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
  （无域名时 `@@SERVER_NAME@@` 填 `_`，`@@CONF_NAME@@` 填站点 ID，
  `@@DEFAULT@@` 填 ` default_server`（前导空格）——理由见模板注释；
  有域名时 `@@DEFAULT@@` 填空）

写之前备份，`nginx -t` 失败要能回滚：

```bash
CONF="/etc/nginx/conf.d/$CONF_NAME.conf"
BAK=""
[ -f "$CONF" ] && { BAK="$CONF.bak.$(date +%Y%m%d_%H%M%S)"; cp -a "$CONF" "$BAK"; }
# ... 写入 ...
if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx || systemctl start nginx
    # 成功了就把备份删掉。**不要留在 conf.d 里**：备份是 HAO 文件的副本，同样带着
    # `# Managed by HAO` 和 `# HAO-SITE:` 头，于是每次重新部署都在 conf.d 下攒一个
    # 无主副本（`hao-state.sh orphans` 会把它们全列出来）。nginx 只 include
    # `*.conf`，所以它们不影响运行 —— 但下一个来看这个目录的人分不清哪个是线上的。
    [ -n "$BAK" ] && rm -f "$BAK"
else
    nginx -t 2>&1            # 原始输出给用户看
    # 有备份就恢复，没备份才删。**不要**写成 `[ -n "$BAK" ] && cp … || rm -f …`：
    # 那个形式在 cp 本身失败时也会执行 rm，把还在服务的配置删掉。
    if [ -n "$BAK" ]; then
        cp -a "$BAK" "$CONF"
        rm -f "$BAK"
    else
        rm -f "$CONF"
    fi
    nginx -t >/dev/null 2>&1 && systemctl reload nginx
    echo "nginx -t 未通过，已回滚。把上面的原始输出给用户，不要继续。"
    exit 1
fi
```

（要留一份配置历史的话，留在 `conf.d` 之外 —— 那个目录是 nginx 的工作目录，
不是版本库。真正可重放的东西是 `DEPLOY-INTENT.md`。）

**站点能否真的取到内容要自己验一次**，别停在 `nginx -t` 通过就报成功：

```bash
# 有域名（TLS 还没配好时先验 80）
curl -sS -o /dev/null -w '%{http_code}\n' -H "Host: $DOMAIN" http://127.0.0.1/
# 无域名的默认站点
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1/
```

**状态码不够，还要确认这次请求真的落在本站点上。** 每个站点的内容块都写了自己的
`access_log`，所以日志里有没有刚才那一行就是最直接的证据：

```bash
tail -n 1 "/var/log/nginx/$CONF_NAME.access.log"
```

取不到那一行说明请求被**别的 server 块**接走了（最常见的是包自带的
`conf.d/default.conf` 抢了 `:80` 的 default server —— 它的欢迎页也返回 200，
所以只看状态码会得到一个假成功）。这时回 `references/nginx.md` 第 3 节末尾
把 `default.conf` 停用掉，或者检查 `@@DEFAULT@@` 是否漏填了 `default_server`。

### 加一个站点会改变别人的默认站点 —— 查一次并如实汇报

`include /etc/nginx/conf.d/*.conf` 是**按文件名排序**展开的，而某个地址上的
default server 是"第一个 server 块"（没人显式写 `default_server` 时）。于是给一台
已经有站点的机器**新增**一个 vhost，可能仅仅因为文件名排在前面，就把"未知域名 /
直接用 IP 访问时看到谁"这件事换掉了 —— 而两个站点各自的域名都还正常，
所以从站点验证里完全看不出来。

写完 vhost 一定要查一次，变了就告诉用户：

```bash
# 谁在 :80 / :443 上当默认站点（显式声明的话这里会列出来）
nginx -T 2>/dev/null | grep -n 'default_server' || echo "没有任何 server 显式声明 default_server，按文件名排序决定"
ls /etc/nginx/conf.d/*.conf              # 排在最前面的那个就是隐式默认站点
# 直接问一次：未知域名会落到谁身上
curl -sS -o /dev/null -w '%{http_code}\n' -H "Host: nonexistent.invalid" http://127.0.0.1/
tail -n 1 /var/log/nginx/*.access.log     # 哪个站点的日志里多了这一条，就是它
```

这不是错误，多数情况下也无害（各站点的域名都正确命中）。但它是一个**这次部署
改变了其他站点行为**的事实，收尾汇报里要提一句；用户不想要就给他两条路：把新站点
的文件名改成排序在后，或者显式给某个站点加 `default_server`（改别人的 vhost
之前要单独确认，那是 `foreign` 资源）。

### 别停在源站直连 —— 域名走 CDN 时要从公网再取一次

上面几条 `curl` 用的都是 `-H "Host:"` 或 `--resolve ...:127.0.0.1`，走的是**源站
直连**。它证明的是"nginx 配对了"，证明不了"用户在浏览器里能打开"：安全组没放行
443、CDN 没回源、DNS 还没生效，源站照样返回 200。

```bash
curl -sS -o /dev/null -w 'http  -> %{http_code}\n' "http://$DOMAIN/"   --max-time 15
curl -sS -o /dev/null -w 'https -> %{http_code}\n' "https://$DOMAIN/"  --max-time 15
```

取不到就**如实说"源站已就绪，但从公网还打不开"**，并给出最可能的三个原因
（安全组 443、CDN 回源设置、DNS 生效），不要报成"部署完成"。这一步在 CDN 后面
尤其重要 —— 源站和公网是两条不同的路径。

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
# webroot 必须和 snippets/acme-challenge.conf 里的 root 一致
install -d -m 0755 /var/www/html
```

**先自己探一次 challenge 路径，再去请求 Let's Encrypt。** 这一步不能省：失败的
验证要算进速率限制（每个域名每小时只有几次），而"DNS 指对了"根本不等于"这个路径
取得到" —— webroot 和 `-w` 不一致、域名被另一个 server 块抢走、CDN 没回源，
任一条都会让验证失败，而 certbot 的报错只会说"challenge failed"，不会告诉你是哪一环。
自己探一次的成本是零：

```bash
PROBE="hao-probe-$(openssl rand -hex 6)"
install -d -m 0755 /var/www/html/.well-known/acme-challenge
printf '%s\n' "$PROBE" > "/var/www/html/.well-known/acme-challenge/$PROBE"
chmod 644 "/var/www/html/.well-known/acme-challenge/$PROBE"

# -L -k 是刻意的：Let's Encrypt 做 http-01 验证时会跟随重定向，且不校验跳转到
# https 之后的证书。探测要模仿它的行为，否则一个 80->443 跳转就会让我们误判成
# 「路径不可达」而白白放弃一次本来能成功的签发。
# 走**公网域名**而不是 127.0.0.1 —— 回环取到只证明 nginx 配对了，证明不了
# Let's Encrypt 能从外面进来（安全组、CDN 回源、DNS 都在这条路上）。
GOT="$(curl -sSLk --max-time 15 "http://$DOMAIN/.well-known/acme-challenge/$PROBE" 2>/dev/null || true)"
rm -f "/var/www/html/.well-known/acme-challenge/$PROBE"
[ "$GOT" = "$PROBE" ] || {
    echo "取不到 http://$DOMAIN/.well-known/acme-challenge/ 下的文件，先别申请证书。"
    echo "按这个顺序查：80 端口能不能从公网进来（安全组）→ 域名是不是被别的 server 块抢走"
    echo "（hao-guard.sh vhost-owner）→ snippets/acme-challenge.conf 的 root 是否就是 /var/www/html"
    exit 1
}
```

探测通过了再签：

```bash
# 邮箱：**问用户，不要推导。** 它是 Let's Encrypt 账户的联系地址，
# 用来收吊销通知和账户恢复。从域名拼一个 admin@<域名> 有两个具体的坏处：
#   1. 多级后缀会算错。`awk -F. '{print $(NF-1)"."$NF}'` 对 blog.example.co.uk
#      得到 co.uk —— 那是注册局的域名，等于把账户联系人填成别人；
#   2. 就算算对了，那个信箱多半不存在，通知发进黑洞。
# 用户不想给邮箱是可以的，那就明确地不注册联系方式（下面第二条），
# 而不是编一个。
if [ -n "${ACME_EMAIL:-}" ]; then
    certbot certonly --webroot -w /var/www/html -d "$DOMAIN" \
        --non-interactive --agree-tos -m "$ACME_EMAIL"
else
    certbot certonly --webroot -w /var/www/html -d "$DOMAIN" \
        --non-interactive --agree-tos --register-unsafely-without-email
fi
```

用了 `--register-unsafely-without-email` 要在收尾汇报里说一句：
证书续期照常（`certbot.timer` 不需要邮箱），但**出问题时 Let's Encrypt 联系不到他**。

certbot 2.x 默认就是 ECDSA 密钥，不用额外指定。

**续期不需要 HAO 做任何事**：`certbot.timer` 随包安装并自动启用。但"timer 在跑"
证明不了"续期会成功" —— webroot 变了、challenge 路径被别的 server 块抢走，都会让
它在**60 天后**才失败一次，那时没人在看。用 `--dry-run` 当场证明整条续期路径通，
它走 staging 服务器，不消耗正式速率限制、不动现有证书：

```bash
systemctl list-timers certbot.timer --no-pager        # timer 存在且有下次触发时间
certbot renew --dry-run                                # 必须以 "all simulated renewals succeeded" 结束
```

`--dry-run` 会把这台机器上**所有**证书都模拟一遍（包括别人装的），所以它顺带也验了
存量站点的续期。有哪一张失败就如实报出来是哪一张 —— 那是既有问题，不是这次部署
造成的，但用户需要知道。

续期后重载 Nginx 的 deploy 钩子**由 `nginx` 模块安装**（它对所有证书生效，
不是某个站点专属的），见 `references/nginx.md` 第 4 节。这里只确认它在，并且
真的能跑（钩子里有 `nginx -t`，跑一次是安全的）：

```bash
[ -x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh ] \
    || echo "钩子不在，按 references/nginx.md 第 4 节装上，否则续期后 Nginx 仍用旧证书"
/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh   # 退出码 0 才算这条链路通
```

（`--dry-run` 默认**不执行** deploy 钩子，所以钩子要单独验一次。两件事都验过，
才能对用户说"续期不用你管"。）

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

只有**同时**满足以下五条，`@@PORT80_BODY@@` 才填
`include /etc/nginx/snippets/redirect-to-https.conf;`（跳转）：

1. `cert-issuer` 确认是 `letsencrypt`（真实证书，不是自签名）；
2. 用户没有明确要求关闭跳转；
3. **用户已经确认云服务器安全组/防火墙放行了 443/TCP**；
4. **域名如果走了 CDN，用户已经确认 CDN 到源站也是 HTTPS**（见下面那一节）；
5. **反代的是第三方应用时，这个应用自己的对外协议约束允许 HTTPS**（见下面
   「来源校验教训」——有的应用只接受明文，加跳转会让它拒绝启动）。

五条不全满足就填 `include /etc/nginx/snippets/$CONF_NAME.conf;`（不跳转，
80 直接提供服务）。两种填法都是**一行**，别把跳转那段 location 直接写进模板 ——
占位符的值必须是单行，理由见模板头部。

第 3 条必须真的问一句。很多 VPS 面板默认只开 80，一旦启用跳转，浏览器被 301
到打不通的 443，站点会**完全不可访问**（典型现象：Cloudflare 522 超时）。
这个故障对小白来说极难自查——站点刚才还好好的，配完证书就全白了。

### ⚠️ 来源校验教训：把站点搬到域名上，不等于只改 Nginx

反代一个应用（面板、网关、自建服务）并给它换对外地址时，**它自己也记着旧地址**，
而那些配置不在 Nginx 里。真实踩过一次：把站点从 `http://<IP>` 搬到
`https://<域名>`，首页照常 200，用户一登录就 403「请求来源不受信任」——
应用拿浏览器发的 `Origin` 头和配置里的公开地址做**逐字节**比对，不一致就拒。

要查的东西（各应用叫法不同，按语义找）：公开地址 / 站点 URL、允许来源
（Origin / Referer 白名单）、CORS、OAuth 回调地址、Cookie 的 `Secure` 位、
CSRF 的信任来源、TrustedHost / AllowedHosts。

还有一类更硬的：**启动时的自检门**。有的应用把「对外协议必须是 HTTPS」「必须配置
验证码/签名密钥」写成启动校验，不满足就直接**拒绝启动**。所以顺序是：

1. 先只读地把那批配置和启动校验找出来（读配置模板、启动日志、`*_ORIGIN` 之类的
   环境变量，看它启动时自己打印了什么；`SKILL.md` 的第三方应用清单里有这一条）；
2. 把"改地址会连带改这些"讲给用户，再动手；
3. **改完必须发一次非 GET 请求验证**。

第 3 条是这条教训的核心：**GET 请求一般不做来源校验，所以首页 200 会骗过验证。**
至少打一次注定失败的登录或提交，只要回来的**不是来源 / CSRF 类的 403**，
就说明这一层过了。只验首页等于没验——故障会在用户手里才暴露。

如果应用只接受明文（自检门或来源校验把协议锁死了），就**不要给它加跳转**：
按明文起站，并把原因如实告诉用户。硬上 HTTPS 的结果是服务起不来，比明文更糟。
这台机器上的判断还要看 `PUBLIC_ORIGIN` 与非 HTTPS 的一致性 —— 但结论一样：
**协议由应用决定，不是由我们觉得该怎样决定。**

### 域名走 CDN 时，跳转还要再问一件事

第 1 节讲过"解析到 CDN 的 IP 不算配错，不要停下"。那只是 CDN 带来的**第一个**
影响。第二个在这里：**CDN 到源站用什么协议，决定源站能不能跳转。**

以 Cloudflare 的 SSL/TLS 模式为例：

| CDN→源站 | 源站开 80→443 跳转的后果 |
|---|---|
| Full / Full (strict)（回源走 HTTPS） | 正常。可以开 |
| **Flexible（回源走 HTTP）** | **无限重定向，站点完全打不开**。CDN 用 http 回源 → 源站 301 到 https → CDN 又用 http 回源 → 循环 |

现象和 522 教训一模一样（配完证书站点全白），但原因完全不同，所以两条都要查。
**判断不了就不要开跳转**：不跳转的代价只是少一次跳转，而且 CDN 那边通常已经有
"Always Use HTTPS"可以开，比在源站冒这个风险划算。

用户说不清自己用的是哪个模式时，让他去 CDN 控制台看一眼再回来，不要替他猜 ——
这一条猜错的代价是站点完全不可访问。

自签名证书**永不跳转**，80 端口直接提供服务。

无论是否跳转，`/.well-known/acme-challenge/` 都必须留在 80 上
（模板里的 `include /etc/nginx/snippets/acme-challenge.conf` 已经保证了这点，
而且那个片段用的是 `^~` 前缀匹配，不会被内容块里挡点文件的正则抢走），
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
    cert="$CERT_STATE" \
    acme_email="${ACME_EMAIL:-未注册}"
```

`repo` 里内嵌的凭据会被自动脱敏,不用自己处理。**不要**往里塞任何密钥——
key 名**含有** `password`/`passwd`/`token`/`secret`/`apikey`/`api_key`/`credential`/`private_key`
任一子串的会被直接拒绝（所以 `token_ttl` 这种无害的名字也会被拒，换个词）。
key 还必须**以小写字母开头**，只含小写字母、数字、下划线。
`build_cmd` 两种类型都要记（node 的是装依赖那条命令，重放时缺了它站点起不来），
static 不填 `entry`，node 不填 `output_dir`，留空即可。

### 装了 fail2ban-nginx 的机器：reload 一次

```bash
[ -f /etc/fail2ban/jail.d/hao-nginx.local ] && fail2ban-client reload
```

jail 的 `logpath` 是 glob，**只在 fail2ban 启动/reload 时展开一次**。不 reload
的话，这个新站点的 `access.log` / `error.log` 对两个 jail 都是隐形的——站点看着
一切正常，防扫站却完全没覆盖到它，而且没有任何报错提示。`fail2ban-nginx.md`
把这一步称作"最容易被漏的一步"，所以它在这里，紧挨着 `record`。

reload 之后确认新日志真的进了 jail 的跟踪清单：

```bash
fail2ban-client status hao-nginx-scan | grep -A2 'File list'
```

## 7. 汇报给用户

至少说清这几件事，用普通话而不是路径清单：

- 访问地址（真实证书 `https://域名`；自签名要说明浏览器会告警；无域名给 `http://IP`）
- 是否启用了跳转，以及 443 放行的提醒
- 更新命令：`sudo $ID-update`
- 代码目录 `/opt/$ID`、发布目录 / 服务单元 `$ID.service` 与端口
- 证书由 certbot 自动续期（`certbot.timer`），**不需要他做任何事** ——
  这句话只有在 `certbot renew --dry-run` 通过、且 deploy 钩子跑过一次之后才能说
- node 站点若绑在 `0.0.0.0`，把第 3b 节那段提醒讲给他
- **这次部署改变了什么别的东西**：默认站点变了没有（第 4 节那一步查出来的）、
  为了构建装了什么全局工具（例如 corepack 的 pnpm shim 落在 `/usr/local/bin`）
- 用户仓库里那份为别的机器写的部署文档和实际布局不一致（如果有）
- 只在源站验证通过但公网还打不开时，**说清楚是哪一段不通**，不要报"部署完成"
- **让他把 `/var/lib/hao/DEPLOY-INTENT.md` 存一份到自己的笔记或仓库里**——
  机器销毁后，那是重建这个站点的唯一依据

## 常见问题

- **站点 404**：static 产物目录填错，`ls $DOCROOT` 看是不是空的。
- **站点 403（不是 404）**：文件权限。Nginx 以 `nginx` 用户读 docroot，而
  `cp -a` 保留了仓库里的权限（`umask 077` 下 clone 出来的文件是 0600）。
  `namei -l "$DOCROOT/index.html"` 一路看下来，然后
  `find "$DOCROOT" -type d -exec chmod 755 {} +` 加
  `find "$DOCROOT" -type f -exec chmod 644 {} +`。
- **502 Bad Gateway**：node 服务没起来，看 `journalctl -u $ID.service`。
  最常见的一条是 `Cannot find module '...'` —— 依赖没装（跳过了第 3b 节开头那一步，
  或者更新脚本的 `@@BUILD_CMD@@` 留空了）。补跑 `npm ci --omit=dev` 再 restart，
  并且把更新脚本重新生成一遍，否则下次更新还会这样。
- **构建只输出一行 `Killed`**：被 OOM killer 杀了，不是配置问题。`free -m` 看内存，
  按第 3a 节先跑 `swap` 模块。
- **构建报 `ERR_PNPM_...` / `only-allow` 拦住 / 依赖装了但构建失败**：包管理器用错了。
  按第 3a 节的表重新判一次（`pnpm-lock.yaml` 的仓库必须用 pnpm），改完把更新脚本
  也重新生成一遍。
- **更新脚本卡住不动、日志停在装依赖那一步**：corepack 在等"要不要下载这个版本的
  包管理器"的确认，而无人值守跑没人回答它。构建命令里加
  `COREPACK_ENABLE_DOWNLOAD_PROMPT=0`（见第 3a 节），重新生成更新脚本。
- **配好证书后站点全白 / 522**：跳转启用了但 443 没放行。改成不跳转先恢复可用，
  再让用户去开安全组。
- **`nginx -t` 报找不到 `/etc/letsencrypt/options-ssl-nginx.conf`**：那个文件由
  `python3-certbot-nginx` 提供，而本 skill 不装那个插件，所以**它永远不会出现**。
  说明 vhost 里多了一行不该有的 include——删掉它，TLS 参数在
  `snippets/ssl-hardening.conf` 里。`ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem`
  同理。**这跟证书签没签成功无关**，别去查 certbot。
- **`nginx -t` 报某个 `@@TOKEN@@` 附近语法错误**：占位符没替换完，
  `grep -n '@@[A-Z]' <文件>` 找出来。
- **`nginx -t` 报 `unknown directive "http2"`**：这台机器上的 nginx 早于 1.25.1
  （多半来自发行版仓库，不是本 skill 装的 nginx.org 包）。`@@HTTP2@@` 那一行整行删掉，
  见第 4 节的能力探测。**这跟证书无关**，别去查 certbot。
- **浏览器访问 IP 看到 "Welcome to nginx!"，站点却部署完了**：包自带的
  `/etc/nginx/conf.d/default.conf` 抢了 `:80` 的 default server。按
  `references/nginx.md` 第 3 节末尾把它改名停用，无域名站点的 `@@DEFAULT@@`
  也要填 ` default_server`。
- **`nginx -t` 报 `"return"/"location" directive is not allowed here`**：
  给某个占位符填了**多行**的值。占位符在模板自己的注释头里也出现，整文件替换会把
  多行值的后几行留在注释区外面，变成活配置。所有占位符的值都必须是单行 ——
  两处"块"形态（80 端口跳转、无域名站点的 default_server）都已经设计成一行。
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
