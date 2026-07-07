# CliproxyAPI 轻量 AI API 代理

> **版本**: v2.1
> **部署方式**: 默认 Docker Compose + Nginx 反代；可选二进制 + Systemd
> **资源占用**: ~50MB 内存

---

## 简介

CliproxyAPI 是一款轻量级 AI API 转发代理，将多个 AI 服务商（OpenAI、Claude、Gemini 等）的 API 统一到一个端点，客户端只需配置一个地址即可访问所有模型。

与 New-API 相比：更轻量、更简单，适合低配 VPS（< 1GB 内存），没有用户管理和计费系统。

---

## 快速部署

```bash
cd cliproxyapi
chmod +x install.sh
sudo ./install.sh              # 默认 Docker Compose
```

### CPA 裸机安装选项

```bash
cd cliproxyapi
sudo HAO_CLIPROXY_MODE=bare ./install.sh
```

### 前置条件

- 已部署并启动 `nginx`（可先进入 `../nginx` 运行 `sudo ./install.sh`）
- 默认 Docker Compose 部署需已部署并启动 `docker` + Compose（可先进入 `../docker` 运行 `sudo ./install.sh`）
- 裸机模式不依赖 Docker，会使用二进制文件 + Systemd
- 域名模式需 DNS 已解析；IP 模式无需域名
- 至少准备一个 AI 服务商的 API Key

---

## 访问模式

| 模式 | 证书 | 说明 |
|------|------|------|
| 域名模式 | Let's Encrypt（自动） | 生产推荐 |
| IP 模式 | 自签名 | 测试环境 |
| HTTP 模式 | 无 | 内网/开发 |

---

## 服务管理

默认 Docker Compose：

```bash
cd /opt/docker-services/cliproxyapi
docker compose ps
docker compose logs -f cliproxyapi
docker compose restart
```

裸机 Systemd：

```bash
systemctl status cliproxyapi
systemctl restart cliproxyapi
journalctl -u cliproxyapi -f
```

## SSL 证书管理

```bash
~/.acme.sh/acme.sh --list
./apply_ssl.sh    # 重新申请/更新证书
```

## 卸载

```bash
./uninstall_cliproxyapi.sh
```

---

## 文件说明

| 文件 | 说明 |
|------|------|
| `install.sh` | 安装/升级脚本（默认 Docker Compose，可选裸机） |
| `docker-compose.yml` | Docker Compose 参考模板 |
| `apply_ssl.sh` | SSL 证书工具 |
| `uninstall_cliproxyapi.sh` | 卸载脚本 |

---

**最后更新**: 2026-06-23
