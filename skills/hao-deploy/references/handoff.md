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
| 凭据 | **否**（重新生成等于换密码） | 否（0600，目录 0700） | `/etc/hao` |

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

`result` 取值：`installed` `updated` `verified` `failed` `skipped`。

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
由 HAO 管理**。标记块用 `<!-- HAO-HANDOFF BEGIN/END -->` 包裹，重复运行原地
替换，块外的用户内容一律保留。发现标记只剩单边（文件被手工改坏）会拒绝写入
而不是吞掉内容。

不想写指令文件时用 `--skip-agent-files`；要指定文件用 `--agent-file PATH`
（可重复）。

## 接手一台已有机器时

先看这台机器说了什么，再动手：

```bash
cat /var/lib/hao/HANDOFF.md                      # 先读这个
"$SKILL/scripts/hao-state.sh" services           # 装了什么
"$SKILL/scripts/hao-state.sh" drift              # 有没有被手工改过
"$SKILL/scripts/hao-state.sh" credentials        # 凭据在哪（只有路径）
```

`drift` 报告了 managed 资源变化，说明**有人手工改过 HAO 管理的文件**。
停下来把差异讲给用户听，让用户决定是保留手工改动还是按 HAO 流程重写。
直接覆盖会静默丢掉那些改动——这类丢失通常几周后才被发现。

`drift` 退出码：0 = 无漂移，非 0 = 有漂移。

### 碰到已经不存在的模块名

早期版本把多个工具打包成一个模块，所以旧机器上可能有这些 service ID：

| 旧 service ID | 现在对应的模块 |
|---|---|
| `maintenance` | `fail2ban` + `swap` + `journald`，Docker 日志轮转归 `docker` |
| `git-github` | `git` + `gh` |

**没有自动迁移**，也不要就着旧 ID 继续 `record` —— 那会让状态里同时存在两套命名，
下一个 agent 无从判断哪个是真的。碰到时这样处理：

```bash
# 1. 先看旧记录里都有什么资源，按新模块归类
cat /var/lib/hao/services/maintenance.resources

# 2. 按新模块各记一条（路径照旧记录里的，别凭记忆写）
"$SKILL/scripts/hao-state.sh" record fail2ban installed managed:/etc/fail2ban/jail.d/hao-sshd.local
"$SKILL/scripts/hao-state.sh" record journald installed managed:/etc/systemd/journald.conf.d/hao.conf
"$SKILL/scripts/hao-state.sh" record swap     installed managed:/etc/sysctl.d/99-hao-swap.conf shared:/etc/fstab

# 3. 确认新记录都在了，再删旧的
rm -f /var/lib/hao/services/maintenance.json \
      /var/lib/hao/services/maintenance.resources \
      /var/lib/hao/services/maintenance.intent
"$SKILL/scripts/hao-state.sh" handoff
```

顺序不能颠倒：先记新的再删旧的，中途失败也不会丢掉资源清单。

主机上的文件本身**不用动**（路径没变，只是归属记录换了名字），但那几个文件的
`# Service: maintenance` 注释头会和新记录对不上。`hao-guard.sh` 判归属只看
`Managed by HAO`，所以不影响拒绝覆盖的保证；重写那个文件时顺手把头改对即可。

`git-github` 还多一件事：agent 指令文件里的 `<!-- HAO-GIT-GITHUB BEGIN/END -->`
块不会被 `convention HAO-GH` 替换（标记名就是块的身份），所以会**多出一个块**。
手工删掉旧的那个，从 BEGIN 到 END 连同标记一起删，块外内容不要动。

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
    run_user="$USER" \
    cert=letsencrypt
```

规则：

- key 只允许小写字母、数字、下划线；service ID 和 `record` 用同一个
  （站点是 `site-<id>`），这样卸载时删 `services/<svc>.*` 会把意图一起带走。
- **凭据一律不许进去。** key 名里带 `password` / `token` / `secret` / `apikey` 之类的
  会被直接拒绝——这份文件是 0644 且要交给用户带走的。
- 仓库地址里内嵌的凭据会被自动脱敏成 `***`，落盘和文档里都不会有原值。
  重放时需要用户重新提供。
- `intent` 会重建 `DEPLOY-INTENT.md`；`handoff` 也会重建一次，所以顺序无所谓。

**收尾汇报必须让用户把 `DEPLOY-INTENT.md` 存到他自己的笔记或仓库里。**
有了它，在一台新机器上重放一遍就能得到等价的部署——这就是"即用即抛"成立的前提。
只留在 `/var/lib/hao` 里等于没留。

凭据不属于可重放的部分：新机器上会重新生成。用户如果需要保留旧密码，
必须在销毁机器前自己从凭据文件导出（路径见 `credentials`，内容要他自己去取）。
销毁前提醒一次。
