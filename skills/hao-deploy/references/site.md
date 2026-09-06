# site —— 从 Git 仓库部署自有站点

这是小白用户最常走的一条链路：给一个仓库地址和域名，得到一个能访问的网站。
支持两种类型：`static`（构建产物直接由 Nginx 提供）和 `node`（起一个 Node
进程，Nginx 反代）。

前置：Nginx 已装（见 `references/nginx.md`）、`git` 可用；node 类型还需要
`node` 在 `/usr/bin` 或 `/usr/local/bin`（见 `references/node.md`）。

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

**同一台机器只能有一个无域名的默认站点**（`server_name _`）。已经有一个了，
就必须给新站点一个域名。

## 1. 前置检查（只读）

```bash
"$SKILL/scripts/hao-guard.sh" vhost-owner "$DOMAIN"      # 域名是否被占
"$SKILL/scripts/hao-guard.sh" repo-identity /opt/hao-sites/$ID "$REPO"
"$SKILL/scripts/hao-guard.sh" cert-issuer /etc/nginx/ssl/$DOMAIN/fullchain.pem
```

**`vhost-owner` 的判断规则（最重要的一道闸）**：

| 输出 | 含义 | 该怎么做 |
|---|---|---|
| `free` | 没人占用 | 继续 |
| `hao-site <本站ID> <path>` | 本站点自己的配置 | 继续，原地更新 |
| `hao-site <别的ID> <path>` | 另一个 HAO 站点占用了这个域名 | **停下**，让用户换域名 |
| `hao <service> <path>` | 别的 HAO 服务占用 | **停下**，让用户换域名 |
| `foreign <path>` | 非 HAO 管理的配置占用 | **停下**，绝不覆盖，报告路径 |

`repo-identity` 的判断规则：

- `absent`：目录不存在，正常克隆。
- `ok`：已是同一仓库的检出，走更新流程。
- `not-git`：目录存在但不是 Git 检出 → **停下**，报告路径让用户处理，不要
  `rm -rf`。里面可能是用户自己放的东西。
- `remote-mismatch <脱敏地址>`：同名目录指向别的仓库 → **停下**。要换仓库
  必须由用户确认后手工移除目录。

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
install -d -m 0755 /opt/hao-sites
# 首次克隆
install -d -m 0755 -o "$USER" -g "$GROUP" "/opt/hao-sites/$ID"
runuser -u "$USER" -- env HOME="$HOME_DIR" \
    git clone --branch "$BRANCH" "$REPO" "/opt/hao-sites/$ID"

# 已存在（repo-identity == ok）则更新
runuser -u "$USER" -- env HOME="$HOME_DIR" git -C "$DIR" fetch --prune origin
runuser -u "$USER" -- env HOME="$HOME_DIR" git -C "$DIR" checkout -f -B "$BRANCH" "origin/$BRANCH"
runuser -u "$USER" -- env HOME="$HOME_DIR" git -C "$DIR" reset --hard "origin/$BRANCH"
```

克隆失败要把半成品目录删掉再报错，不要留下空目录（下次重跑会被误判为已存在）。

**仓库地址可能内嵌凭据**（`https://user:token@github.com/...`）。在对话、日志、
报错里一律用脱敏形式：`sed -E 's#(://)[^/@]+@#\1***@#'`。

## 3a. static 类型：构建与发布

```bash
# 构建（以目标用户执行，CI=true 让多数前端工具进入非交互模式）
runuser -u "$USER" -- env HOME="$HOME_DIR" CI=true \
    bash -c "cd /opt/hao-sites/$ID && $BUILD_CMD"

# 发布
install -d -m 0755 "/var/www/hao-sites/$ID"
find "/var/www/hao-sites/$ID" -mindepth 1 -delete     # 清旧产物，避免删掉的文件残留
cp -a "/opt/hao-sites/$ID/$OUTPUT/." "/var/www/hao-sites/$ID/"
[ "$OUTPUT" = "." ] && rm -rf "/var/www/hao-sites/$ID/.git"   # 别把 .git 发到公网
chown -R "$USER:$GROUP" "/var/www/hao-sites/$ID"
chmod 755 "/var/www/hao-sites/$ID"
```

产物目录不存在就停下来报错，并把 `构建命令 / 产物目录` 两个值回显给用户核对
——这是最常见的配置错误。产物目录必须是克隆目录内的相对路径，含 `..` 或绝对
路径一律拒绝。

## 3b. node 类型：systemd 服务

端口分配（**幂等关键**）：用户没指定端口时，先从既有单元里读回来复用，
避免每次重跑都换端口：

```bash
PORT="$("$SKILL/scripts/hao-guard.sh" unit-port "/etc/systemd/system/hao-site-$ID.service")"
# 读不到再从 8100 起找第一个空闲端口
[ -n "$PORT" ] || for p in $(seq 8100 8200); do
    [ "$("$SKILL/scripts/hao-guard.sh" port-free "$p")" = free ] && { PORT="$p"; break; }
done
```

同一批部署的多个站点之间也不能撞端口，自己记账。

然后用 `templates/site-node.service` 生成单元文件：

- `@@NODE_BIN@@` 用 `command -v node` 的结果（绝对路径，systemd 没有 PATH 继承）
- **权限必须 0640**：额外环境变量可能含敏感值
- 不要在 `@@EXTRA_ENV@@` 里设 `PORT`，端口由专门的字段控制

```bash
chmod 0640 "/etc/systemd/system/hao-site-$ID.service"
systemctl daemon-reload
systemctl enable "hao-site-$ID.service"
systemctl restart "hao-site-$ID.service"
```

启动后**必须确认端口真的在监听**（服务 active 不等于应用起来了）：

```bash
for _ in $(seq 1 15); do
    timeout 2 bash -c ">/dev/tcp/127.0.0.1/$PORT" 2>/dev/null && { echo ready; break; }
    sleep 2
done
```

30 秒内没起来就停下来，把 `journalctl -u hao-site-$ID.service -n 50` 的输出
给用户，不要继续往下写 Nginx 配置。

## 4. Nginx 配置与证书

顺序很重要：**先让站点在 HTTP 上活起来，再申请证书**。这样 ACME 的 HTTP 校验
路径天然可达，不需要临时配置腾挪。

**第一步**：写内容块和 HTTP 版 vhost。

- `templates/site-body-static.conf` 或 `site-body-node.conf`
  → `/etc/nginx/hao-site-$ID-body.conf`
- `templates/site-vhost-http.conf` → `/etc/nginx/conf.d/hao-site-$ID.conf`
  （无域名时 `@@SERVER_NAME@@` 填 `_`）

写之前备份，`nginx -t` 失败要能回滚：

```bash
CONF="/etc/nginx/conf.d/hao-site-$ID.conf"
BAK=""
[ -f "$CONF" ] && { BAK="$CONF.bak.$(date +%Y%m%d_%H%M%S)"; cp -a "$CONF" "$BAK"; }
# ... 写入 ...
if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx || systemctl start nginx
else
    nginx -t 2>&1            # 原始输出给用户看
    [ -n "$BAK" ] && cp -a "$BAK" "$CONF" || rm -f "$CONF"
    nginx -t >/dev/null 2>&1 && systemctl reload nginx
    # 停下来报错，不要继续
fi
```

无域名或 `CERT=no` 的站点到这里就结束了，跳到第 5 步。

**第二步**：申请证书。已有真实证书就不要重复申请
（`cert-issuer` 返回 `letsencrypt` 即跳过；返回 `selfsigned` 说明上次是兜底的，
可以重试真实申请）。

```bash
# acme.sh 的账户邮箱不能是 example.com / localhost / test.com 这类占位域名，
# 否则 Let's Encrypt 会拒绝注册。用主域名推导一个：
MAIN="$(echo "$DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')"
EMAIL="admin@$MAIN"

[ -f ~/.acme.sh/acme.sh ] || curl -s --connect-timeout 10 https://get.acme.sh | sh -s email="$EMAIL"

mkdir -p /var/www/acme && chmod 755 /var/www/acme
mkdir -p "/etc/nginx/ssl/$DOMAIN"

~/.acme.sh/acme.sh --issue --server letsencrypt -d "$DOMAIN" \
    --webroot /var/www/acme --keylength ec-256

~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
    --key-file       "/etc/nginx/ssl/$DOMAIN/key.pem" \
    --fullchain-file "/etc/nginx/ssl/$DOMAIN/fullchain.pem" \
    --reloadcmd      "systemctl reload nginx"

chmod 600 "/etc/nginx/ssl/$DOMAIN/key.pem"
chmod 644 "/etc/nginx/ssl/$DOMAIN/fullchain.pem"
```

申请失败时降级为自签名（站点仍可用，只是浏览器告警），并**如实告诉用户这是
自签名证书**，不要说成"证书已配置好"：

```bash
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "/etc/nginx/ssl/$DOMAIN/key.pem" \
    -out "/etc/nginx/ssl/$DOMAIN/fullchain.pem" \
    -subj "/CN=$DOMAIN" -addext "subjectAltName=DNS:$DOMAIN"
```

**第三步**：改写成 TLS 版 vhost（`templates/site-vhost-tls.conf`），同样是
备份 → 写入 → `nginx -t` → reload/回滚。

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
（模板里的 `include /etc/nginx/hao-acme-location.conf` 已经保证了这点），
否则证书续期会失败。

## 5. 生成更新脚本

用 `templates/site-update-static.sh.tmpl` 或 `site-update-node.sh.tmpl`
生成 `/usr/local/bin/hao-site-update-$ID`，权限 0755。

脚本内嵌解析后的字面量，不依赖本 skill，用户之后自己 `sudo hao-site-update-$ID`
就能更新站点。值里含单引号要转义成 `'\''`。

## 6. 记录状态并交接

```bash
"$SKILL/scripts/hao-state.sh" record "site-$ID" installed \
    managed:/etc/nginx/conf.d/hao-site-$ID.conf \
    managed:/etc/nginx/hao-site-$ID-body.conf \
    managed:/usr/local/bin/hao-site-update-$ID \
    observed:/opt/hao-sites/$ID
# node 类型再加：managed:/etc/systemd/system/hao-site-$ID.service
"$SKILL/scripts/hao-state.sh" handoff
```

**service ID 必须是 `site-$ID` 而不是 `site`。** `record` 对一个 service ID 只保留
一条记录，是整体替换而不是追加。一台机器上部署第二个站点时，如果两次都记成
`site`，第一个站点的资源会静默从状态里消失——它的 nginx 配置、更新脚本从此
不再被 `drift` 检查，`HANDOFF.md` 里也只剩一行。这类丢失通常要等到有人手工改坏
了那个站点、而 `drift` 一声不响时才被发现。

克隆目录记 `observed` 而不是 `managed`：里面的内容由用户的仓库决定，每次
更新都会变，记 managed 会让 `drift` 天天误报。

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
    run_user="$USER" \
    cert="$CERT_STATE"
```

`repo` 里内嵌的凭据会被自动脱敏,不用自己处理。**不要**往里塞任何密钥——
key 名带 `password`/`token`/`secret` 之类的会被直接拒绝。
node 类型不填 `build_cmd`/`output_dir`，static 类型不填 `entry`，留空即可。

## 7. 汇报给用户

至少说清这几件事，用普通话而不是路径清单：

- 访问地址（真实证书 `https://域名`；自签名要说明浏览器会告警；无域名给 `http://IP`）
- 是否启用了跳转，以及 443 放行的提醒
- 更新命令：`sudo hao-site-update-$ID`
- 代码目录、发布目录 / 服务单元与端口
- **让他把 `/var/lib/hao/DEPLOY-INTENT.md` 存一份到自己的笔记或仓库里**——
  机器销毁后，那是重建这个站点的唯一依据

## 常见问题

- **站点 404**：static 产物目录填错，`ls /var/www/hao-sites/$ID` 看是不是空的。
- **502 Bad Gateway**：node 服务没起来，看 `journalctl -u hao-site-$ID.service`。
- **配好证书后站点全白 / 522**：跳转启用了但 443 没放行。改成不跳转先恢复可用，
  再让用户去开安全组。
- **证书申请失败**：先查 DNS 是否指向本机、80 是否可从公网访问、域名是否被
  另一个 server 块抢走（`hao-guard.sh vhost-owner`）。
- **重跑一次端口变了**：没有先用 `unit-port` 读回既有端口。
- **`drift` 不检查某个站点**：那个站点的状态被后来部署的站点覆盖了——两次都记成
  了 `site` 而不是 `site-<id>`。重跑一次 `record "site-$ID" ...` 补回来。
