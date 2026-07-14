# Git + GitHub 工具

该模块面向个人开发机和明确需要 GitHub 操作能力的管理型 VPS。默认建议使用官方
GitHub CLI（`gh`）的 Web 登录，而不是让用户创建和粘贴长期 Token。它安装 Git 与
官方 GitHub CLI，配置用户明确提供的提交身份，并准备基于 SSH 的 GitHub 授权流程。

它不会猜测姓名或邮箱，不会创建或保存 Personal Access Token，也不会在无人确认时
覆盖已有 Git 身份。生产 VPS 默认不允许个人 GitHub 授权，必须额外确认。

## 推荐流程

```bash
cat > git.env <<'EOF'
HAO_SERVICES="git-github"
HAO_GIT_NAME="Your Exact Name"
HAO_GIT_EMAIL="exact-address-you-confirmed@example.com"
HAO_GIT_MACHINE_ROLE="workstation"
HAO_GIT_SCOPE="global"
HAO_GIT_TARGET_USER="your-user"
HAO_GH_AUTH_MODE="web"
EOF

./hao plan --profile git.env
./hao preflight --profile git.env
sudo ./hao apply --profile git.env --yes
hao-github-authorize
```

`hao-github-authorize` 必须由目标用户运行。它执行 GitHub 官方浏览器/设备码登录，
选择 SSH 作为 Git 协议，并由 `gh` 检查、选择、生成或上传 SSH 公钥。私钥不会进入 HAO
profile、日志或状态清单。

root-only VPS 可以明确把 `HAO_GIT_TARGET_USER` 设为 `root`。HAO 会显示警告但不阻止：
此时 `gh` 凭据、Git 全局配置和 SSH Key 都归 root 所有，其他系统用户无法直接复用。
共享服务器仍建议使用专门的普通管理用户。在无可用系统凭据存储的 VPS 上，`gh` 可能
回退到 `~/.config/gh/hosts.yml`；辅助脚本会把该文件权限明确收紧为 `600`，且不显示内容。

## 生产 VPS

生产服务器若只需下载公开仓库，不应安装个人 GitHub 凭据，直接使用 HTTPS 即可。
只有站长明确需要从该 VPS 执行 push、PR 或 Release 时，才应启用个人授权：

```bash
HAO_GIT_MACHINE_ROLE="server"
HAO_GH_AUTH_MODE="web"
HAO_GIT_ALLOW_SERVER_AUTH="yes"
```

私有仓库的只读自动部署更适合使用只读 Deploy Key 或 GitHub App，不应长期保存站长的
个人 Token。

## 配置变量

| 变量 | 必填 | 说明 |
|---|---|---|
| `HAO_GIT_NAME` | 是 | 用户确认的准确提交名称 |
| `HAO_GIT_EMAIL` | 是 | 用户确认的验证邮箱或准确 noreply 邮箱 |
| `HAO_GIT_MACHINE_ROLE` | 是 | `workstation` 或 `server` |
| `HAO_GIT_SCOPE` | 是 | `global` 或 `repository` |
| `HAO_GIT_TARGET_USER` | 条件 | 无非 root `SUDO_USER` 时必填 |
| `HAO_GIT_REPO_DIR` | 条件 | repository 范围时必填 |
| `HAO_GH_AUTH_MODE` | 否 | `web`（默认）或 `skip` |
| `HAO_GIT_ALLOW_IDENTITY_CHANGE` | 条件 | 覆盖不同的已有身份时必须为 `yes` |
| `HAO_GIT_ALLOW_SERVER_AUTH` | 条件 | 服务器启用个人 Web 授权时必须为 `yes` |
| `HAO_GIT_CONFIG_ONLY` | 否 | 仅配置现有 Git，不安装软件 |
| `HAO_GIT_SKIP_AGENT_CONVENTION` | 否 | 设为 `1` 时不向 AI 助手指令文件写入 gh 使用约定 |
| `HAO_GIT_AGENT_FILES` | 否 | 显式指定约定写入的文件（逗号分隔绝对路径），跳过自动检测 |

## AI 助手约定（gh）

安装后模块会把「GitHub 操作一律使用 `gh`」的约定写入目标用户已安装的 AI 编程助手
全局指令文件（Claude Code `~/.claude/CLAUDE.md`、Pi `~/.pi/agent/AGENTS.md`、
Codex CLI `~/.codex/AGENTS.md`、OpenCode `~/.config/opencode/AGENTS.md`，仅写
检测到的），与 `uv/` 模块使用同一套 `lib/agent-convention.sh` 标记块机制
（`HAO-GIT-GITHUB BEGIN/END`，幂等、原地更新、不动用户已有内容）。

约定要点：PR/Issue/CI/Release 操作走 `gh` 子命令；裸 API 用 `gh api` 复用登录
凭据；未登录时提示用户运行 `hao-github-authorize` 而不是代输凭据；禁止在命令行
与日志中出现 token 值；不擅自修改已配置的提交身份。

GitHub CLI 使用其官方 Debian/Ubuntu仓库和签名密钥。模块接受 GitHub 当前公布的官方
签名密钥指纹，并拒绝未知签名密钥。

相关官方说明：

- [GitHub CLI 登录](https://cli.github.com/manual/gh_auth_login)
- [GitHub CLI 的 Debian/Ubuntu 安装方式](https://github.com/cli/cli/blob/trunk/docs/install_linux.md)
- [向 GitHub 添加 SSH Key](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/adding-a-new-ssh-key-to-your-github-account?tool=cli)
- [Personal Access Token 安全建议](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)
