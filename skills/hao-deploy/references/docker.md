# docker —— Docker Engine 与 Compose 插件

从 Docker 官方仓库安装，不要用发行版自带的 `docker.io`（版本旧、缺
compose 插件）。

## 1. 前置检查

```bash
"$SKILL/scripts/hao-guard.sh" os-supported
command -v docker >/dev/null && docker --version
systemctl is-active docker 2>/dev/null || true
docker compose version 2>/dev/null || true
```

**已装且能用就不要重装**。只在以下情况动手：

- 没有 `docker` 命令 → 完整安装
- 有 `docker` 但服务没起来 → `systemctl enable --now docker`
- 有 `docker` 但没有 compose 插件 → 只补装 `docker-compose-plugin`

## 2. 安装

```bash
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg

install -m 0755 -d /etc/apt/keyrings
. /etc/os-release      # $ID 是 debian 或 ubuntu
curl -fsSL --connect-timeout 30 "https://download.docker.com/linux/$ID/gpg" \
    | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

printf '# Managed by HAO\n# Service: docker\ndeb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n' \
    "$(dpkg --print-architecture)" "$ID" "$VERSION_CODENAME" \
    > /etc/apt/sources.list.d/docker.list

apt-get update -qq
apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker
```

### apt 源坏掉时

老 Debian（buster/bullseye）常见 `apt-get update` 失败，因为安全源路径变了或
已归档。先备份 `/etc/apt/sources.list`，再按实际报错处理：

- `security.debian.org <codename>/updates` → 改成 `security.debian.org/debian-security <codename>-security`
- buster 已归档 → `deb.debian.org` 换成 `archive.debian.org`，并删掉 `buster-updates` 行

改完仍失败就 `apt-get clean && rm -rf /var/lib/apt/lists/* && apt-get update`。
还是不行就停下来把原始报错给用户，不要盲目 `--force-yes`。

## 3. 验证

```bash
docker --version
docker compose version          # 必须有输出，否则 compose 插件没装上
systemctl is-active docker
docker run --rm hello-world     # 真正跑一个容器，比 --version 更有说服力
```

## 4. 日志轮转

Docker 默认不轮转容器日志，磁盘写爆是常见事故。

**关键：不能整体覆盖 `/etc/docker/daemon.json`。** 里面可能有用户的镜像加速、
私有仓库、存储驱动配置，覆盖掉会让 Docker 起不来或拉不到镜像。

必须先备份，再**合并**（只改 `log-driver` 和 `log-opts` 两个键）：

```bash
mkdir -p /etc/docker
DAEMON=/etc/docker/daemon.json
[ -f "$DAEMON" ] && cp -a "$DAEMON" "$DAEMON.bak.$(date +%Y%m%d_%H%M%S)"

python3 - "$DAEMON" <<'PY'
import json, os, sys
path = sys.argv[1]
data = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)          # 解析失败就抛错，别猜
if not isinstance(data, dict):
    raise SystemExit("daemon.json 根节点必须是对象")
data["log-driver"] = "json-file"
opts = data.get("log-opts")
if not isinstance(opts, dict):
    opts = {}
opts["max-size"] = "50m"
opts["max-file"] = "3"
data["log-opts"] = opts
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
```

已有 `daemon.json` 不是合法 JSON：**恢复备份并跳过**，把情况告诉用户。
不要试图修好用户的 JSON。

目标值的权威来源是 `templates/docker-daemon-logrotate.json`。Docker 还没装的
机器上直接把那份模板写进去也可以，配置会在 Docker 安装后生效。

**重启 Docker 之前看有没有运行中的容器**：

```bash
docker ps -q 2>/dev/null
```

有容器在跑就**先问用户**——重启 Docker 会中断所有容器。用户不同意就说明
「配置已写入，下次重启 Docker 后生效」。**这不是失败**，照实说就行。

验证：

```bash
cat /etc/docker/daemon.json                        # 用户原有的键还在
docker info --format '{{.LoggingDriver}}'          # 重启过才会变
```

## 5. 把用户加进 docker 组（可选，要讲清风险）

```bash
usermod -aG docker "$USER"
```

必须告诉用户：**docker 组等价于 root**（能挂载宿主任意目录进容器）。
只在这是他自己的机器、且他理解这一点时才做。加组后需要重新登录才生效。

## 6. 记录状态

```bash
"$SKILL/scripts/hao-state.sh" record docker installed \
    managed:/etc/apt/sources.list.d/docker.list \
    managed:/etc/apt/keyrings/docker.gpg \
    shared:/etc/docker/daemon.json
"$SKILL/scripts/hao-state.sh" handoff
```

`daemon.json` 记 `shared` 而不是 `managed`：我们只改了其中的 `log-driver` /
`log-opts`，下一个 agent 不能整体重写它。

## 常见问题

- **`docker compose` 说找不到命令**：装的是旧的 `docker-compose`（独立二进制）
  或者 compose 插件缺失。补装 `docker-compose-plugin`。本 skill 一律用
  `docker compose`（带空格）这种插件写法。
- **拉镜像超时**：国内机器常见。让用户自己决定是否配镜像加速——那要改
  `daemon.json`，同样必须合并写入。
- **`permission denied` 连不上 docker.sock**：当前用户不在 docker 组，
  或者加了组但没重新登录。
