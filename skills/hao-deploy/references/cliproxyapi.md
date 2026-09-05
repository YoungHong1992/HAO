# cliproxyapi —— CliproxyAPI 网关（Docker Compose）

CliproxyAPI，默认 Docker Compose 部署，Nginx 反代 + TLS。

前置：`docker`、`nginx`。

## 0. 要问清的

| 要素 | 说明 |
|---|---|
| 域名 | 必填 |
| 管理面板密码 | 建议**留空**让它自动生成，只落到凭据文件 |
| 镜像 tag | 默认用 `references/images.md` 的固定 tag |

管理密码**绝不要**通过命令行参数传入——`ps` 和 `/proc/<pid>/cmdline` 对同机
任意用户可见。用户自带密码就写进文件，用 `@file:` 读入。

## 1. 前置检查

```bash
"$SKILL/scripts/hao-guard.sh" vhost-owner "$DOMAIN"
"$SKILL/scripts/hao-guard.sh" port-free 8317
docker compose version
[ -d /opt/docker-services/cliproxyapi ] && ls /opt/docker-services/cliproxyapi
```

已有部署时默认不动，先问用户意图（同 `references/new-api.md` 第 1 节的表）。
升级只换镜像 tag，**复用现有 config.yaml 里的密钥**。

## 2. 生成凭据

```bash
"$SKILL/scripts/hao-secret.sh" write /etc/hao/cliproxyapi.env \
    ADMIN_SECRET=@password API_KEY_1=@apikey API_KEY_2=@apikey

# 用户自带管理密码时：
#   ADMIN_SECRET=@file:/path/to/password.txt
```

重跑复用已有值，所以重新部署不会换掉用户已经在用的 API key。

## 3. 渲染配置并启动

```bash
install -d -m 0755 /opt/docker-services/cliproxyapi
cd /opt/docker-services/cliproxyapi
install -d -m 0755 auths logs

# config.yaml 含 API key 与管理密码，必须 0600
"$SKILL/scripts/hao-secret.sh" render \
    "$SKILL/templates/cliproxyapi-config.yaml" \
    /opt/docker-services/cliproxyapi/config.yaml \
    --from /etc/hao/cliproxyapi.env --mode 0600

# compose 不含密钥，直接复制并填 @@IMAGE@@
```

然后 `docker compose up -d`。

## 4. 等真正就绪

```bash
for _ in $(seq 1 30); do
    timeout 2 bash -c ">/dev/tcp/127.0.0.1/8317" 2>/dev/null && break
    sleep 2
done
docker compose ps
docker compose logs --tail=50 cliproxyapi     # 起不来就看这个
```

## 5. Nginx 反代

同 `references/site.md` 第 4 节，端口 8317，`@@SITE_ID@@` 用 `cliproxyapi`。
跳转的三个前提同样适用。

容器端口一律绑 `127.0.0.1`（模板里已经是），对外只走 Nginx。
那几个 OAuth 回调端口（8085/1455/54545/51121/11451）也只绑本机，
不要暴露到公网。

## 6. 记录状态

```bash
"$SKILL/scripts/hao-state.sh" record cliproxyapi installed \
    managed:/opt/docker-services/cliproxyapi/docker-compose.yml \
    managed:/etc/nginx/conf.d/hao-cliproxyapi.conf \
    managed:/etc/nginx/hao-cliproxyapi-body.conf \
    secret:/opt/docker-services/cliproxyapi/config.yaml \
    secret:/etc/hao/cliproxyapi.env \
    observed:/opt/docker-services/cliproxyapi/auths
"$SKILL/scripts/hao-state.sh" handoff
```

`config.yaml` 记 `secret`：里面有 API key 和管理密码。
`auths/` 记 `observed`：OAuth 凭据由用户在面板里登录产生。

## 汇报给用户

访问地址、管理面板入口、凭据文件路径（**不打印内容**）、
以及"要在面板里登录各个上游账号才能真正用起来"。

## 常见问题

- **面板打不开**：Nginx 反代没配好，或者容器没起来。
- **API 返回 401**：客户端用的 key 不在 `config.yaml` 的 `api-keys` 里。
  用 `hao-secret.sh keys /etc/hao/cliproxyapi.env` 看有哪些 key 名，
  **不要打印值**；让用户自己去凭据文件里取。
- **上游账号掉登录**：`auths/` 里的凭据过期，用户需要重新在面板登录。
- **升级后密钥变了**：说明有人加了 `--rotate` 或删过凭据文件。
