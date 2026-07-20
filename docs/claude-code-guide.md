# Claude Code 安装和配置指南

> 本文档介绍如何在服务器或本地开发机上安装 Claude Code，并配置自定义 Anthropic API 网关、模型和运行参数。

---

## 前置条件

- 已安装 Node.js 和 npm
- 可以访问 npm registry
- 已准备好可用的 Anthropic API 兼容网关地址和 token

检查 Node.js / npm：

```bash
node -v
npm -v
```

如果系统没有 Node.js，建议先通过发行版包管理器、NodeSource 或 nvm 安装 LTS 版本。

---

## 安装 Claude Code

使用 npm 全局安装：

```bash
npm install -g @anthropic-ai/claude-code
```

安装完成后验证：

```bash
claude --version
```

正常情况下会输出 Claude Code 的版本号。

---

## 配置 Claude Code

Claude Code 支持通过 `~/.claude/settings.json` 配置运行环境变量。创建配置目录：

```bash
mkdir -p ~/.claude
chmod 700 ~/.claude
```

写入配置文件：

```bash
cat > ~/.claude/settings.json <<'EOF'
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://gateway.example.com",
    "ANTHROPIC_AUTH_TOKEN": "替换为你的 token",
    "ANTHROPIC_MODEL": "替换为网关提供的模型名",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "替换为网关提供的模型名",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "替换为网关提供的模型名",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "替换为网关提供的模型名",
    "API_TIMEOUT_MS": "3000000",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    "CLAUDE_CODE_DISABLE_1M_CONTEXT": "0",
    "CLAUDE_CODE_ATTRIBUTION_HEADER": "0"
  }
}
EOF

chmod 600 ~/.claude/settings.json
```

> 不要把真实 `ANTHROPIC_AUTH_TOKEN` 提交到 Git 仓库。只在本机或服务器的用户目录中保存真实 token。

---

## 验证配置

检查 JSON 是否有效：

```bash
jq -e . ~/.claude/settings.json >/dev/null
```

启动 Claude Code：

```bash
claude
```

如果之前已经打开 Claude Code，需要退出后重新启动，新的环境变量才会生效。

---

## 常见问题

### 1. `npm install -g` 权限不足

如果提示权限错误，可以使用以下任一方式处理：

```bash
sudo npm install -g @anthropic-ai/claude-code
```

或使用 nvm 管理 Node.js，避免全局 npm 包写入系统目录。

### 2. `claude: command not found`

确认 npm 全局 bin 目录在 `PATH` 中：

```bash
npm prefix -g
echo "$PATH"
```

如果不在 `PATH`，把 npm 全局 bin 目录加入 shell 配置文件后重新打开终端。

### 3. 配置修改后没有生效

Claude Code 启动时读取配置。修改 `~/.claude/settings.json` 后，需要重新启动 Claude Code。

### 4. API 请求超时

当前示例中 `API_TIMEOUT_MS` 设置为 `3000000`。如果网关或网络不稳定，可以保留较长超时时间；如果希望失败更快，可以调小该值。

---

**最后更新**: 2026-07-08
