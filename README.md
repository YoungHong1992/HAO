# HAO（HongAgentOps）— AI-native server deployment toolkit

> **发布标识**: 正式发布使用 `YYMMDD-<git-short-hash>`，例如 `260713-abcdef0`
> **更新日期**: 2026-07-13
> **许可证**: MIT

HongAgentOps 是洪哥出品的 AI 原生服务器部署工具。它把传统终端菜单改造成适合 AI agents 调用的 `plan → preflight → apply → status/doctor` 工作流：人负责在对话里确认目标和风险，AI 负责生成部署 profile、检查环境、执行明确的参数化命令。

> 🤖 **如果你是 AI agent**：请先阅读 [AGENTS.md](AGENTS.md)，它是为你准备的入口文档（工作流契约、知识库索引、skill 安装方式）。

---

## ✨ 特性

- 🤖 **AI 协作部署**：AI 通过 profile/参数驱动部署，不依赖终端菜单输入
- 🧭 **计划先行**：`plan` 只生成变更计划，`preflight` 只检查环境，确认后才 `apply`
- 🔒 **安全基线**：fail2ban、swap、日志限制、TLS 1.2+，自动 SSL 证书
- 📦 **零依赖**：纯 Bash 实现，兼容 Debian/Ubuntu，无需安装额外运行时
- 🧩 **模块化**：每个服务可独立安装，也可通过 `hao` CLI 编排部署
- 🐳 **Compose 优先**：CPA / New-API 默认采用 Docker Compose，CPA 保留裸机安装选项

---

## 🚀 快速开始

### AI 协作部署（推荐）

```bash
git clone https://github.com/YoungHong1992/hao.git
cd hao

cat > deploy.env <<'EOF'
HAO_SERVICES="maintenance,nginx,docker,new-api"
HAO_ACCESS_MODE="domain"
HAO_NEWAPI_DOMAIN="api.example.com"
HAO_DB_TYPE="postgresql"
EOF

./hao plan --profile deploy.env
./hao preflight --profile deploy.env
sudo ./hao apply --profile deploy.env --yes
./hao inventory
```

> 建议由 AI agent 先和你确认服务、域名、数据库、风险项，再生成 `deploy.env`。`apply` 必须显式传入 `--yes` 或设置 `HAO_CONFIRM_APPLY=yes` 才会修改系统。

### 下载完整包安装

```bash
curl -fsSLO https://github.com/YoungHong1992/hao/releases/latest/download/hao.tar.gz
tar xzf hao.tar.gz
cd hao
./hao plan --services new-api --domain api.example.com
```

生产环境建议固定发布标识，避免 `latest` 随后变化：

```bash
HAO_RELEASE="260713-abcdef0" # 替换为实际发布标识
curl -fsSLo hao.tar.gz "https://github.com/YoungHong1992/hao/releases/download/${HAO_RELEASE}/hao.tar.gz"
curl -fsSLo checksums.txt "https://github.com/YoungHong1992/hao/releases/download/${HAO_RELEASE}/checksums.txt"
sha256sum -c checksums.txt
```

发布标识不表达兼容级别，只标识一次不可变构建。归档内的 `RELEASE` 和
`build-info.json` 分别记录发布标识、完整提交哈希、UTC 构建时间和真实 VM 验收记录。

### 远程自举入口

```bash
curl -fsSL https://raw.githubusercontent.com/YoungHong1992/hao/main/install.sh | bash
```

> 无参数运行只显示帮助，不进入终端菜单。根入口只作为确定性 CLI 执行器和远程自举入口；请使用 release 包或完整仓库中的 `hao plan/preflight/apply/status/doctor`。

### 单独安装某个服务

在完整仓库内，每个组件目录都保留统一命名的 `install.sh`，供 `hao apply` 非交互调用。涉及服务编排和凭据写入的组件会复用仓库内 `lib/` 公共库；部分基础/辅助脚本保持自包含，便于单独修复环境问题。推荐保留完整仓库结构运行。

```bash
cd maintenance && sudo ./install.sh        # 安装服务器维护基线
cd ../nginx && sudo ./install.sh           # 安装 Nginx
cd ../docker && sudo ./install.sh          # 安装 Docker
cd ../cliproxyapi && sudo ./install.sh     # 安装 CliproxyAPI（默认 Docker Compose）
# CPA 裸机安装：cd ../cliproxyapi && sudo HAO_CLIPROXY_MODE=bare ./install.sh
cd ../new-api && sudo ./install.sh         # 安装 New-API
cd ../pi-coding-agent && sudo ./install.sh # 安装 Pi
cd ../claude-code && sudo ./install.sh     # 安装 Claude Code
```

> CliproxyAPI / New-API 需要已安装 Nginx；默认 Docker Compose 部署还需要 Docker + Compose。缺少依赖时，对应脚本会提示先安装依赖后再继续。CPA 如需裸机二进制 + Systemd，可设置 `HAO_CLIPROXY_MODE=bare`。

---

## 📁 项目结构

```
hao/
├── hao                     # AI-friendly CLI wrapper
├── install.sh                  # 确定性 CLI 执行器 / 远程自举入口
├── AGENTS.md                   # AI agent 使用入口文档
├── lib/                        # 公共 Bash 工具库（凭据写入等）
├── maintenance/                # 服务器维护基线 (fail2ban / swap / 日志限制)
├── nginx/                      # Nginx (HTTP/3 + BBR)
├── docker/                     # Docker Engine + Compose
├── cliproxyapi/                # 轻量 AI API 转发代理
├── new-api/                    # AI 模型网关
├── pi-coding-agent/            # 终端 AI 编程助手
├── claude-code/                # Claude Code CLI 安装与配置
├── skills/                     # 通用 AI agent skill：协作部署封装
├── docs/                       # 辅助文档
├── tests/                      # 静态检查、凭据与集成测试脚本
└── README.md
```

常用辅助文档：

- [Cloudflare DNS 配置指南](docs/cloudflare-dns-guide.md)
- [Claude Code 安装和配置指南](docs/claude-code-guide.md)

---

## 📦 组件说明

| 组件 | 描述 | 资源需求 |
|------|------|----------|
| **Maintenance** | fail2ban、swap、journald 限制、Docker 日志轮转 | 基础维护 |
| **Nginx** | HTTP/3 (QUIC) + BBR 优化，所有服务的基础设施 | 512MB 内存 |
| **Docker** | Docker Engine + Compose 插件 | 无额外需求 |
| **CliproxyAPI** | 轻量 AI API 转发代理，默认 Docker Compose，可选裸机 | 256MB 内存 |
| **New-API** | AI 模型网关与资产管理系统，Docker Compose | ≥ 1GB 内存 |
| **Pi** | 终端 AI 编程助手 | 500MB 磁盘 |
| **Claude Code** | Anthropic 官方终端 AI 编程助手，可选配置自定义网关/模型 | 500MB 磁盘 |

### 用一句话理解 Nginx

可以把 **Nginx 理解成服务器入口处的“接线员兼门卫”**：外部请求先到 Nginx，
Nginx 看清请求要找谁，再把它转接给 New-API、CliproxyAPI 等内部服务；同时还负责
HTTPS 证书、标准的 80/443 端口、WebSocket、访问日志和基础访问控制。

```text
api.example.com ──┐
                  ├──> Nginx（接线员）──> 对应的内部服务
cpa.example.com ──┘
```

域名就像分机号。同一个公网 IP 上部署多个服务时，Nginx 可以根据不同域名把请求转到
不同服务。如果完全不用域名，也可以使用 `IP:不同端口` 区分，例如：

```text
203.0.113.10:3000  -> New-API
203.0.113.10:8317  -> CliproxyAPI
```

但一个 IP 上的多个服务不能同时直接占用相同的 80/443 端口。技术上，单个内网服务可以
不经过 Nginx，直接使用 `IP:端口` 访问；当前 HAO 的 New-API 和 CliproxyAPI 部署仍将
Nginx 作为统一入口，用它处理转发、HTTPS 和 WebSocket。生产环境建议保留 Nginx；只有
在内网、VPN 或其他受控环境中，直接开放服务端口才通常更合适。

---

## 🛠 AI 工作流

```
1. 问询 → AI 和用户确认目标服务、域名、数据库、部署方式
2. Profile → AI 生成 deploy.env 或等价 CLI 参数
3. Plan → ./hao plan 输出将安装什么、依赖顺序和系统改动
4. Preflight → ./hao preflight 检查 OS、权限、DNS、端口、脚本完整性
5. Apply → 用户确认后 sudo ./hao apply --yes 非交互执行
6. Status/Doctor → ./hao status / doctor 检查部署状态并辅助排障
```

### HAO 如何标识自己管理的资源

通过 HAO 成功部署后，根执行器会在 `/var/lib/hao/` 写入不含秘密的管理清单：

```text
/var/lib/hao/
├── NOTICE
├── manifest.json
└── services/
    ├── nginx.json
    ├── nginx.resources
    └── new-api.json
```

- `managed`：由 HAO 生成并维护，`doctor` 会检查文件哈希和配置漂移。
- `shared`：HAO 可能调整过，但它属于整个系统，不能由 HAO 独占或随意覆盖。
- `observed`：HAO 只记录它的存在，不声称拥有它。
- `secret`：只记录凭据文件路径，哈希和值都会隐藏。

包含运行时秘密的生成配置会限制为仅 root 可读；manifest 不保存文件内容。普通受管文件只
记录 SHA-256，用于发现漂移，不能据此恢复配置内容。

HAO 生成的 Nginx、systemd、sysctl、APT 和 Compose 配置会带有 `Managed by HAO`、
服务名和发布标识；Docker 容器配置还带有 `io.hao.*` labels。其他工程师或 AI 可以运行：

```bash
./hao inventory    # 输出机器可读的 JSON 管理清单
./hao status       # 查看服务是否安装以及 managed/observed/untracked 状态
./hao doctor       # 检查服务状态、环境和受管文件是否被修改或删除
```

发现没有 HAO 标识的现有配置时，应视为外部资源并默认保留。发现受管文件被人工修改时，
`doctor` 只报告漂移，不会自动覆盖修改。

较早的 HAO 部署没有统一 manifest。升级后它们会继续显示为 `untracked`，直到对应服务
通过新版 HAO 完成一次受控重部署；HAO 不会仅凭文件路径自动认领旧资源。

> 同时部署 CliproxyAPI 与 New-API 时，请为每个 Web 服务准备独立域名，避免多个服务争用同一个 Nginx `server_name` 和 `/` 路由。

### CLI 命令

```bash
./hao plan --services new-api --domain api.example.com
./hao preflight --profile deploy.env
sudo ./hao apply --profile deploy.env --yes
./hao status
./hao doctor --profile deploy.env
./hao inventory
```

### AI Agent Skill

仓库内置 `skills/hao-deploy`，用于让各类 AI agent 按 HongAgentOps 的安全流程部署服务。它不会绕过确认机制：agent 应先运行 `plan` 和 `preflight`，在你确认后才执行 `apply --yes`。

安装到 agent 运行时（可选，符号链接方式随仓库更新）：

```bash
./skills/hao-deploy/scripts/install-skill.sh                       # Claude Code (~/.claude/skills)
./skills/hao-deploy/scripts/install-skill.sh --dir /path/to/skills # 其他 agent 运行时
```

Profile 支持的常用变量：

```bash
HAO_SERVICES="maintenance,nginx,docker,cliproxyapi,new-api,pi,claude-code"
HAO_ACCESS_MODE="domain"       # domain | ip | http
HAO_DOMAIN="api.example.com"   # 单个 Web 服务时可用
HAO_CLIPROXY_DOMAIN="cpa.example.com"
HAO_NEWAPI_DOMAIN="api.example.com"
HAO_CLIPROXY_MODE="docker"     # docker | bare
HAO_CLIPROXY_IMAGE="eceasy/cli-proxy-api:latest"
HAO_DB_TYPE="postgresql"       # postgresql | mysql
HAO_NEWAPI_IMAGE="calciumion/new-api:latest"
HAO_CONFIRM_APPLY="yes"        # 等价于 apply --yes
```

Docker 镜像默认跟随 `latest`。`hao plan` 会同时显示最近一次仓库审查确认的两个固定标签，
用户可通过 `HAO_CLIPROXY_IMAGE` / `HAO_NEWAPI_IMAGE` 或对应 CLI 参数选择。候选来源于
`config/image-candidates.tsv`，每次发布前必须刷新和验收；New-API 当前上游候选仍属于 RC，
计划输出会明确标记为 `release-candidate`。

### 支持的操作系统

正式支持矩阵遵循 Debian 的 stable/oldstable 与 Ubuntu 仍处于标准维护期的主流 LTS：

| 发行版 | 支持版本 |
|---|---|
| Debian | 13、12 |
| Ubuntu LTS | 26.04、24.04、22.04 |

`preflight` 会拒绝矩阵外的版本。支持矩阵依据
[Debian Releases](https://www.debian.org/releases/) 和
[Ubuntu release cycle](https://ubuntu.com/about/release-cycle) 维护，并在每次发布前复核。

---

## 🔒 安全说明

- 所有密码和密钥使用加密安全随机数生成
- SSL/TLS 最低版本: TLSv1.2
- 安装日志自动记录到 `/var/log/vps-deploy/`
- fail2ban 默认启用 SSH 防暴力破解
- swap 自动按内存配置，降低小内存 VPS OOM 风险
- journald / Docker 日志轮转限制磁盘占用
- Nginx 配置先备份再覆盖
- 支持域名（Let's Encrypt）和 IP（自签名）两种证书模式

---

## 🧪 开发

### 本地测试

```bash
# 安装 shellcheck
apt-get install -y shellcheck

# 静态检查 + 仓库测试
./tests/run.sh

# 真实安装幂等测试（会修改当前机器维护基线，建议只在 CI/临时机执行）
sudo ./tests/test-maintenance-idempotency.sh
```

正式发布流程和真实 VM 验收矩阵见 [发布清单](docs/releasing.md)。GitHub Release 通过
`Release` workflow 手工触发，标识由 UTC 日期和目标提交自动生成，已有发布不会被覆盖。

### 新增模块

向 HAO 添加新组件（服务或工具配置模块）请遵循 [docs/adding-a-module.md](docs/adding-a-module.md) 的约定。

---

**最后更新**: 2026-07-13
