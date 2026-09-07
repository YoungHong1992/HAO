# git —— Git 与提交身份

装 git，并把提交身份写对。身份会进入每一个 commit，写错了要改历史才能修 ——
所以这份文档的重点不是安装（`apt-get install git` 而已），是身份。

要在这台机器上操作 GitHub（PR、issue、CI、推送），另外装 `gh`，
见 `references/gh.md`。

## 0. 这几件事必须问用户，一个都不能猜

| 要素 | 为什么不能猜 |
|---|---|
| 显示名 | 会写进每一个 commit，猜错了要改历史 |
| 邮箱 | 同上；且必须是 GitHub 已验证邮箱或 noreply 地址 |
| 目标系统用户 | 决定配置写到谁的 `~/.gitconfig` |
| 作用域（global / repository） | global 会影响这个用户的所有仓库 |

**绝不要**从登录名、主机名、仓库历史或机器上已有的 GitHub 账号推断身份。
邮箱要校验格式，名字里不能有换行。

## 1. 前置检查（只读）

```bash
command -v git >/dev/null && git --version

run_as_target() {
    if [ "$TARGET_USER" = "$(id -un)" ]; then HOME="$TARGET_HOME" "$@"
    else runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" "$@"; fi
}

run_as_target git config --global --get user.name
run_as_target git config --global --get user.email
```

`run_as_target` 不是多余的：以 root 直接跑 `git config --global` 会写到
`/root/.gitconfig`，用户用自己的账号提交时完全看不到效果，而命令退出码是 0。

**已有身份且与用户给的不一致 → 停下来问。** 直接改会让之后的提交换一个人，
用户往往几周后才发现，那时历史已经脏了。

## 2. 安装

```bash
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git
```

发行版自带的 git 够用，不要为它加第三方源。

## 3. 写提交身份

确认过之后：

```bash
run_as_target git config --global user.name  "$GIT_NAME"
run_as_target git config --global user.email "$GIT_EMAIL"
```

作用域是 repository 就改用 `git -C "$REPO_DIR" config --local`，并先确认那个目录
真的是个 Git 仓库：

```bash
run_as_target git -C "$REPO_DIR" rev-parse --is-inside-work-tree   # 期望输出 true
```

**这里不要用 `hao-guard.sh repo-identity`** —— 它要两个参数（`<dir> <expected_remote>`），
少给会直接报错退出；而"这个目录是不是仓库"这个问题本来也不需要知道预期 remote。
`repo-identity` 是给 site 流程用的（那里确实有预期 remote）。

## 4. 验证

```bash
git --version
run_as_target git config --global --get user.name     # 回读
run_as_target git config --global --get user.email
```

回读必须走 `run_as_target`。以 root 读出来的是 root 的配置，那不是我们要的证据。

## 5. 记录状态

```bash
"$SKILL/scripts/hao-state.sh" record git installed \
    "shared:$TARGET_HOME/.gitconfig"
"$SKILL/scripts/hao-state.sh" intent git \
    target_user="$TARGET_USER" scope=global \
    git_name="$GIT_NAME" git_email="$GIT_EMAIL"
"$SKILL/scripts/hao-state.sh" handoff
```

身份进意图文件是刻意的：它本来就会出现在每个 commit 里，不是密钥，而换机器时
必须原样重放（猜错要改历史）。

`.gitconfig` 记 `shared` 而不是 `managed`：这是用户的文件，我们只写了
`user.name` 和 `user.email` 两个键，下一个 agent 不能整体重写它。作用域是
repository 时记的是那个仓库的 `.git/config`，同样是 `shared`。

## 汇报给用户

```
目标用户 / 作用域 / 提交身份（名字和邮箱可以明示，它们本来就会进每个 commit）
git 版本
```
