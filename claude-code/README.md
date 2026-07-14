# Claude Code 安装与配置模块

安装 [Claude Code](https://docs.anthropic.com/claude-code) CLI，并可选地为目标用户写入 `~/.claude/settings.json`（自定义 Anthropic 兼容网关、模型、超时）。

这是 HAO 的第一个「工具配置」类模块：不部署服务器服务，而是安装终端工具并写用户级配置。与服务模块的区别是它需要 root 仅为了 npm 全局安装；配置文件写入的是 `HAO_CC_USER` 指定用户的 home 目录。

## 用法

```bash
# 通过 hao CLI（推荐）
./hao plan --services claude-code
sudo ./hao apply --services claude-code --yes

# 带配置的 profile 部署
cat > deploy.env <<'EOF'
HAO_SERVICES="claude-code"
HAO_CC_BASE_URL="https://gateway.example.com"
HAO_CC_TOKEN_FILE="/root/.secrets/cc-token"
HAO_CC_MODEL="claude-fable-5-thinking"
EOF
sudo ./hao apply --profile deploy.env --yes

# 单独运行
cd claude-code && sudo ./install.sh
```

## 配置变量

全部可选；不提供任何 `HAO_CC_*` 变量时只安装 CLI，不写配置。

| 变量 | 说明 | 默认 |
|------|------|------|
| `HAO_CC_ACTION` | `ensure`（CLI 已安装则保持现有版本）或 `upgrade`（显式升级到最新版） | `ensure` |
| `HAO_CC_BASE_URL` | Anthropic 兼容网关地址 | 官方 API |
| `HAO_CC_AUTH_TOKEN` | API token | 无 |
| `HAO_CC_TOKEN_FILE` | 从文件首行读取 token（优先于 `HAO_CC_AUTH_TOKEN`，避免 token 进入 profile/命令行） | 无 |
| `HAO_CC_MODEL` | 默认模型（同时设置 SONNET/OPUS/HAIKU 默认） | 无 |
| `HAO_CC_API_TIMEOUT_MS` | API 超时毫秒数 | `3000000` |
| `HAO_CC_USER` | settings.json 写入的目标用户 | `SUDO_USER`，否则当前用户 |
| `HAO_CC_CONFIGURE_ONLY` | 设为 `1` 时只写配置，跳过 Node.js/CLI 安装（为当前用户写配置时无需 root） | 关闭 |

## 安全说明

- token 只写入 `settings.json`（权限 0600），不打印、不进日志
- 推荐用 `HAO_CC_TOKEN_FILE` 传入 token，profile 文件中不放明文 token
- 已存在的 `settings.json` 会先备份（`*.bak.<时间戳>`）再覆盖
- 不要把包含真实 token 的 profile 或 settings.json 提交到 Git

## 详细文档

人工安装步骤和常见问题见 [docs/claude-code-guide.md](../docs/claude-code-guide.md)。
