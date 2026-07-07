# Maintenance 服务器维护基线

> **部署方式**: Bash + systemd 配置
> **内容**: fail2ban + swap + journald 日志限制 + Docker 日志轮转
> **适用场景**: 云服务器首装基础维护

---

## 简介

Maintenance 是 HAO 的服务器基础维护组件，用于在部署 AI 服务前先完成常见的安全和稳定性配置。

包含：

- `fail2ban`：默认启用 SSH 防暴力破解
- `swap`：低内存 VPS 自动创建 swap
- `journald`：限制系统日志占用
- `Docker` 日志轮转：限制容器 json-file 日志无限增长

---

## 快速部署

```bash
cd maintenance
chmod +x install.sh
sudo ./install.sh
```

也可以从根目录总入口选择 `Maintenance`：

```bash
sudo ./install.sh
```

---

## 默认策略

### fail2ban

配置文件：

```text
/etc/fail2ban/jail.d/hao-sshd.local
```

默认规则：

```text
maxretry = 5
findtime = 10m
bantime  = 1h
```

脚本会自动检测 SSH 端口。

### swap

如果系统已有活动 swap，则跳过创建。

无 swap 时默认策略：

| 内存 | swap |
|------|------|
| ≤ 2GB | 2GB |
| 2GB ~ 4GB | 4GB |
| > 4GB | 交互确认，非交互模式默认跳过 |

可通过环境变量指定大小：

```bash
sudo HAO_SWAP_SIZE_MB=2048 ./install.sh
```

跳过 swap：

```bash
sudo HAO_DISABLE_SWAP=1 ./install.sh
```

### journald 日志限制

配置文件：

```text
/etc/systemd/journald.conf.d/hao.conf
```

默认限制：

```ini
[Journal]
SystemMaxUse=500M
RuntimeMaxUse=100M
MaxRetentionSec=14day
```

### Docker 日志轮转

配置文件：

```text
/etc/docker/daemon.json
```

默认配置：

```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  }
}
```

如果 Docker 未安装，会先预置配置，后续 Docker 安装后生效。

如果 Docker 已运行且存在运行中的容器，默认不会强制重启 Docker。可手动重启：

```bash
systemctl restart docker
```

或强制脚本重启 Docker：

```bash
sudo HAO_RESTART_DOCKER=1 ./install.sh
```

---

## 检查命令

```bash
fail2ban-client status sshd
swapon --show
journalctl --disk-usage
cat /etc/docker/daemon.json
```

---

**最后更新**: 2026-06-23
