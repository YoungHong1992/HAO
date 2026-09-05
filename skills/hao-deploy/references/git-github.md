# git-github —— Git 身份与 GitHub CLI

装 Git + 官方 GitHub CLI（`gh`），配置提交身份，装好授权助手，
并写「用 gh 操作 GitHub」的 agent 约定。

## 0. 这几件事必须问用户，一个都不能猜

| 要素 | 为什么不能猜 |
|---|---|
| Git 显示名 | 会写进每一个 commit，猜错了要改历史 |
| Git 邮箱 | 同上；且必须是 GitHub 已验证邮箱或 noreply 地址 |
| 目标系统用户 | 决定配置、SSH 密钥、gh 凭据归谁 |
| 机器角色（workstation / server） | server 上做个人授权需要额外确认 |
| 作用域（global / repository） | global 会影响该用户所有仓库 |
| 授权方式（web / skip） | 服务器部署公开仓库通常该用 skip |

**绝不要**从登录名、主机名、仓库历史或 GitHub 账号推断身份。邮箱格式要校验，
名字里不能有换行。

## 1. 前置检查

```bash
"$SKILL/scripts/hao-guard.sh" managed-file /usr/local/bin/hao-github-authorize
command -v git >/dev/null && git --version
command -v gh >/dev/null && gh --version | head -1
```

- 授权助手已存在但返回 `foreign` → **拒绝覆盖**，报告路径。
- 已有 GitHub CLI apt 源但内容不是官方那一行 → **停下**，可能是别人配的。

server 角色 + web 授权：必须让用户单独确认一次
「要在服务器上绑定个人 GitHub 账号」。这台机器可能不只他一个人用。
目标用户是 root 时额外警告：凭据和 SSH 密钥都会归 root。

## 2. 安装 Git 与 gh

GitHub CLI 的 keyring **必须校验指纹**，不能下载就用：

```bash
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git ca-certificates curl gnupg util-linux

curl -fsSL --connect-timeout 30 \
    https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /tmp/gh-key.gpg

# 只接受这两个官方指纹，其余一律中止
gpg --show-keys --with-colons /tmp/gh-key.gpg \
    | awk -F: '$1=="pub"{f=1;next} f&&$1=="fpr"{print $10;f=0}'
# 期望值：
#   2C6106201985B60E6C7AC87323F3D4EA75716059
#   7F38BBB59D064DBCB3D84D725612B36462313325

install -d -m 0755 /etc/apt/keyrings /etc/apt/sources.list.d
install -m 0644 /tmp/gh-key.gpg /etc/apt/keyrings/githubcli-archive-keyring.gpg

printf '# Managed by HAO\n# Service: git-github\ndeb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' \
    "$(dpkg --print-architecture)" > /etc/apt/sources.list.d/github-cli.list

apt-get update -qq
apt-get install -y -qq gh
```

指纹不匹配就中止并报告——这可能是中间人或源被换了。

## 3. 配置提交身份

以目标用户身份执行（root 直接跑会写到 root 的配置里）：

```bash
run_as_target() {
    if [ "$TARGET_USER" = "$(id -un)" ]; then HOME="$TARGET_HOME" "$@"
    else runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" "$@"; fi
}

# 先读现有身份
run_as_target git config --global --get user.name
run_as_target git config --global --get user.email
```

**已有身份且与用户给的不一致 → 停下来问**。直接改会让之后的提交换个人，
用户往往几周后才发现。确认后再写：

```bash
run_as_target git config --global user.name  "$GIT_NAME"
run_as_target git config --global user.email "$GIT_EMAIL"
```

作用域是 repository 就用 `git -C "$REPO_DIR" config --local`，
并先确认那是个 Git 仓库。

## 4. 预备 SSH 密钥（web 授权模式）

已有密钥就**保持不变**，不要覆盖——覆盖会让用户在其他机器/服务上的
授权全部失效：

```bash
[ -f "$TARGET_HOME/.ssh/id_ed25519" ] || [ -f "$TARGET_HOME/.ssh/id_rsa" ] || {
    run_as_target mkdir -p "$TARGET_HOME/.ssh"
    run_as_target chmod 700 "$TARGET_HOME/.ssh"
    run_as_target ssh-keygen -t ed25519 -N "" \
        -f "$TARGET_HOME/.ssh/id_ed25519" -C "${GIT_EMAIL}-hao" -q
}
```

私钥**不上传、不记入清单、不打印**。这一步只准备本地材料。

## 5. 装授权助手

把 `templates/gh-authorize.sh.tmpl` 逐字安装成
`/usr/local/bin/hao-github-authorize`（权限 0755，无需替换任何占位符）。

**授权本身不在部署流程里做**，因为它需要用户在浏览器里交互。部署完成后
告诉用户以目标用户身份运行：

```bash
hao-github-authorize
```

助手会做：web/设备码登录（附加 `admin:public_key` 权限）→ 注册 git 凭据助手
→ 上传公钥 → 验证 `ssh -T git@github.com`。上传失败时它会打印人工添加指引。

**不要代替用户输入凭据**，也不要引导用户创建长期 Personal Access Token。

## 6. 写 agent 约定

```bash
"$SKILL/scripts/hao-state.sh" convention HAO-GIT-GITHUB --user "$TARGET_USER" <<'EOF'
## Git / GitHub 操作约定（gh）

本机 GitHub 操作一律使用官方 GitHub CLI（`gh`），不要手写 GitHub REST/GraphQL
调用，也不要引导用户创建长期 Personal Access Token：

- PR：`gh pr create` / `gh pr view` / `gh pr checks` / `gh pr merge`。
- Issue：`gh issue create` / `gh issue list`。
- CI：`gh run list` / `gh run view` / `gh run watch`。
- Release：`gh release list` / `gh release view`（创建 release 前先确认项目的发布流程）。
- 需要裸 API 时用 `gh api`，它复用已有登录凭据。

授权与安全：

- 认证状态用 `gh auth status` 检查。未登录时提示用户运行 `hao-github-authorize`
  （web/设备码登录 + SSH Git 协议），不要代替用户输入凭据。
- 禁止在命令行、日志或提交内容中出现 token 值。
- Git 推送走 SSH 协议；提交身份已由系统配置好，不要擅自修改 `user.name` / `user.email`。
- 提交与 PR 前先运行项目自带的测试/检查（如有）。
EOF
```

## 7. 记录状态

```bash
"$SKILL/scripts/hao-state.sh" record git-github installed \
    managed:/etc/apt/sources.list.d/github-cli.list \
    managed:/etc/apt/keyrings/githubcli-archive-keyring.gpg \
    managed:/usr/local/bin/hao-github-authorize
"$SKILL/scripts/hao-state.sh" handoff
```

SSH 私钥**不进清单**。

## 汇报给用户

```
目标用户 / 机器角色 / 作用域 / 提交身份（名字和邮箱可以明示）
git 与 gh 版本
下一步：以 <目标用户> 身份运行 hao-github-authorize 完成登录
```

私有仓库的无人值守部署不该用个人授权，建议只读 Deploy Key 或 GitHub App。
公开仓库部署用 `skip` 就够。
