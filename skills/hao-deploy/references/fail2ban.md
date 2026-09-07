# fail2ban —— SSH 防爆破

新买的机器暴露在公网上，SSH 每天会被扫上千次。fail2ban 读 SSH 日志，把反复
失败的 IP 临时封掉。这件事和 `swap`、`journald` 互相独立，任何一件失败都不
影响其他两件，但都要如实汇报。

## 1. 前置检查（只读）

```bash
"$SKILL/scripts/hao-guard.sh" managed-file /etc/fail2ban/jail.d/hao-sshd.local
command -v fail2ban-client >/dev/null && fail2ban-client --version
```

jail 文件已存在且返回 `foreign` → **拒绝覆盖**，把路径报给用户。那可能是他自己
或另一个工具配的，覆盖会改掉他的封禁策略。

## 2. 探测真实 SSH 端口

**这一步不能跳过，也不能写死 22。** 用户改过 SSH 端口的情况很常见，端口写错的
后果是防护形同虚设（真实端口没人看着），或者反过来把用户自己关在门外。

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

`sshd -T` 排第一，因为它给的是 sshd 自己算出来的最终配置。直接读配置文件会漏掉
`Include`、drop-in、以及被后面的行覆盖掉的项。

## 3. 安装并写 jail

```bash
export DEBIAN_FRONTEND=noninteractive
command -v fail2ban-client >/dev/null || { apt-get update -y && apt-get install -y fail2ban; }
mkdir -p /etc/fail2ban/jail.d
# 写 templates/fail2ban-sshd.local → /etc/fail2ban/jail.d/hao-sshd.local
# @@SSH_PORTS@@ 换成上一步探测到的 $SSH_PORTS
systemctl enable fail2ban
systemctl restart fail2ban
```

## 4. 验证

```bash
fail2ban-client status sshd        # 必须列出 jail 状态
```

**配置写对不代表 jail 起来了** —— filter 名不对、backend 不被支持、日志读不到，
都会让 jail 静默缺失。状态取不到就如实说「已配置但 sshd jail 未就绪」，
别报成功。

## 5. 记录状态

```bash
"$SKILL/scripts/hao-state.sh" record fail2ban installed \
    managed:/etc/fail2ban/jail.d/hao-sshd.local
"$SKILL/scripts/hao-state.sh" intent fail2ban \
    ssh_ports="$SSH_PORTS" maxretry=5 bantime=1h
"$SKILL/scripts/hao-state.sh" handoff
```

只记我们写的那个 drop-in。`/etc/fail2ban/jail.conf` 是包自带的主配置，我们不碰
也不记。

## 不要顺手做的事

**不改 SSH 端口、不禁用密码登录、不改防火墙默认策略。** 这几件都会影响用户自己
登录的能力，而他没有第二条路进来。完整清单见 `references/safety.md`
「不该做的事」。用户明确要求某一件时再单独做，并先确认他有救援控制台。

封禁参数在模板里（`maxretry = 5`、`bantime = 1h`）。用户嫌不够严就改模板值重写，
但不要改成 `bantime = -1` —— 永久封禁意味着他自己输错几次密码就再也进不来。
