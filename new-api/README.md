# New-API 大模型网关

> **部署方式**: Docker Compose
> **技术栈**: New-API + PostgreSQL + Redis
> **资源需求**: ≥ 1GB 内存

---

## 简介

New-API 是新一代大模型网关与 AI 资产管理系统，支持 OpenAI、Claude、Gemini、Azure 等多种模型的统一管理和转发，提供用户管理、令牌分组、计费系统、数据看板等完整功能。

---

## 快速部署

```bash
cd new-api
chmod +x install.sh
sudo ./install.sh
```

### 前置条件

- 已部署并启动 `nginx`（可先进入 `../nginx` 运行 `sudo ./install.sh`）
- 已部署并启动 `docker` + Compose（可先进入 `../docker` 运行 `sudo ./install.sh`）
- 域名模式需 DNS 已解析

---

## 访问模式

| 模式 | 证书 | 说明 |
|------|------|------|
| 域名模式 | Let's Encrypt（自动） | 生产推荐 |
| IP 模式 | 自签名 | 测试环境 |
| HTTP 模式 | 无 | 内网/开发 |

---

## 部署后

部署完成访问 `http://<IP>:3000` 或 `https://<域名>`：

1. 初始账号：`root`，密码：`123456`
2. 登录后立即修改密码
3. 添加渠道 → 填写上游 API Key
4. 创建令牌 → 分发给客户端使用

---

## 服务管理

```bash
cd /opt/docker-services/new-api
docker compose ps
docker compose logs -f new-api
docker compose restart
```

---

## 升级

```bash
./upgrade_newapi_docker.sh       # 正式版
./upgrade_newapi_alpha.sh        # Alpha 预览版
```

## 卸载

```bash
./uninstall_newapi_docker.sh
```

---

## 文件说明

| 文件 | 说明 |
|------|------|
| `install.sh` | 一键部署脚本 |
| `docker-compose.yml` | 容器编排配置 |
| `upgrade_newapi_docker.sh` | 正式版升级 |
| `upgrade_newapi_alpha.sh` | Alpha 版升级 |
| `uninstall_newapi_docker.sh` | 卸载脚本 |

---

**最后更新**: 2026-06-22
