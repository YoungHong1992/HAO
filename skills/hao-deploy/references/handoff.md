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
├── manifest.json               汇总清单，schema_version 1
└── services/
    ├── <service>.json          单服务记录
    └── <service>.resources     资源清单（TSV: ownership 哈希 路径）
```

用 `HAO_STATE_DIR` 可以整体改位置（测试时用）。

记录里只有**资源路径、归属类别、内容哈希**。配置值不进去，密钥内容更不进去。
凭据文件只登记路径，哈希恒为 `redacted`。

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
      "service": "site",
      "release": "skill",
      "recorded_at": "2026-09-05T14:04:18Z",
      "result": "installed",
      "ownership": "managed",
      "resources": [
        {"path": "/etc/nginx/conf.d/hao-site-blog.conf", "ownership": "managed", "sha256": "c467…"},
        {"path": "/opt/hao-sites/blog", "ownership": "observed", "sha256": "directory"},
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

`handoff` 做两件事：

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

## 机器销毁后还剩什么

`/var/lib/hao` 随机器一起消失。真正需要跨机器存活的是**部署意图**，不是状态：
站点 ID、仓库地址、类型、域名、分支、构建命令这些回答，让用户自己留一份
（记在他自己的笔记或仓库里）。有了这些，在一台新机器上重放一遍就能得到
等价的部署——这就是"即用即抛"成立的前提。

凭据不属于可重放的部分：新机器上会重新生成。用户如果需要保留旧密码，
必须在销毁机器前自己导出。销毁前提醒一次。
