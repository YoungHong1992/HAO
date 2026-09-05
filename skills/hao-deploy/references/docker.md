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

Docker 默认不轮转容器日志，磁盘写爆是常见事故。如果这台机器还没做过
`maintenance`，至少把日志轮转补上——见 `references/maintenance.md` 第 4 节
（**合并**写入 `daemon.json`，不要整体覆盖）。

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

## 常见问题

- **`docker compose` 说找不到命令**：装的是旧的 `docker-compose`（独立二进制）
  或者 compose 插件缺失。补装 `docker-compose-plugin`。本 skill 一律用
  `docker compose`（带空格）这种插件写法。
- **拉镜像超时**：国内机器常见。让用户自己决定是否配镜像加速——那要改
  `daemon.json`，同样必须合并写入。
- **`permission denied` 连不上 docker.sock**：当前用户不在 docker 组，
  或者加了组但没重新登录。
