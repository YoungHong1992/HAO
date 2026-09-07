# gh —— GitHub CLI 与授权

装官方 GitHub CLI（`gh`）、装授权助手、写「本机 GitHub 操作一律走 gh」的 agent
约定。提交身份不在这里，属于 `git`，见 `references/git.md`。

## 0. 这几件事必须问用户

| 要素 | 为什么不能猜 |
|---|---|
| 目标系统用户 | 决定 gh 凭据和 SSH 密钥归谁 |
| 机器角色（workstation / server） | server 上做个人授权需要额外确认 |
| 授权方式（web / skip） | 服务器上部署公开仓库通常该用 skip |

server 角色 + web 授权：必须让用户**单独确认一次**「要在这台服务器上绑定个人
GitHub 账号」。这台机器可能不只他一个人用，而 gh 凭据能读到他名下所有仓库。
目标用户是 root 时额外警告：凭据和 SSH 密钥都会归 root。

## 1. 前置检查（只读）

```bash
"$SKILL/scripts/hao-guard.sh" managed-file /usr/local/bin/github-authorize
command -v gh >/dev/null && gh --version | head -1
cat /etc/apt/sources.list.d/github-cli.list 2>/dev/null
```

- 授权助手已存在但返回 `foreign` → **拒绝覆盖**，报告路径。
- 已有 GitHub CLI apt 源但内容不是官方那一行 → **停下**，可能是别人配的。

## 2. 装 gh

keyring **必须校验指纹**，不能下载就用：

```bash
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg util-linux

curl -fsSL --connect-timeout 30 \
    https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /tmp/gh-key.gpg

# 只接受这两个官方指纹，其余一律中止。**要真的比对，不是打印出来看一眼**：
GH_FPR_OK="2C6106201985B60E6C7AC87323F3D4EA75716059 7F38BBB59D064DBCB3D84D725612B36462313325"
GH_FPR="$(gpg --show-keys --with-colons /tmp/gh-key.gpg \
    | awk -F: '$1=="pub"{f=1;next} f&&$1=="fpr"{print $10;f=0}')"
matched=0
for got in $GH_FPR; do
    for want in $GH_FPR_OK; do
        [ "$got" = "$want" ] && matched=1
    done
done
[ "$matched" = 1 ] || {
    rm -f /tmp/gh-key.gpg
    echo "GitHub CLI keyring 指纹不匹配，实际: $GH_FPR —— 中止，不要装" >&2
    exit 1
}

install -d -m 0755 /etc/apt/keyrings /etc/apt/sources.list.d
install -m 0644 /tmp/gh-key.gpg /etc/apt/keyrings/githubcli-archive-keyring.gpg
rm -f /tmp/gh-key.gpg

printf '# Managed by HAO\n# Service: gh\ndeb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' \
    "$(dpkg --print-architecture)" > /etc/apt/sources.list.d/github-cli.list

apt-get update -qq
apt-get install -y -qq gh
```

指纹不匹配就**中止并报告** —— 那可能是中间人，也可能是源被换了。
不要"先装上再说"。

## 3. 预备 SSH 密钥（web 授权模式）

已有密钥就**保持不变，不要覆盖** —— 覆盖会让用户在其他机器和服务上的授权全部
失效，而且他不会立刻发现：

```bash
[ -f "$TARGET_HOME/.ssh/id_ed25519" ] || [ -f "$TARGET_HOME/.ssh/id_rsa" ] || {
    run_as_target mkdir -p "$TARGET_HOME/.ssh"
    run_as_target chmod 700 "$TARGET_HOME/.ssh"
    run_as_target ssh-keygen -t ed25519 -N "" \
        -f "$TARGET_HOME/.ssh/id_ed25519" -C "${GIT_EMAIL}-hao" -q
}
```

`run_as_target` 的定义在 `references/git.md` 第 1 节。私钥**不上传、不记入清单、
不打印**，这一步只准备本地材料。

## 4. 装授权助手

把 `templates/gh-authorize.sh.tmpl` 逐字安装成
`/usr/local/bin/github-authorize`（权限 0755，无需替换任何占位符）。

**授权本身不在部署流程里做**，因为它需要用户在浏览器里交互。部署完成后告诉用户
以目标用户身份运行：

```bash
github-authorize
```

助手会做：web/设备码登录（附加 `admin:public_key` 权限）→ 注册 git 凭据助手 →
上传公钥 → 验证 `ssh -T git@github.com`。上传失败时它会打印人工添加指引。

**不要代替用户输入凭据**，也不要引导用户创建长期 Personal Access Token。

## 5. 写 agent 约定

```bash
"$SKILL/scripts/hao-state.sh" convention HAO-GH --user "$TARGET_USER" <<'EOF'
## GitHub 操作约定（gh）

本机 GitHub 操作一律使用官方 GitHub CLI（`gh`），不要手写 GitHub REST/GraphQL
调用，也不要引导用户创建长期 Personal Access Token：

- PR：`gh pr create` / `gh pr view` / `gh pr checks` / `gh pr merge`。
- Issue：`gh issue create` / `gh issue list`。
- CI：`gh run list` / `gh run view` / `gh run watch`。
- Release：`gh release list` / `gh release view`（创建 release 前先确认项目的发布流程）。
- 需要裸 API 时用 `gh api`，它复用已有登录凭据。

授权与安全：

- 认证状态用 `gh auth status` 检查。未登录时提示用户运行 `github-authorize`
  （web/设备码登录 + SSH Git 协议），不要代替用户输入凭据。
- 禁止在命令行、日志或提交内容中出现 token 值。
- Git 推送走 SSH 协议；提交身份已由系统配置好，不要擅自修改 `user.name` / `user.email`。
- 提交与 PR 前先运行项目自带的测试/检查（如有）。
EOF
```

## 6. 验证

```bash
gh --version                                # 必须有输出
[ -x /usr/local/bin/github-authorize ]  # 助手可执行
gh auth status || true                      # 未登录是预期的
```

`gh auth status` 说未登录**不是失败** —— 授权是用户下一步自己要做的事。汇报时
说清这一点，不要写成"GitHub 已配好"。

## 7. 记录状态

```bash
"$SKILL/scripts/hao-state.sh" record gh installed \
    managed:/etc/apt/sources.list.d/github-cli.list \
    managed:/etc/apt/keyrings/githubcli-archive-keyring.gpg \
    managed:/usr/local/bin/github-authorize
"$SKILL/scripts/hao-state.sh" intent gh \
    target_user="$TARGET_USER" machine_role="$ROLE" auth_mode="$AUTH_MODE"
"$SKILL/scripts/hao-state.sh" handoff
```

SSH 私钥**不进清单**。`auth_mode` 是 `web` 或 `skip`，它决定新机器上要不要重做授权。

## 汇报给用户

```
目标用户 / 机器角色 / 授权方式
gh 版本
下一步：以 <目标用户> 身份运行 github-authorize 完成登录
```

私有仓库的无人值守部署不该用个人授权，建议只读 Deploy Key 或 GitHub App。
公开仓库部署用 `skip` 就够。
