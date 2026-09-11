# 交接契约

这台机器可能是即用即抛的，但**接手的 agent 一定不是同一个**。部署完成后，
原始对话就消失了。所以这台主机自己必须能回答三个问题：装了什么、凭据在哪、
什么能改什么不能碰。

这份契约就是那个答案的格式。所有写入都通过 `scripts/hao-state.sh`，
不要手写 `/var/lib/hao` 下的任何文件。

## 状态目录布局

```
/var/lib/hao/
├── NOTICE                      给人看的说明
├── HANDOFF.md                  给下一个 agent 看的交接文档（自动生成）
├── DEPLOY-INTENT.md            给用户带走的部署意图（自动生成，不含密钥）
├── manifest.json               汇总清单，schema_version 1
└── services/
    ├── <service>.json          单服务记录
    ├── <service>.resources     资源清单（TSV: ownership 哈希 路径）
    └── <service>.intent        部署意图（TSV: key 值，不含密钥）
```

用 `HAO_STATE_DIR` 可以整体改位置（测试时用）。

记录里只有**资源路径、归属类别、内容哈希**。配置值不进去，密钥内容更不进去。
凭据文件只登记路径，哈希恒为 `redacted`。

### 为什么状态在 `/var/lib/hao` 而凭据在 `/etc/hao`

分开放不是随意的，判据是**可再生性**和**暴露等级**，两者一致的才该同处一树：

| 类别 | 可再生？ | 该被读到？ | 位置 |
|---|---|---|---|
| 状态索引、交接文档、意图 | 是（重跑 `record` / `intent`） | 是（0644） | `/var/lib/hao` |
| 凭据 | **否**（重新生成等于换密码） | 否（0600，目录新建时 0700） | `/etc/hao` |

凭据目录的权限有一个前提要说清：`hao-secret.sh` 只在**目录不存在**时用 0700 新建；
目录已经存在时它**只告警、不改权限**（目标可能是 `/etc/foo.env` 这种直接落在 `/etc`
下的路径，chmod 会把 `/etc` 改成 0700，后果比元信息泄露严重得多）。
所以看到那条告警要照它的建议手动 `chmod 0700 <目录>`，不要以为脚本已经处理了。

`/var/lib` 按惯例是"可丢弃的再生状态"，备份和配置管理经常整体排除它；凭据丢了
服务就废了，不能和可再生的东西共命运。而且 `/var/lib/hao` 里的 `NOTICE`、
`HANDOFF.md`、`manifest.json` 是**故意**可读的，把 0600 的密钥塞进一棵默认可读的
树，是把两个暴露等级混在一起。

### `/var/lib/hao` 是索引，不是容器

这里**不持有**被部署的资源，只持有"资源在哪、归谁、内容哈希是什么"的记录。
vhost 在 `/etc/nginx`、单元文件在 `/etc/systemd/system`、apt 源在 `/etc/apt`——
那些位置是消费它们的程序规定的，挪进 `/var/lib/hao` 只会让 nginx 找不到配置。
想知道 HAO 动过哪些文件，查 `manifest.json`，不要指望目录里能翻出来。

## manifest.json

```json
{
  "schema_version": 1,
  "managed_by": "HAO",
  "generated_at": "2026-09-05T14:04:47Z",
  "services": [
    {
      "schema_version": 1,
      "managed_by": "HAO",
      "service": "site-blog",
      "release": "skill",
      "recorded_at": "2026-09-05T14:04:18Z",
      "result": "installed",
      "ownership": "managed",
      "resources": [
        {"path": "/etc/nginx/conf.d/blog.example.com.conf", "ownership": "managed", "sha256": "c467…"},
        {"path": "/opt/blog", "ownership": "observed", "sha256": "directory"},
        {"path": "/etc/hao/blog.env", "ownership": "secret", "sha256": "redacted"}
      ]
    }
  ]
}
```

`result` 取值：`installed` `updated` `verified` `failed` `skipped`。怎么选：

| 情况 | 用哪个 |
|---|---|
| 第一次装好 | `installed` |
| 已经装过、这次重新部署或改了配置 | `updated` |
| 只做了检查、没改任何东西 | `verified` |
| 中途失败，机器处于半成品状态 | `failed`（**要记**，别只在对话里说） |
| 归属检查拦住了，或用户拒绝了 | `skipped` |

一律写 `installed` 会让下一个 agent 无法判断这台机器上次到底发生了什么。

### `result` 写错了怎么改：`amend`，不要重跑 `record`

```bash
"$SKILL/scripts/hao-state.sh" amend <service> --result <合法词>
```

`record` 是**整体替换**，所以拿它去改一个词，就必须把该服务的全部资源重新列一遍
——少列一个就静默丢掉一个资源。而"改 result"这件事最常发生在接手一台旧机器、
发现存量记录里有非法值的时候，那时资源清单恰好是唯一的事实来源，最不该重打一遍。
`amend` 只改那一个词，资源与哈希原样保留，`recorded_at` 也不动（哈希是那个时刻算
的，改一个词不该让它看起来像刚重新采集过）。

`services` 会自动点出 result 不合法的记录（早期版本写过 `success` 这类词），
并直接给出对应的 `amend` 命令。**读到非法 result 就意味着这条记录不可信**，
先修正再据它做判断。

### `installed` 不等于"真的能用"：接手时要抽查一次

`record` 只检查它**列出的资源路径**是否存在，没有"这个服务本身可用吗"的概念。
真实踩过的坑：某台机器的记录写着 `docker installed`，而机器上既没有 docker 二进制、
也没有对应的 unit——那条记录的资源只有一个 `daemon.json`，文件确实在，于是记录
"看起来"是自洽的。下一个 agent 读到它就会以为能用 docker。

所以接手时对每个 `installed` / `updated` 的服务抽查一次，命令按服务性质选：

```bash
command -v docker nginx node uv gh git certbot 2>/dev/null   # 该有的二进制在不在
systemctl is-active nginx fail2ban 2>/dev/null               # 该跑的服务在不在跑
```

对不上就**先把记录改成实情**（`amend` 成 `skipped` 或 `failed`），再告诉用户，
不要带着一条已知不实的记录继续往下做。

### 漏跑 `record` 的反查：`orphans`

```bash
"$SKILL/scripts/hao-state.sh" orphans          # 也可以 orphans <目录>... 指定范围
```

漏跑一次 `record` 的后果是**静默**的：文件在主机上、`# Managed by HAO` 归属头也在，
但 `drift` 不看它、`manifest.json` 里没有它、卸载流程也不会带走它。归属头正是反查
这类漏记的钩子——`hao-guard.sh` 靠它判归属，`orphans` 靠它对账，扫的是 HAO 可能
写入的那几个目录（`/etc/nginx`、`/etc/apt`、`/etc/systemd/system`、`/usr/local/bin`…）。

列出来的每一个，要么补进对应服务的 `record`（记得把该服务原有的资源一起列上），
要么确认可以删。`*.bak.*` / `*.disabled` 会被单独标注：那通常是回滚备份或停用件，
确认线上配置无误后可以删。

### `record` 只记录**当时真的存在**的路径

不存在的路径会被静默丢掉，并在输出里打一行 `跳过不存在的路径: …`。
那行不是提示，是**证据**：它说明你以为写好的文件其实没写成（或路径写错了）。
看到它就回去查那一步，不要继续往下走。

### `ownership <service>`

回答"这个服务归谁"最省事的一条命令，输出是归属类别，服务没记录过时输出 `untracked`。
`drift` 之前想快速确认"我能不能动这个"就用它。

## 归属类别（决定你能对一个资源做什么）

| 类别 | 含义 | 允许的操作 |
|---|---|---|
| `managed` | HAO 创建并负责 | 可按流程重写；但发现漂移要先问用户 |
| `shared` | HAO 改过、但属于系统 | 只能改自己那部分，**不可整体覆盖** |
| `observed` | 仅记录，不属于 HAO | 只读。内容由别人决定 |
| `secret` | 凭据文件 | 只汇报路径，**永不读取或打印内容** |

选错类别的后果很具体：把用户的代码目录记成 `managed`，`drift` 会天天误报；
把别人的配置记成 `managed`，下一个 agent 会理所当然地覆盖它。

判断依据：**这个文件的内容是不是完全由 HAO 决定？** 是 → `managed`；
由用户的仓库或别的程序决定 → `observed`。

## 每次部署收尾必做

```bash
"$SKILL/scripts/hao-state.sh" record <service> installed OWNERSHIP:PATH ...
"$SKILL/scripts/hao-state.sh" handoff
```

### 一个 service ID 只有一条记录

`record` 是**整体替换**，不是追加：同一个 service ID 记第二次，第一次的资源清单
就没了。所以凡是同一模块可以部署多份的东西，service ID 必须带实例标识：

| 模块 | service ID |
|---|---|
| 单例模块（nginx、docker、node、uv、fail2ban…） | 模块名本身 |
| `site`（一台机器可以有多个站点） | `site-<站点ID>`，如 `site-blog` |

都记成 `site` 的后果很隐蔽：先部署的站点从状态里消失，`drift` 从此不检查它的
nginx 配置和更新脚本，`HANDOFF.md` 里也只剩一行。等到有人手工改坏那个站点
而 `drift` 一声不响时才会发现。

### handoff 做两件事

`handoff` 做两件事（并顺带重建 `manifest.json`）：

1. 生成 `/var/lib/hao/HANDOFF.md`（当前服务表、凭据路径、接手规则、可用的
   更新命令）；
2. 检测本机 AI 助手的全局指令文件，往里面写一个带标记的指针块，指向 HANDOFF.md。
   检测走两条路，都不绑定具体 runtime：已知配置目录约定，以及扫描 home 下点目录里
   已经存在的 `AGENTS.md` / `CLAUDE.md`。两条都没覆盖到的 runtime，
   用 `--agent-file PATH` 显式指定（可重复）。

第 2 步是整套设计的关键：**下一个 agent 不需要被谁告知，开机就知道这台机器
由 HAO 管理**。标记块用
`<!-- HAO-HANDOFF BEGIN (managed by HAO, do not edit inside) -->` 与
`<!-- HAO-HANDOFF END -->` 包裹（手工要删块时按这两行**原文**去找），重复运行原地
替换，块外的用户内容一律保留。发现标记只剩单边（文件被手工改坏）会拒绝写入
而不是吞掉内容。

**默认写进谁的指令文件：`${SUDO_USER:-root}`。** 以 root 直接跑（新买的 VPS 上
最常见）时它就是 root，于是只会去 `/root` 下找 `AGENTS.md` / `CLAUDE.md`，
用户自己家目录里的那份**收不到指针块**，而输出只会说一句"未检测到已安装的 AI 助手"。
所以目标用户不是 root 时必须显式传：

```bash
"$SKILL/scripts/hao-state.sh" handoff --user "$TARGET_USER"
```

用和 `convention` 同一个用户。不想写指令文件时用 `--skip-agent-files`；
runtime 的位置不在检测范围内时用 `--agent-file PATH`（可重复）。

## 接手一台已有机器时

先看这台机器说了什么，再动手：

```bash
cat /var/lib/hao/HANDOFF.md                      # 先读这个
"$SKILL/scripts/hao-state.sh" services           # 装了什么（顺带点出不合法的 result）
"$SKILL/scripts/hao-state.sh" drift              # 有没有被手工改过
"$SKILL/scripts/hao-state.sh" orphans            # 有没有 HAO 写过却没记录的文件
"$SKILL/scripts/hao-state.sh" credentials        # 凭据在哪（只有路径）
```

这四条覆盖的是四种不同的不一致，缺一条就会漏掉一类：

| 命令 | 回答的问题 | 不一致的表现 |
|---|---|---|
| `services` | 记录本身可不可信 | result 是早期版本写的非法词 |
| `drift` | 记录里的文件被改过没有 | managed 资源哈希不符 |
| `orphans` | 有没有该记而没记的文件 | 带归属头却不在任何记录里 |
| 抽查 `command -v` / `is-active` | 记录说装了的东西真的在吗 | 幻影服务（见上一节） |

`drift` 报告了 managed 资源变化，说明**有人手工改过 HAO 管理的文件**。
停下来把差异讲给用户听，让用户决定是保留手工改动还是按 HAO 流程重写。
直接覆盖会静默丢掉那些改动——这类丢失通常几周后才被发现。

`drift` 退出码：0 = 无漂移，非 0 = 有漂移。**所以不要用 `drift && 下一步` 串命令**——
有漂移时后面那步会被静默跳过，而那正是最需要人介入的时候。

**`drift` 只比对 `managed` 资源。** `shared`（如 `/etc/fstab`、`.gitconfig`）、
`observed`（如 `/opt/<站点>`、`/usr/bin/node`）、`secret`（凭据）都不参与比对：
前两类的内容本来由别人决定，后一类不记哈希。所以"drift 干净"的含义是
"HAO 自己写的文件没被人动过"，不等于"这台机器没被人动过"。
一个 `managed` 资源都没有的服务（例如 `uv`）永远显示正常。

### 接手一台跑过更早版本（CLI 形态）HAO 的机器

更早的版本是一套 CLI（用一个 `hao` 命令跑 plan / apply 这类子命令），它的记录格式
与主机布局跟现在不同，而它留下的东西**不会自己消失**。其中一类特别隐蔽：
**旧 service ID 在新版里没有对应模块**——`services` 只会点出非法的 `result`，
不会告诉你这个 ID 该往哪映射。逐条对一遍：

- 旧的 `git-github` 一条记录把 git 和 gh 合在一起，新版是**两个**独立模块。按
  `references/git.md` / `references/gh.md` 分别记 `git` 与 `gh`，然后
  `hao-state.sh remove git-github` 把旧记录清掉——否则 `drift` 会一直报它缺失。
  合并记录丢掉的正是「单独卸载、单独查漂移」这两件事。
- 旧版写的主机文件带 `hao-` 前缀和旧 service 名：授权助手在
  `/usr/local/bin/hao-github-authorize`，新版逐字安装成
  `/usr/local/bin/github-authorize`、归属头是 `# Service: gh`。改名后**旧文件要删掉**
  （通用命名是刻意的约定），apt 源那几行的 `# Service:` 也一并改成新 service ID，
  否则下一个 agent 的归属判断和 `orphans` 对账都会对不上。
- 旧版把凭据放在服务目录里（例如 compose 目录下的 `hao-credentials.txt`），新版约定是
  `/etc/hao`。**不要为了迁就约定去搬一个可能正被服务读着的凭据文件**：先确认没有程序
  按旧路径读它，确认不了就留在原地、按 `secret` 记它的真实路径，并在交接里写明。
- `/var/lib/hao/NOTICE` 会被下一次 `record` 自动重写成新版文案，不需要手工处理。
- 旧版在 `/opt` 下留的产物（服务目录、`*.bak.*`）：默认扫描覆盖 `/opt` 的三层深度
  （`/opt/<服务>/<文件>` 够用）。更深的位置要显式 `hao-state.sh orphans /opt`
  ——显式传目录是整棵递归，慢。

清理旧记录用 `hao-state.sh remove <service>`：它会先检查该服务的资源是否都还在主机上，
还在就拒绝删除（除非显式 `--force`），避免"服务还在、记录先没了"。

## 机器销毁后还剩什么

`/var/lib/hao` 随机器一起消失。真正需要跨机器存活的是**部署意图**，不是状态。
所以凡是问过用户的那些回答，收尾时都要记进意图文件：

```bash
"$SKILL/scripts/hao-state.sh" intent site-blog \
    type=static \
    repo="$REPO" \
    branch="$BRANCH" \
    domain="$DOMAIN" \
    build_cmd="$BUILD_CMD" \
    output_dir="$OUTPUT" \
    run_user="$TARGET_USER" \
    cert=letsencrypt
```

规则：

- key 必须**以小写字母开头**，其余只能是小写字母、数字、下划线（`^[a-z][a-z0-9_]*$`）。
  `2fa_mode` 这种以数字开头的会被拒。service ID 和 `record` 用同一个
  （站点是 `site-<id>`），这样卸载时删 `services/<svc>.*` 会把意图一起带走。
- **凭据一律不许进去。** key 名里**含有** `password` / `passwd` / `token` / `secret` /
  `apikey` / `api_key` / `credential` / `private_key` 任一子串的会被直接拒绝——
  这份文件是 0644 且要交给用户带走的。匹配是子串而非整词，所以 `token_ttl`、
  `password_policy` 这类无害的名字也会被拒，换个词（`ttl_seconds`、`login_policy`）。
- 仓库地址里内嵌的凭据会被自动脱敏成 `***`，落盘和文档里都不会有原值。
  重放时需要用户重新提供。
- `intent` 会重建 `DEPLOY-INTENT.md`；`handoff` 也会重建一次，所以顺序无所谓。
- **凡是问过用户的回答都要记**，不是只有 site 模块要记：git 的身份、gh 的目标用户与
  授权方式、claude-code 的网关与模型、node 的主版本、swap 的大小、uv 的 Python 版本、
  fail2ban 的 SSH 端口，各模块的 reference 里都给了对应的 `intent` 行。

**收尾汇报必须让用户把 `DEPLOY-INTENT.md` 存到他自己的笔记或仓库里。**
有了它，在一台新机器上重放一遍就能得到等价的部署——这就是"即用即抛"成立的前提。
只留在 `/var/lib/hao` 里等于没留。

凭据不属于可重放的部分：新机器上会重新生成。用户如果需要保留旧密码，
必须在销毁机器前自己从凭据文件导出（路径见 `credentials`，内容要他自己去取）。
销毁前提醒一次。
