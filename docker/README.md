# Docker 自动安装指南

> **版本**: v1.0
> **更新日期**: 2026-06-23
> **适用场景**: VPS 集群 Docker 服务基础环境

---

## 目录

- [项目简介](#项目简介)
- [快速开始](#快速开始)
- [详细安装流程](#详细安装流程)
- [使用方式](#使用方式)
- [服务管理](#服务管理)
- [常见问题](#常见问题)

---

## 项目简介

本脚本为 VPS 集群项目的 **Docker 环境组件**，为 CliproxyAPI、New-API 等容器化服务提供运行环境。

### 核心功能

- **自动检测**: 已安装则跳过，仅确保服务运行
- **apt 源修复**: 自动修复 Debian/Ubuntu 常见源问题
- **双重安装策略**: 官方脚本优先，失败后按发行版手动安装
- **Compose 插件**: 自动安装 Docker Compose 插件
- **可复用设计**: 支持直接运行和 `source` 引用两种模式

### 为什么需要 Docker？

```
┌──────────────────────────────────────────┐
│         docker（容器运行环境）          │
│       【Docker 服务的前置依赖 - 推荐安装】  │
└────────────────────┬─────────────────────┘
                     │
         ┌───────────┴───────────┐
         ▼                       ▼
   ┌──────────┐          ┌──────────────┐
   │ New-API  │          │  其他 Docker  │
   │ AI 网关  │          │    服务       │
   └──────────┘          └──────────────┘
```

以下服务依赖 Docker 环境：
- **cliproxyapi**: 默认 Docker Compose 部署（仍可选择裸机二进制 + Systemd）
- **new-api**: Docker Compose 部署（PostgreSQL + Redis + New-API）

---

## 快速开始

### 系统要求

| 项目 | 最低配置 | 推荐配置 |
|------|---------|---------|
| **操作系统** | Ubuntu 20.04 / Debian 11 / CentOS Stream 9 | Ubuntu 22.04+ |
| **内存** | 512MB | 1GB+ |
| **磁盘** | 2GB 可用空间 | 10GB+ |
| **权限** | root | root |

### 一键安装

```bash
cd docker
chmod +x install.sh
sudo ./install.sh
```

### 验证安装

```bash
# 检查 Docker 版本
docker --version

# 检查 Compose 版本
docker compose version

# 检查服务状态
systemctl status docker

# 运行测试容器
docker run --rm hello-world
```

---

## 详细安装流程

```
Docker 已安装？
  ├─ 是 → 检查版本 → 确保服务运行 → 完成
  └─ 否 → 开始自动安装
           ├─ 1. 修复 apt 源（Debian/Ubuntu）
           ├─ 2. 安装依赖包
           ├─ 3. 按发行版配置 Docker 官方软件仓库
           │     ├─ debian/ubuntu → apt + Docker 官方仓库
           │     ├─ centos/rhel/rocky → yum + Docker 仓库
           │     └─ 其他 → 报错退出
           └─ 4. 启动服务 + 验证安装
```

---

## 使用方式

### 方式一：直接运行

```bash
sudo ./install.sh
```

适用于独立安装 Docker 环境。

### 方式二：通过根目录总入口

```bash
cd ..
sudo ./install.sh
```

各组件脚本不再通过 `source` 引用 Docker 安装脚本；需要 Docker 的组件会在未检测到 Docker/Compose 时提示先安装 Docker。部分组件会复用仓库内 `lib/` 公共库，请在完整仓库内运行。

---

## 服务管理

### Docker 服务命令

```bash
# 查看状态
systemctl status docker

# 启动/停止/重启
systemctl start docker
systemctl stop docker
systemctl restart docker

# 查看是否开机自启
systemctl is-enabled docker
```

### 常用 Docker 命令

```bash
# 查看运行中的容器
docker ps

# 查看所有容器
docker ps -a

# 查看镜像列表
docker images

# 清理未使用的资源
docker system prune -f

# 查看磁盘使用
docker system df
```

---

## 常见问题

### 1. Docker 官方仓库连接失败

**症状**: 连接 `download.docker.com` 超时或 apt/yum 仓库更新失败

**解决方案**: 检查服务器网络、DNS、防火墙或软件源代理配置后重试。

### 2. apt 源报错

**症状**: `E: The repository ... does not have a Release file`

**解决方案**: 脚本内置 `fix_apt_sources` 函数自动修复常见源问题（Debian 10/11 安全源路径变更等）。

### 3. Docker 服务启动失败

**排查步骤**:
```bash
# 查看详细错误
journalctl -xe -u docker

# 检查存储驱动
docker info 2>&1 | grep "Storage Driver"

# 检查磁盘空间
df -h /var/lib/docker
```

### 4. docker compose 命令不可用

**解决方案**:
```bash
# 安装 Compose 插件
apt-get install docker-compose-plugin

# 或使用独立版本
curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
  -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
```

---

**文档维护**: Claude Code
**最后更新**: 2026-06-23
