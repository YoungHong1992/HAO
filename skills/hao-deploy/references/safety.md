# 安全契约

以前这些约束由 CLI 的 `--yes` 开关和脚本里的 guard 强制执行。现在**执行者是你**，
所以它们变成了你必须自己守住的行为规则。用户是小白，他没有能力审查你下一步
要动什么——这不是可以放松要求的理由，恰恰相反。

## 动手之前

**任何会改变系统的操作之前，先讲清楚再做。** 用普通话讲，不要甩一串命令：

> 我接下来会：安装 Nginx（会添加一个软件源）、修改内核网络参数、
> 把你的博客代码克隆到 /opt/blog、申请一张 HTTPS 证书。
> 大约需要 3 分钟。要继续吗？

需要显式确认的操作：

- `apt-get install` / 添加软件源
- `systemctl enable` / `restart` / 写 systemd 单元
- 写 `/etc/nginx`、`/etc/docker`、`/etc/sysctl.d`、`/etc/security/limits.d`
- 申请或替换 SSL 证书
- 克隆任意仓库、并执行用户给的构建命令（构建命令等于任意代码执行）
- 改动 SSH、防火墙、fail2ban 等会影响你自己登录能力的东西

只读命令（`hao-guard.sh` 全部子命令、`hao-state.sh drift/services/credentials`、
`nginx -t`、`systemctl status`、`journalctl`）不需要确认，放心多跑。

## 绝不覆盖不属于自己的东西

动任何目标路径之前先判断归属：

```bash
"$SKILL/scripts/hao-guard.sh" managed-file <path>          # missing / managed / foreign
"$SKILL/scripts/hao-guard.sh" vhost-owner <server_name>    # free / hao-site / hao / foreign
"$SKILL/scripts/hao-guard.sh" unit-free <unit_name>        # 同一套输出词汇
"$SKILL/scripts/hao-guard.sh" repo-identity <dir> <remote> # absent / ok / not-git / remote-mismatch
```

返回 `foreign`、`not-git`、`remote-mismatch` 一律**停下来**，把路径报给用户，
让用户决定。不要 `rm -rf`，不要"顺手清理一下"。那可能是用户自己放的东西，
也可能是另一套线上服务。

`unit-free` 单独说一句：站点的 systemd 单元用通用命名 `<id>.service`，而
`/etc/systemd/system/<name>.service` 会**静默覆盖**发行版的同名单元。站点 ID
撞上 `nginx` 就会把 Nginx 的单元顶掉，不报错。写单元前必须先问这一句。

覆盖 `managed` 资源之前先跑 `hao-state.sh drift`。有漂移说明有人手工改过，
先解释差异再问用户。

## 密钥

规则要守住的是一件具体的事：**密钥值不得进入对话记录、日志，也不得进入
命令行参数**（`ps` 和 `/proc/<pid>/cmdline` 对同机任意用户可见）。

- **永不打印、永不转述凭据文件内容。** 汇报只给路径。
- 需要生成密钥就用 `scripts/hao-secret.sh write`，它会生成并写入 0600 文件，
  值不经过你的上下文。
- 需要把密钥注入配置文件就用 `hao-secret.sh render`，模板里写 `@@KEY@@`。
  不要自己读出来再拼进去。
- 用户自带的密钥用 `KEY=@file:PATH` 或 `KEY=@env:VAR` 传入。**不要**放在命令行
  参数里。`hao-secret.sh` 会直接拒绝字面量。
- **确实需要把值取出来喂给某个程序时**（例如深合并 JSON，`render` 帮不上忙），
  唯一可接受的形式是：`VAR="$(...)" program`，值只经过环境变量，
  不落到 argv、不落到 stdout、不落到你的汇报里。`references/claude-code.md`
  第 2 节是这条例外的范本。除此之外不要读凭据文件。
- 用户在对话里直接贴了密码：不要复述，提醒他这条消息已经留在记录里了，
  必要时建议改掉。
- 仓库地址里可能内嵌 token，日志和汇报一律脱敏：
  `sed -E 's#(://)[^/@]+@#\1***@#'`
- **部署意图文件里绝不能有凭据。** `hao-state.sh intent` 生成的
  `DEPLOY-INTENT.md` 是 0644、而且要交给用户带离本机的。脚本会拒绝明显是密钥的
  key 名、并自动脱敏 URL 里内嵌的凭据，但别去试探这条边界：意图记的是
  "怎么重放"，密码不属于可重放的东西。

## 幂等

重跑一次必须安全。具体来说：

- 生成密钥前先复用已有的（`hao-secret.sh` 默认就这么做，别用 `--rotate` 绕过）
- node 站点先用 `hao-guard.sh unit-port` 读回既有端口，不要每次换端口
- 已经是真实 Let's Encrypt 证书就不要重复申请（有速率限制）
- 配置文件原地重写，不要每次追加

## 不该做的事

除非用户明确要求那个具体操作，否则不做：

- 卸载服务、删除 Docker volume、删除 SSL 文件、删除服务目录
- 改 SSH 端口 / 禁用密码登录 / 改防火墙默认策略（会把用户自己锁在门外）
- 替换生产环境已有的证书
- 为了"清理干净"而删除任何非 HAO 创建的文件

## 如实汇报

- `nginx -t` 失败就说失败，把原始输出给用户，不要说"配置已写入"。
- 证书降级成自签名就说是自签名，不要说"HTTPS 已配好"。
- BBR 没开启就说没开启（内核太旧），不要因为文件写成功了就报成功。
- 端口没监听起来就停下来，不要继续往下走完剩下的步骤。

半途失败时，先把已经改了什么讲清楚，再说下一步建议。用户最怕的是不知道
机器现在处于什么状态。

## 跳转那一条单独强调

启用 80→443 跳转前必须确认云安全组放行了 443。没确认就别开。
详见 `references/site.md` 的 522 教训——这是最容易把小白站点搞成完全不可访问的
一步，而且故障现象和原因看起来毫不相关。
