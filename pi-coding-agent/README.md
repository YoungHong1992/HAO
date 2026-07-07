# Pi Coding Agent

> **版本**: v1.0
> **更新日期**: 2026-06-22
> **依赖**: Node.js
> **部署方式**: npm 全局安装

Pi 是一个极简的终端编程助手，支持交互式和打印模式，可扩展工具、技能、提示词模板和主题。

---

## 环境要求

| 依赖 | 最低版本 | 安装方式 |
|------|---------|---------|
| **Node.js** | >= 18 | 脚本自动安装 v22 LTS |
| **npm** | >= 9 | 随 Node.js 提供 |

### 操作系统支持

| 操作系统 | 版本 | 测试状态 |
|---------|------|---------|
| **Ubuntu** | 20.04 / 22.04 / 24.04 | ✅ 推荐 |
| **Debian** | 11 / 12 | ✅ 支持 |
| **CentOS Stream** | 9 | ✅ 支持 |
| **Windows** | 10 / 11 (WSL2) | ✅ 支持 |
| **macOS** | 12+ | ✅ 支持 |

### 硬件要求

| 场景 | 最低配置 |
|------|---------|
| **仅安装** | 500MB 磁盘 |
| **实际使用** | 512MB 内存（API 调用无需本地算力） |

### API Key 要求

Pi 本身不提供 AI 能力，需要配置至少一个 AI 提供商的 API Key：

| 提供商 | 环境变量 |
|--------|---------|
| **Anthropic** | `ANTHROPIC_API_KEY` |
| **OpenAI** | `OPENAI_API_KEY` |
| **Google Gemini** | `GEMINI_API_KEY` |
| **DeepSeek** | `DEEPSEEK_API_KEY` |
| **其他** | 见 `pi /login` 交互认证 |

---

## 快速安装

### 方式一：脚本安装（推荐）

```bash
cd pi-coding-agent
chmod +x install.sh
sudo ./install.sh
```

### 方式二：手动安装

```bash
# 1. 安装 Node.js
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs

# 2. 安装 Pi
npm install -g --ignore-scripts @earendil-works/pi-coding-agent

# 3. 验证
pi --version
```

### 方式三：安装脚本一键安装

```bash
curl -fsSL https://pi.dev/install.sh | sh
```

---

## 配置 API Key

```bash
# 方式一：环境变量（推荐，临时生效）
export ANTHROPIC_API_KEY=sk-ant-...

# 方式二：写入 shell 配置文件（永久生效）
echo 'export ANTHROPIC_API_KEY=sk-ant-...' >> ~/.bashrc
source ~/.bashrc

# 方式三：使用 OAuth 登录
pi /login
```

---

## 基本使用

### 交互模式

```bash
pi                      # 启动交互式终端
pi "帮我写一个脚本"       # 带初始提示词启动
```

### 非交互模式

```bash
pi -p "解释这段代码"                    # 打印输出
cat file.txt | pi -p "总结这段内容"      # 管道输入
pi -p @screenshot.png "图片里有什么?"    # 文件引用
```

### 模型选择

```bash
pi --provider anthropic --model claude-sonnet-4-20250514   # 指定模型
pi --model openai/gpt-4o                                    # 简写形式
pi --thinking high "复杂问题"                                # 思考级别
```

### 会话管理

```bash
pi -c                   # 继续上一次会话
pi -r                   # 浏览并选择历史会话
pi --no-session         # 临时模式（不保存）
pi --fork <id>          # 从指定会话分支
```

### 工具控制

```bash
pi --tools read,write,bash          # 限制可用工具
pi -p --no-tools "纯聊天"            # 禁用所有工具
```

---

## SSH Key 认证配置（可选）

如果使用 AI 提供商中转 API（如本项目的 cliproxyapi / new-api），可以通过 SSH 端口转发连接：

```bash
# 使用已配置的 SSH key 建立端口转发
ssh -L 3000:127.0.0.1:3000 root@<vps-ip> -N

# 然后配置 API base URL
export OPENAI_BASE_URL=http://127.0.0.1:3000/v1
export OPENAI_API_KEY=your-key
pi --provider openai --model gpt-4o
```

---

## 常用命令速查

| 命令 | 说明 |
|------|------|
| `pi` | 启动交互模式 |
| `pi -p "msg"` | 打印模式，输出后退出 |
| `pi -c` | 继续上次会话 |
| `pi --help` | 帮助信息 |
| `pi --version` | 查看版本 |
| `pi --list-models` | 列出可用模型 |
| `pi /login` | OAuth 登录 |
| `pi /model` | 切换模型 |
| `pi /settings` | 设置面板 |
| `node --version` | Node.js 版本 |
| `npm list -g pi` | 查看安装信息 |
| `npm update -g @earendil-works/pi-coding-agent` | 更新 Pi |

---

## 目录结构

```
~/.pi/agent/
├── sessions/           # 会话存档 (JSONL)
├── settings.json       # 全局设置
├── AGENTS.md           # 全局上下文指令
├── extensions/         # 自定义扩展
├── skills/             # 技能包
├── prompts/            # 提示词模板
└── themes/             # 主题
```

---

## 升级

```bash
# 升级 Pi 本身
npm update -g @earendil-works/pi-coding-agent

# 或安装最新版
npm install -g --ignore-scripts @earendil-works/pi-coding-agent@latest
```

---

## 卸载

```bash
npm uninstall -g @earendil-works/pi-coding-agent
```

---

## 常见问题

### 1. 安装后提示 "pi: command not found"

```bash
# 检查 npm 全局路径
npm root -g
# 确保全局 bin 目录在 PATH 中
export PATH="$(npm bin -g):$PATH"
```

### 2. "Permission denied" 错误

```bash
# 确保使用 root 或有 sudo 权限
sudo npm install -g --ignore-scripts @earendil-works/pi-coding-agent
```

### 3. Node.js 版本过低

```bash
# Ubuntu/Debian 使用 NodeSource 安装最新版
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs
```

### 4. pi 启动后无法连接 AI

- 检查 API Key 是否正确设置
- 检查网络是否可以访问对应 API 端点
- 使用 `/login` 检查认证状态

---

## 项目集成说明

本项目（HAO）中，Pi 作为 AI 客户端工具，配合以下组件使用：

| 组件 | 角色 |
|------|------|
| **pi-coding-agent** | AI 编程助手客户端 |
| **cliproxyapi** | 轻量 API 代理（转发端口用） |
| **new-api** | AI 网关（多模型聚合管理） |

---

**最后更新**: 2026-06-22
