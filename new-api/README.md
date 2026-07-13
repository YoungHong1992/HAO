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
./hao plan --services new-api --domain api.example.com
./hao preflight --services new-api --domain api.example.com
sudo ./hao apply --services new-api --domain api.example.com --yes
```

重复执行相同的 `ensure`（默认动作）是 no-op，不会轮换数据库、Redis 或 Session 密钥。

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
./hao plan --services new-api --domain api.example.com --newapi-action upgrade
sudo ./hao apply --services new-api --domain api.example.com --newapi-action upgrade --yes
```

显式升级会从现有 Compose 复用全部密钥，并且只能保持当前数据库引擎。
PostgreSQL/MySQL 之间的数据迁移不是普通升级；`migrate-db` 动作会明确拒绝自动执行，
以免用一个空数据库替代真实迁移。旧的独立升级脚本保留用于人工维护，但不属于根 CLI
的可审计升级路径。

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
