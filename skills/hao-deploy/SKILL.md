---
name: hao-deploy
description: 在一台 Debian/Ubuntu 服务器上部署网站和开发运维工具，面向不懂运维的用户。当用户想把自己的 Git 仓库变成能访问的网站、想在 VPS 上装 Nginx/Docker/Node 等工具、想更新或排查已部署的站点、或者接手一台别人（或以前的自己）部署过的服务器时使用。部署完成后会在主机上留下交接记录，任何后续 agent 都能照规则接手。
when_to_use: 用户说"帮我把这个仓库部署上线""在服务器上装个 nginx""我的站点打不开了""这台机器上装了什么""接手一下这台服务器"时触发。也适用于用户刚买了一台 VPS、想搭一个能干活或学习的环境。
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/hao-guard.sh *) Bash(${CLAUDE_SKILL_DIR}/scripts/hao-state.sh *) Bash(${CLAUDE_SKILL_DIR}/scripts/hao-secret.sh *)
---

# HAO 部署

把一台干净的 Debian/Ubuntu 服务器变成能用的东西：一个上线的网站，或者一台能
干活、能学习的机器。用户通常不懂运维，**你是执行者**，他只负责回答问题和拍板。

开始前先记下 skill 目录，后面所有脚本和模板都在这里：

```bash
SKILL="${CLAUDE_SKILL_DIR}"
```

## 前提：你必须在目标服务器上

`hao-deploy` 的所有操作都是本机操作。确认一下你在哪：

```bash
hostname; "$SKILL/scripts/hao-guard.sh" os-supported; id -u
```

如果这是用户自己的笔记本、而要部署的是一台远程 VPS，**先停下来**告诉用户：
需要先 `ssh` 到那台服务器、在服务器上启动 Claude Code，再让我干活。
在笔记本上跑这套流程只会把笔记本改坏。

`os-supported` 返回 `unsupported` 也停下来：支持 Debian 13/12 与
Ubuntu 26.04/24.04/22.04 LTS，别的系统不要硬上。

## 工作流程

### 1. 先弄清用户到底要什么

用户说的是目标（"我想让我的博客上线"），不是服务清单。你负责翻译：

| 用户想要 | 实际需要 |
|---|---|
| 让我的网站/博客上线 | `nginx` + `site`（node 类型再加 `node`） |
| 我要一台能跑 AI 工具的机器 | `node` + `uv` + `claude-code` |
| 我要跑容器化的服务 | `docker`（+ `nginx` 做反代） |
| 服务器刚买来，先弄安全点 | `maintenance` |
| 我要在服务器上用 git / GitHub | `git-github` |

问清缺失的关键信息，一次问完，不要来回挤牙膏。各模块要问什么，看对应的
reference。**不要替用户猜域名、Git 身份、仓库地址这类东西。**

### 2. 只读检查

动手前把该查的都查完（这些命令都是只读的，随便跑）：

```bash
"$SKILL/scripts/hao-state.sh" services     # 这台机器已经装了什么
"$SKILL/scripts/hao-state.sh" drift        # 有没有被手工改过
"$SKILL/scripts/hao-guard.sh" ...          # 目标资源归属，见各 reference
```

如果 `services` 显示这台机器已经被 HAO 管理过，先读
`/var/lib/hao/HANDOFF.md`，再看 `references/handoff.md` 的接手流程。

### 3. 讲清楚，然后拿到确认

把将要发生的系统变更用普通话讲一遍再动手。用户是小白，他无法从命令里看出
风险，这一步是他唯一的保护。具体要求见 `references/safety.md`。

### 4. 按 reference 执行

一个模块一份过程文档，照着做，不要凭记忆：

| 模块 | 文档 | 作用 |
|---|---|---|
| `maintenance` | `references/maintenance.md` | fail2ban、swap、journald 上限、Docker 日志轮转 |
| `nginx` | `references/nginx.md` | Nginx（nginx.org 源，含 HTTP/3）+ 内核调优 |
| `docker` | `references/docker.md` | Docker Engine + Compose 插件 |
| `node` | `references/node.md` | 系统级 Node.js LTS（落在 `/usr/bin`） |
| `uv` | `references/uv.md` | uv Python 管理器 + Python 使用约定 |
| `claude-code` | `references/claude-code.md` | Claude Code CLI + 网关/模型配置 |
| `git-github` | `references/git-github.md` | Git 身份、GitHub CLI、授权助手 |
| `site` | `references/site.md` | 从 Git 仓库部署静态站或 Node 站，含证书 |

另外几份跨模块文档：

- `references/handoff.md` —— 状态记录格式与交接契约（收尾必读）
- `references/safety.md` —— 完整安全契约
- `references/uninstall.md` —— 卸载流程。**只在用户明确要求时才读它**

配置文件内容全部在 `templates/`，把 `@@TOKEN@@` 换成实际值再写入。
**模板是内容的权威来源**，里面每一行都有原因，不要自己重写一份"差不多的"。
现有模板都不含密钥；一旦要写入含密钥的配置，用 `hao-secret.sh render` 渲染，
不要自己读出密钥再拼进去。

### 不在本 skill 范围内的事

HAO 只装**通用的运维底座**：Web 服务器、运行时、容器引擎、基础加固，以及从
用户自己的 Git 仓库部署站点。**具体第三方应用的部署过程不在这里**（模型网关、
论坛、面板这类）——它们各有自己的初始化流程、默认口令和数据迁移语义，
写成通用过程只会给出似是而非的步骤。

用户要装某个具体应用时：照 `docker` + `nginx` 打好底座，然后**按上游官方文档
部署**，并把这几件事当成必查项：

- 上游有没有**默认管理员口令**？有就必须在暴露到公网之前改掉，
  并在汇报里单独说这一条。
- 配置文件或 compose 里要填密码？用 `hao-secret.sh write` 生成、
  `hao-secret.sh render` 注入（模板里写 `@@KEY@@`），别把值读出来拼进去。
- 数据在哪（bind mount 还是 named volume）？销毁机器前要导出什么？
- 镜像 tag 别用 `latest`，让用户去上游 releases 挑一个固定 tag——
  否则同一份步骤两周后装出来的东西不一样。部署前用
  `docker manifest inspect <image>:<tag>` 确认 tag 还在，拉不到就停下来问用户，
  不要默默换一个。
- 容器端口一律绑 `127.0.0.1`，对外只走 Nginx 反代。

反代和证书照 `references/site.md` 第 4 节做，`@@SITE_ID@@` 用服务名。
收尾同样要 `hao-state.sh record` + `handoff`。

### 5. 验证

每一步都要拿到真实证据，不要因为命令退出码是 0 就报成功：

- 服务：`systemctl is-active`，以及端口真的在监听
- Nginx：`nginx -t` 通过，且 reload 成功
- 站点：能取到预期内容
- 调优项：回读实际生效值（例如 BBR 要看 `sysctl -n net.ipv4.tcp_congestion_control`）

失败就停下来如实汇报，把原始输出给用户。

### 6. 记录状态并交接（不可跳过）

```bash
"$SKILL/scripts/hao-state.sh" record <service> installed OWNERSHIP:PATH ...
"$SKILL/scripts/hao-state.sh" handoff
```

这一步是整个 skill 存在的理由之一：机器和会话都是即用即抛的，只有主机上的
记录能让下一个 agent 接手。归属类别怎么选、交接文档写了什么，
见 `references/handoff.md`。

**一个 service ID 只有一条记录**，`record` 是整体替换而不是追加。所以同一模块
可以部署多份的东西（站点就是），service ID 必须带上实例标识：`site-blog`、
`site-shop`，而不是都记成 `site`——都记成 `site` 会让先部署的那个静默从状态里
消失，之后 `drift` 再也不检查它。

## 三个必须走脚本的地方

其余步骤你直接用 shell 命令做就行。只有这三类事情不能即兴发挥：

| 脚本 | 为什么不能自己来 |
|---|---|
| `scripts/hao-secret.sh` | 密钥值绝不能进入对话记录。它负责生成、复用、注入，你只看到路径和 key 名 |
| `scripts/hao-state.sh` | 下一个 agent 要能**信任**状态记录。格式漂了，交接契约就废了 |
| `scripts/hao-guard.sh` | 覆盖前的归属判断。全部只读，返回 `foreign` 就必须停 |

三个脚本都支持 `-h` 查看用法。

## 硬规则

完整版见 `references/safety.md`，最关键的四条：

1. **改系统之前先讲清楚并取得确认**，只读检查不需要确认。
2. **`foreign` / `not-git` / `remote-mismatch` 一律停下**，绝不覆盖别人的东西，
   绝不 `rm -rf` 用户的目录。
3. **凭据只报路径**，永不打印内容；用户自带密钥走 `@file:` / `@env:`，
   不要放进命令行参数。
4. **如实汇报**。失败说失败，降级说降级，没生效说没生效。

## 收尾汇报

用普通话告一段，不要甩路径清单。至少包含：能怎么访问、之后怎么更新、
凭据文件在哪（只有路径）、有哪些需要他自己去做的事（比如放行 443 端口、
改 DNS）。

如果这台机器是用完就销毁的，提醒用户：**把部署时的那几个回答自己留一份**
（仓库地址、域名、类型、构建命令）。有了它们在新机器上重放一遍就行；
`/var/lib/hao` 里的状态会随机器一起消失。
