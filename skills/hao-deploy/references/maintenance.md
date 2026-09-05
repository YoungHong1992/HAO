# maintenance —— 服务器基础加固

新买的机器先做这一步：SSH 防爆破、swap 兜底、日志不写爆磁盘。四件事互相独立，
任何一件失败都不影响其他三件，但都要如实汇报。

## 1. fail2ban（SSH 防护）

**先探测真实 SSH 端口**，写死 22 会让防护失效（用户改过端口的情况很常见）：

```bash
# 首选：读 sshd 最终生效配置
SSH_PORTS="$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | sort -n -u | paste -sd, -)"

# 退回读配置文件（含 drop-in 目录）
[ -n "$SSH_PORTS" ] || SSH_PORTS="$(grep -hE '^[[:space:]]*Port[[:space:]]+[0-9]+' \
    /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null \
    | awk '{print $2}' | sort -n -u | paste -sd, -)"

# 最后兜底
[ -n "$SSH_PORTS" ] || SSH_PORTS=22
```

装包并写 jail（模板 `templates/maintenance-fail2ban-sshd.local` → `/etc/fail2ban/jail.d/hao-sshd.local`）：

```bash
export DEBIAN_FRONTEND=noninteractive
command -v fail2ban-client >/dev/null || { apt-get update -y && apt-get install -y fail2ban; }
mkdir -p /etc/fail2ban/jail.d
# ... 写模板，@@SSH_PORTS@@ 替换成上面探测到的值 ...
systemctl enable fail2ban
systemctl restart fail2ban
```

验证（**这一步不能省**，配置写对不代表 jail 起来了）：

```bash
fail2ban-client status sshd
```

jail 状态取不到就如实说"已配置但 sshd jail 未就绪"，别报成功。

## 2. swap

决策规则（先看有没有活动 swap，有就别碰）：

```bash
swapon --show=NAME --noheadings | grep -q . && echo "已有活动 swap，跳过"
MEM_MB="$(awk '/MemTotal/ {print int(($2 + 1023) / 1024)}' /proc/meminfo)"
```

| 内存 | swap 大小 |
|---|---|
| ≤ 2048 MB | 2048 MB |
| ≤ 4096 MB | 4096 MB |
| > 4096 MB | 问用户要不要，默认不建 |

创建（`/swapfile` 已存在但不是 swap 文件时改用 `/swapfile.hao`，**不要覆盖**）：

```bash
SWAP=/swapfile
[ -e "$SWAP" ] && ! file "$SWAP" | grep -qi swap && SWAP=/swapfile.hao

fallocate -l "${SIZE_MB}M" "$SWAP" || dd if=/dev/zero of="$SWAP" bs=1M count="$SIZE_MB" status=none
chmod 600 "$SWAP"          # 权限必须 600，swap 内容可能含内存里的敏感数据
mkswap "$SWAP" >/dev/null
swapon "$SWAP"

# 持久化（先查重，别重复追加）
grep -qsE "^[[:space:]]*${SWAP}[[:space:]]+" /etc/fstab \
    || echo "$SWAP none swap sw 0 0" >> /etc/fstab
```

再写 `templates/maintenance-swap-sysctl.conf` → `/etc/sysctl.d/99-hao-swap.conf`，
然后 `sysctl -p`。验证：`swapon --show`。

## 3. journald 日志上限

`templates/maintenance-journald.conf` → `/etc/systemd/journald.conf.d/hao.conf`，
然后 `systemctl restart systemd-journald`。验证：`journalctl --disk-usage`。

## 4. Docker 日志轮转

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

Docker 还没装：直接写文件即可（模板 `templates/docker-daemon-logrotate.json`），
配置会在 Docker 安装后生效。

**重启 Docker 要看有没有运行中的容器**：

```bash
docker ps -q 2>/dev/null
```

有容器在跑就**先问用户**——重启 Docker 会中断所有容器。用户不同意就说明
"配置已写入，下次重启 Docker 后生效"。这不是失败。

## 5. 记录状态

```bash
"$SKILL/scripts/hao-state.sh" record maintenance installed \
    managed:/etc/fail2ban/jail.d/hao-sshd.local \
    managed:/etc/systemd/journald.conf.d/hao.conf \
    managed:/etc/sysctl.d/99-hao-swap.conf \
    shared:/etc/docker/daemon.json \
    shared:/etc/fstab
"$SKILL/scripts/hao-state.sh" handoff
```

`daemon.json` 和 `fstab` 记 `shared` 而不是 `managed`：我们只改了其中一部分，
下一个 agent 不能整体重写它们。

## 检查命令（给用户留一份）

```bash
fail2ban-client status sshd
swapon --show
journalctl --disk-usage
cat /etc/docker/daemon.json
```

## 不要做的事

- 不要改 SSH 端口、不要禁用密码登录、不要改防火墙默认策略。这些会把用户
  锁在门外，而且他没有第二条路进来。用户明确要求时再单独做，并先确认他有
  救援控制台。
- 不要因为"顺手"就 `apt upgrade` 全系统。
