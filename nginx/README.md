# Nginx 部署指南（支持 HTTP/3）

> **版本**: v4.0.0
> **更新日期**: 2026-06-22
> **Nginx 来源**: nginx.org 官方主线仓库（支持 HTTP/3 QUIC 协议）
> **适用场景**: VPS 集群基础设施部署

---

## 目录

- [项目简介](#项目简介)
- [快速开始](#快速开始)
- [详细部署步骤](#详细部署步骤)
- [系统优化说明](#系统优化说明)
- [Nginx 模块说明](#nginx-模块说明)
- [服务管理](#服务管理)
- [目录结构](#目录结构)
- [常见问题](#常见问题)
- [后续服务部署](#后续服务部署)

---

## 项目简介

本脚本是 VPS 集群项目的**基础设施组件**，为后续所有服务提供 Web 服务器和反向代理能力。

### 核心功能

- **Nginx 官方主线包安装**: 来自 nginx.org，支持最新的 HTTP/3 (QUIC) 协议
- **系统内核优化**: 自动开启 BBR 拥塞控制，优化 TCP 连接参数
- **模块化配置结构**: 使用标准 `/etc/nginx/conf.d` 目录，方便后续服务扩展

### 技术特性

| 特性 | 说明 |
|------|------|
| **HTTP/3 (QUIC)** | 基于 UDP 的新一代 HTTP 协议，减少连接延迟 |
| **HTTP/2** | 多路复用，头部压缩，服务器推送 |
| **TCP BBR** | Google 拥塞控制算法，提升网络吞吐量 |
| **RealIP 模块** | 支持 Cloudflare 等 CDN 的真实 IP 还原 |

### 为什么需要先部署此脚本？

```
                    ┌─────────────────────────────────────────┐
                    │      nginx部署（HTTP/3）               │
                    │          【基础设施层 - 必须先部署】        │
                    └────────────────────┬────────────────────┘
                                         │
                    ┌────────────────────┼────────────────────┐
                    ▼                    ▼                    ▼
              ┌───────────┐        ┌───────────┐        ┌──────────┐
              │CliproxyAPI│        │ New-API   │        │ 其他服务  │
              │  API转发   │        │ AI网关    │        │          │
              └───────────┘        └───────────┘        └──────────┘
```

所有后续服务都依赖本脚本提供的：
- Nginx 主程序和配置结构
- SSL 证书存储目录
- 模块化虚拟主机配置目录
- 系统优化（BBR、文件描述符提升）

---

## 快速开始

### 系统要求

| 项目 | 最低配置 | 推荐配置 |
|------|---------|---------|
| **操作系统** | Ubuntu 20.04 / Debian 11 | Ubuntu 22.04+ |
| **内存** | 256MB | 512MB+ |
| **磁盘** | 100MB 可用空间 | 500MB+ |
| **内核版本** | 4.9+（BBR 支持） | 5.4+ |
| **权限** | root | root |

### 一键部署

```bash
cd nginx
chmod +x install.sh
sudo ./install.sh           # 已安装且运行正常时默认跳过
sudo ./install.sh --force   # 强制重装并覆盖主配置
```

**部署时间**: 约 30 秒（纯 apt 安装，无需编译）

### 验证安装

```bash
# 检查 Nginx 版本
nginx -v

# 验证 HTTP/3 模块
nginx -V 2>&1 | grep http_v3

# 检查服务状态
systemctl status nginx

# 验证 BBR 开启
sysctl net.ipv4.tcp_congestion_control
# 应输出: net.ipv4.tcp_congestion_control = bbr
```

---

## 详细部署步骤

### 脚本执行流程

```
[1/3] 系统环境检查与优化
      ├─ 检查 Root 权限
      ├─ 检测已安装且健康的 Nginx（默认跳过，--force 可覆盖）
      ├─ 配置内核参数（BBR、TCP 优化）
      └─ 提升文件描述符限制

[2/3] 安装 Nginx（nginx.org 官方主线包）
      ├─ 添加 nginx.org GPG 签名密钥
      ├─ 添加主线仓库源
      ├─ apt install nginx
      ├─ 校验 nginx 运行用户
      └─ 写入 systemd LimitNOFILE override

[3/3] 配置 Nginx 高并发优化
      ├─ 生成 nginx.conf（高并发调优）
      ├─ 创建 SSL / 日志 / 缓存目录
      └─ 测试配置并启动服务
```

### 输出结果

部署完成后，脚本显示：

```
==============================================
   Nginx 安装与系统优化完成
==============================================
版本:         v4.0.0
Nginx 版本:   当前 nginx.org 主线版
安装来源:     nginx.org 官方主线仓库
配置文件:     /etc/nginx/nginx.conf
站点配置:     /etc/nginx/conf.d/*.conf
SSL 证书:     /etc/nginx/ssl/
优化状态:     BBR 已开启/未开启, systemd LimitNOFILE=65535
HTTP/3 支持:  ✓ (内置 --with-http_v3_module)
==============================================
```

---

## 系统优化说明

### BBR 拥塞控制

脚本自动开启 Google BBR 拥塞控制算法：

```bash
# 配置文件: /etc/sysctl.d/99-vps-optimize.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
```

**BBR 优势**：
- 提升网络吞吐量 20-30%
- 减少网络延迟
- 改善高延迟/高丢包网络环境的性能

### TCP 连接优化

```bash
net.ipv4.tcp_tw_reuse = 1         # TIME-WAIT 复用
net.ipv4.tcp_fin_timeout = 30     # FIN 超时
net.ipv4.tcp_fastopen = 3         # TCP 快速打开
net.core.somaxconn = 32768        # 连接队列大小
```

### 文件描述符提升

```bash
# /etc/security/limits.conf
* soft nofile 65535
* hard nofile 65535

# /etc/systemd/system/nginx.service.d/limits.conf
[Service]
LimitNOFILE=65535
```

支持 Nginx 的 `worker_connections 10240` 配置，并确保 systemd 启动的 Nginx 进程实际获得该限制。

---

## Nginx 模块说明

### 官方包内建模块

Nginx 官方主线包已内置以下与项目相关的核心模块：

| 模块 | 用途 |
|------|------|
| **SSL** | HTTPS 支持 |
| **HTTP/2** | HTTP/2 协议 |
| **HTTP/3** | HTTP/3 QUIC 协议 |
| **RealIP** | 获取真实客户端 IP（CDN 场景） |
| **Status** | Nginx 状态监控 |
| **Gzip Static** | 预压缩静态文件 |
| **Gunzip** | 解压缩模块 |
| **Sub** | 内容替换（伪装） |

---

## 服务管理

### Nginx 服务命令

```bash
# 查看状态
systemctl status nginx

# 启动/停止/重启
systemctl start nginx
systemctl stop nginx
systemctl restart nginx

# 重载配置（不中断服务）
systemctl reload nginx

# 查看是否开机自启
systemctl is-enabled nginx
```

### 配置管理

```bash
# 测试配置语法
nginx -t

# 重载配置
systemctl reload nginx

# 查看当前配置
cat /etc/nginx/nginx.conf

# 查看扩展配置
ls /etc/nginx/conf.d/
```

### 日志管理

```bash
# 访问日志
tail -f /var/log/nginx/access.log

# 错误日志
tail -f /var/log/nginx/error.log

# 日志轮转（系统自动，官方包自带 logrotate 配置）
cat /etc/logrotate.d/nginx
```

---

## 目录结构

### 安装目录

```
/etc/nginx/
├── nginx.conf             # 主配置文件
├── mime.types             # MIME 类型
├── conf.d/                # 【扩展配置目录】- 后续服务配置存放位置
│   ├── api.example.com.conf
│   ├── newapi.example.com.conf
│   └── ...
├── ssl/                   # 【SSL 证书目录】
│   ├── api.example.com/
│   │   ├── key.pem
│   │   └── fullchain.pem
│   └── ...
└── ...
```

### 日志目录

```
/var/log/nginx/
├── access.log             # 访问日志
└── error.log              # 错误日志
```

### 系统优化配置

```
/etc/sysctl.d/99-vps-optimize.conf              # 内核参数
/etc/security/limits.conf                        # 登录会话文件描述符限制
/etc/systemd/system/nginx.service.d/limits.conf  # Nginx systemd 文件描述符限制
```

---

## 常见问题

### 1. BBR 开启失败

**症状**: 提示"BBR 开启失败，请检查内核版本"

**原因**: 内核版本低于 4.9

**解决方案**:
```bash
# 查看当前内核版本
uname -r

# Ubuntu/Debian 升级内核
apt update && apt install linux-generic-hwe-20.04
reboot
```

### 2. 服务启动失败

**症状**: `Job for nginx.service failed`

**排查步骤**:
```bash
# 1. 测试配置语法
nginx -t

# 2. 查看详细错误
journalctl -xe -u nginx

# 3. 检查端口占用
netstat -tlnp | grep :80
netstat -tlnp | grep :443

# 4. 检查日志
cat /var/log/nginx/error.log
```

### 3. 如何添加新站点？

在 `/etc/nginx/conf.d/` 创建新配置文件：

```bash
# 示例: 添加 api.example.com
cat > /etc/nginx/conf.d/api.example.com.conf << 'EOF'
server {
    listen 443 ssl;
    http2 on;
    server_name api.example.com;

    ssl_certificate /etc/nginx/ssl/api.example.com/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/api.example.com/key.pem;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
EOF

# 测试并重载
nginx -t && systemctl reload nginx
```

---

## 后续服务部署

Nginx 部署完成后，可以继续部署以下服务：

| 序号 | 服务 | 用途 | 部署命令 |
|------|------|------|---------|
| Docker | 容器运行环境 | `cd ../docker && sudo ./install.sh` |
| CliproxyAPI | AI API 转发 | `cd ../cliproxyapi && sudo ./install.sh` |
| New-API | AI 模型网关 | `cd ../new-api && sudo ./install.sh` |

**完整部署流程**: 请参考根目录的 `install.sh` 脚本进行引导式部署。

---

## 主配置文件核心参数

```nginx
user  nginx;
worker_processes  auto;           # 自动匹配 CPU 核心
worker_rlimit_nofile 65535;       # 文件描述符限制

events {
    worker_connections  10240;    # 每进程最大连接数
    use epoll;                    # 高效事件模型
    multi_accept on;              # 批量接受连接
}
```

---

## 相关链接

- **Nginx 官方文档**: https://nginx.org/en/docs/
- **Nginx 主线仓库**: https://nginx.org/en/linux_packages.html#mainline
- **HTTP/3 说明**: https://nginx.org/en/docs/http/ngx_http_v3_module.html
- **BBR 算法**: https://github.com/google/bbr

---

**文档维护**: AI Coding Assistant
**最后更新**: 2026-06-22
