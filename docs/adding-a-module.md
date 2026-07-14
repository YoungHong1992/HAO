# 新增模块指南（Adding a Module）

本文档定义向 HAO 添加新组件（服务或工具，例如未来的 openclaw、hermes）的约定。按此模板操作，新模块即可被 `hao plan/preflight/apply/status/doctor/inventory` 编排，并自动获得 AI agent 工作流支持。

## 模块类型

- **服务模块**：部署服务器端服务（如 new-api、cliproxyapi）。通常依赖 nginx/docker，写 `/opt`、`/etc/nginx`。
- **工具模块**：安装终端工具并写用户级配置（如 claude-code、uv）。无服务依赖，配置写入目标用户 home 目录。

新的「给某个 CLI 工具装好并配置参数」类需求，参考 `claude-code/` 作为模板。

## 步骤

### 1. 创建模块目录

```
<module-id>/
├── install.sh    # 必须：统一命名，可被 hao apply 非交互调用
├── README.md     # 必须：用途、用法、全部配置变量表、安全说明
└── ...           # 可选：docker-compose.yml、uninstall/upgrade 脚本
```

`install.sh` 契约：

- `set -euo pipefail`；支持 `-h/--help`
- 非交互：识别 `HAO_UNATTENDED=1` / `HAO_NO_PROMPT=1`，跳过所有 read/confirm
- 幂等：重复执行安全（已安装则升级或跳过）
- 配置全部通过 `HAO_<PREFIX>_*` 环境变量传入（profile 只允许 `HAO_*` 变量）
- secret 通过 `*_FILE` 变量或环境变量传入，只写入 0600 凭据文件，绝不 echo/log
- 需要复用公共库时（凭据写入、SSL、Nginx 探测）：

  ```bash
  HAO_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  HAO_REPO_DIR="$(cd "$HAO_SCRIPT_DIR/.." && pwd)"
  source "$HAO_REPO_DIR/lib/common.sh"       # 日志、校验、SSL、Nginx
  source "$HAO_REPO_DIR/lib/crypto.sh"       # 随机密码/密钥（需要时）
  source "$HAO_REPO_DIR/lib/credentials.sh"  # 凭据文件原子写入（需要时）
  ```

  基础/自救类脚本（如 maintenance）可以自包含，不依赖 lib/。

### 2. 在根 `install.sh` 注册

按顺序修改以下位置（可用 `claude-code` 全文搜索对照，它是最新样板）：

| 位置 | 内容 |
|------|------|
| `SVC_*` 常量区 | `readonly SVC_<ID>="<module-id>"` |
| `SVC_NAME/DESC/HINT/SCRIPT/DEPENDS` | 服务定义；依赖填 `"$SVC_NGINX $SVC_DOCKER"` 等 |
| `ALL_SERVICES` 数组 | 追加（顺序 = 展示顺序） |
| `detect_installed_services()` | 判断已安装（command -v / 标记文件 / compose 文件） |
| `service_short_name()` | 展示短名 |
| `normalize_service_id()` | ID 与别名解析 |
| `run_install()` 的 case | 传递模块专属 `HAO_*` 环境变量 |
| `record_service_management_state()` | 登记 managed/shared/observed/secret 资源，不能记录秘密值 |
| `print_summary()` 的 case | 安装后常用命令提示 |
| `print_cli_status()` 的 case | status 一行详情 |
| `print_cli_plan()` 的 case（可选） | plan 输出模块专属配置（secret 显示 `provided (hidden)`） |
| `run_preflight_checks()`（可选） | 模块专属预检（如 token 文件可读性） |
| `cli_usage()` | `--services` 列表补充 |
| 仓库完整性检查（两处） | `bootstrap_full_repo` 内和文件顶部的 `[ ! -f ... ]` 链 |
| Web 服务额外 | `is_web_service()`、`service_env_prefix()`、域名 CLI 参数 |

### 3. 更新打包与文档

- `.github/workflows/release.yml`：`cp -a` 列表加入模块目录
- `skills/hao-deploy/references/services.md`：服务 ID、依赖、配置变量
- `README.md`：组件表
- 隐藏模块（不对外公开的）**不要**做本节任何一步，并确认 `tests/test-hidden-modules.sh` 通过

### 4. 验证

```bash
./tests/run.sh                          # 静态检查 + 全部仓库测试
./hao plan --services <module-id>       # plan 输出正确
./hao preflight --services <module-id>  # 预检通过
./hao status --services <module-id>     # 状态行正确
```

## 命名约定

- 模块目录 = service ID，小写连字符（`claude-code`）
- 环境变量前缀简短大写（`HAO_CC_*`、`HAO_NEWAPI_*`）
- secret 变量提供 `*_FILE` 变体，推荐 agent 使用文件方式传递

## 安全基线（所有模块必须遵守）

- secret 不进 stdout/日志/plan 输出（plan 显示 `provided (hidden)`）
- 覆盖已有配置前先 `backup_file`
- 凭据文件 0600，用 `write_credentials_file` 原子写入
- 破坏性操作（卸载、删卷、删证书）放独立脚本，绝不进入 `install.sh` 主流程
- 独占配置使用模块专属文件/drop-in，不直接追加系统主配置
- HAO 生成的文本配置头部写 `Managed by HAO`、服务 ID 和发布标识
- Docker 服务添加 `io.hao.managed`、`io.hao.service`、`io.hao.release` labels
- 共享或既有资源标记为 `shared`/`observed`，不得为了登记状态而认领或覆盖
- 凭据资源标记为 `secret`，状态清单只记录路径，值和哈希均不得写入
