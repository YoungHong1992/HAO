# new-api —— 模型网关（Docker Compose）

New-API 模型网关，Docker Compose 部署，Nginx 反代 + TLS。

前置：`docker`、`nginx`（见各自 reference）。

## 0. 要问清的

| 要素 | 说明 |
|---|---|
| 域名 | 必填。这是对外服务，需要 TLS |
| 数据库 | `postgresql`（默认）或 `mysql`。**装好后不可切换** |
| 镜像 tag | 默认用 `references/images.md` 里评审过的固定 tag |

## 1. 前置检查

```bash
"$SKILL/scripts/hao-guard.sh" vhost-owner "$DOMAIN"      # 必须 free 或本服务自己
"$SKILL/scripts/hao-guard.sh" port-free 3000
docker compose version
[ -d /opt/docker-services/new-api ] && ls /opt/docker-services/new-api
```

**已有部署时的默认动作是「什么都不做」。** New-API 在跑着就先问用户到底想干什么：

| 用户想要 | 动作 |
|---|---|
| 就是确认一下装没装 | 只汇报状态，不动 |
| 升级到新镜像 | 换 image tag，**复用现有密钥**，`docker compose up -d` |
| 换数据库引擎 | **拒绝**。见下 |

### 为什么拒绝换引擎

PostgreSQL → MySQL 不是升级，数据不会自动迁移。如果照常部署，用户会得到一个
**空的**新数据库，而旧数据还在原来的 volume 里——看起来像"升级后数据全没了"。
HAO 拒绝把空库当成迁移结果。用户确实要换：让他先自己导出数据，
明确确认放弃现有库，然后当成全新部署来做。

## 2. 生成凭据

```bash
"$SKILL/scripts/hao-secret.sh" write /etc/hao/new-api.env \
    DB_PASSWORD=@password SESSION_SECRET=@session
```

重跑时默认复用已有值——这就是"升级不会换掉线上密码"的保证。
生成的密码是纯字母数字，不含 `@` `/` `:`，所以可以安全放进数据库 DSN。

## 3. 渲染 compose 并启动

```bash
install -d -m 0755 /opt/docker-services/new-api
cd /opt/docker-services/new-api

# 按数据库选择模板，用 render 注入密钥（值不进对话）
"$SKILL/scripts/hao-secret.sh" render \
    "$SKILL/templates/new-api-compose-postgres.yml" \
    /opt/docker-services/new-api/docker-compose.yml \
    --from /etc/hao/new-api.env --mode 0600
```

`@@IMAGE@@` 要先替换成实际 tag（`render` 只处理凭据 key，镜像 tag 由你填）。

```bash
docker compose up -d
```

## 4. 等真正就绪

容器 Up **不等于**应用起来了。等端口 + 等健康检查：

```bash
for _ in $(seq 1 30); do
    timeout 2 bash -c ">/dev/tcp/127.0.0.1/3000" 2>/dev/null && break
    sleep 2
done
docker compose ps                       # 看 (healthy)
curl -fsS http://127.0.0.1:3000/api/status >/dev/null && echo "API 就绪"
```

起不来就 `docker compose logs --tail=50 new-api`，把原始日志给用户，
不要继续配 Nginx。

## 5. Nginx 反代

和 `references/site.md` 第 4 节同一套流程和同一批模板：
先写 HTTP vhost 让它活起来 → 申请证书 → 改写成 TLS vhost。
内容块用 node 版模板（`templates/site-body-node.conf`），把端口填 3000，
`@@SITE_ID@@` 用 `new-api`。

**80→443 跳转的三个前提同样适用**（真实证书 + 用户没关 + 443 已放行）。
详见 `references/site.md` 的 522 教训。

## 6. 记录状态

```bash
"$SKILL/scripts/hao-state.sh" record new-api installed \
    managed:/opt/docker-services/new-api/docker-compose.yml \
    managed:/etc/nginx/conf.d/hao-new-api.conf \
    managed:/etc/nginx/hao-new-api-body.conf \
    secret:/etc/hao/new-api.env \
    observed:/opt/docker-services/new-api/data
"$SKILL/scripts/hao-state.sh" handoff
```

## 汇报给用户

访问地址、管理员初始化流程（首次访问 Web 界面自行设置管理员）、
凭据文件路径（**不打印内容**）、以及"数据在 docker volume 里，
销毁机器前要自己导出"。

## 常见问题

- **502**：容器没起来或还没就绪。`docker compose ps` + `logs`。
- **数据库连不上**：DSN 里的密码含特殊字符。用 `hao-secret.sh` 生成的
  纯字母数字密码不会有这问题；用户自带密码就可能有。
- **重启后数据没了**：volume 被删过，或者用户改了 compose 的 volume 名。
- **改了 compose 没生效**：要 `docker compose up -d` 重建，不是 `restart`。
