# Changelog

HAO 通过插件市场分发（`.claude-plugin/marketplace.json`）。
`plugin.json` 里的 `version` 是语义化版本，供插件生态的 semver 校验使用。

## 0.5.0（未发布）—— 一个工具一个模块

`maintenance` 把 fail2ban、swap、journald 上限、Docker 日志轮转四件事塞进一个模块，
`git-github` 把 Git 和 GitHub CLI 塞进一个模块。文档自己都写着"四件事互相独立"，
但状态记录不是独立的：`record` 按 service ID **整体替换**，四件事共用一条
`maintenance` 记录，于是没法单独查漂移、没法只卸载其中一件、用户只想加个 swap 也
要读一份讲 fail2ban 和 Docker 的文档。

### 破坏性变更：模块拆分

| 旧模块 | 拆成 |
|---|---|
| `maintenance` | `fail2ban`、`swap`、`journald`，Docker 日志轮转并入 `docker` |
| `git-github` | `git`、`gh` |

模块数 8 → 11。捆绑关系上移到 `SKILL.md` 的意图映射表：用户说"服务器刚买来先弄
安全点"，agent 仍然一次装齐 `fail2ban` + `swap` + `journald`，但三者各记一条状态。

### 破坏性变更：service ID、模板名、约定标记

| 类别 | 旧 | 新 |
|---|---|---|
| service ID | `maintenance` | `fail2ban` / `swap` / `journald` |
| service ID | `git-github` | `git` / `gh` |
| 模板 | `maintenance-fail2ban-sshd.local` | `fail2ban-sshd.local` |
| 模板 | `maintenance-journald.conf` | `journald.conf` |
| 模板 | `maintenance-swap-sysctl.conf` | `swap-sysctl.conf` |
| `# Service:` 头 | `maintenance` / `git-github` | 对应的新模块名 |
| 约定标记 | `HAO-GIT-GITHUB` | `HAO-GH` |

**不提供自动迁移。** 旧机器上的 `services/maintenance.json`、`git-github.json`
保持原样，主机上的文件路径一个都没变（只有文件里的 `# Service:` 注释头和新记录
对不上，不影响 `hao-guard.sh` 判归属——它只看 `Managed by HAO`）。接手旧机器的
处理步骤写进了 `references/handoff.md`「碰到已经不存在的模块名」：按新模块重新
`record`，确认之后再删旧记录，顺序不能颠倒。

约定标记改名有一个具体后果：`write_marker_block` 以标记名为块身份，所以旧机器上
`<!-- HAO-GIT-GITHUB -->` 那个块不会被 `convention HAO-GH` 替换，会**多出一个块**，
需要手工删掉旧的。同样写在 `handoff.md` 里。

### 破坏性变更：插件安装名统一成 `hao`

对外露出来的名字原来是四个并存：市场叫 `hao`、市场里的插件条目叫 `hao-deploy`、
`plugin.json` 里写的是 `hao`、skill 叫 `hao-deploy`，于是用户敲的是
`/plugin install hao-deploy@hao` 这么一个四不像。

现在插件名就是产品名：

```
/plugin install hao@hao          # 原 hao-deploy@hao
```

**skill 仍叫 `hao-deploy`**，目录也还是 `skills/hao-deploy/`：插件是产品、skill 是
能力，以后再加第二个 skill（备份、监控之类）时这个分工才立得住。

已经装过旧名字的机器要重装一次（插件名写在用户的 `settings.json` 的
`enabledPlugins` 里，改名后旧条目不会自动跟着改）：

```
/plugin uninstall hao-deploy@hao
/plugin install hao@hao
```

### 拆分时补上的东西

- `swap.md` 说明了为什么 swap 文件本身不进状态记录：`drift` 对记录里每个路径算
  sha256，几 GB 的 swap 文件既算不动、内容也时刻在变，记进去等于永久报漂移。
  旧文档只是没记，没说为什么。
- `journald.md` 的验证改成 `systemd-analyze cat-config`，能看出有没有别的 drop-in
  排在后面把我们的值覆盖了；`cat` 我们自己写的文件看不出这个。
- `git.md` 强调回读身份也必须走 `run_as_target`——以 root 读出来的是 root 的配置，
  那不是证据。
- `docker.md` 拿到了完整的日志轮转过程（合并而非覆盖 `daemon.json`、JSON 非法就
  恢复备份、重启前检查运行中的容器），不再指向别的文档。
- 「不顺手 `apt upgrade` 全系统」原来挂在 `maintenance.md` 上，属于跨模块约束，
  移进 `safety.md` 的「不该做的事」。
- `CLAUDE.md` 写下"一个模块一个工具"这条不变量，以及它的理由。

## 0.4.0（未发布）—— 主机布局改成业内通用形式，证书换 certbot

部署结果原来只有 HAO 自己认识：`/var/www/hao-sites/<id>`、`/opt/hao-sites/<id>`、
`/etc/nginx/conf.d/hao-site-<id>.conf`、`/etc/nginx/ssl/<域名>/`。一个不了解 HAO 的
运维人员登上机器，在他习惯的位置什么都找不到。这违背 HAO 的目标：它服务的是不懂
运维的用户，而这类用户的机器**最终往往由别人接手**——如果 HAO 留下的东西只有 HAO
能维护，就把用户锁在了 HAO 上。

### 破坏性变更：主机路径

| 类别 | 旧 | 新 |
|---|---|---|
| 源码检出 / Node 应用 | `/opt/hao-sites/<id>` | `/opt/<id>` |
| 静态站 docroot | `/var/www/hao-sites/<id>` | `/var/www/<域名>`（无域名时 `/var/www/<id>`） |
| vhost | `conf.d/hao-site-<id>.conf` | `conf.d/<域名>.conf` |
| 站点内容块 | `/etc/nginx/hao-site-<id>-body.conf` | `/etc/nginx/snippets/<域名>.conf` |
| SSL 参数 | `/etc/nginx/hao-ssl-params.conf` | certbot 的 `options-ssl-nginx.conf` + `snippets/ssl-hardening.conf` |
| ACME location | `/etc/nginx/hao-acme-location.conf` | `/etc/nginx/snippets/acme-challenge.conf` |
| ACME webroot | `/var/www/acme` | `/var/www/html` |
| 证书 | `/etc/nginx/ssl/<域名>/{fullchain,key}.pem` | `/etc/letsencrypt/live/<域名>/{fullchain,privkey}.pem` |
| 自签名兜底 | 同上 | `/etc/ssl/certs/<域名>.pem` + `/etc/ssl/private/<域名>.key` |
| systemd 单元 | `hao-site-<id>.service` | `<id>.service` |
| 更新脚本 | `/usr/local/bin/hao-site-update-<id>` | `/usr/local/bin/<id>-update` |
| Compose 服务目录 | `/opt/docker-services/<service>` | `/opt/<service>` |

`/var/lib/hao`（状态）和 `/etc/hao`（凭据）**不变**——`/var/lib/<工具名>`、
`/etc/<工具名>` 正是约定本身，同 `/var/lib/docker`、`/etc/docker`。

**不提供旧布局迁移。** 旧布局部署过的机器保持原样，但其 `manifest.json` 里的路径
与新文档不一致。

**保留的唯一 HAO 标识是文件内部的注释头**（`# Managed by HAO` / `# Service:` /
`# HAO-SITE:`）。归属判断读文件内容而不是文件名，所以通用命名不花代价——但删掉
那几行 HAO 就分不清"这是我写的"和"这是别人的"，拒绝覆盖的保证就失效了。
在生成的配置里标明出处本身是通行做法（certbot 写 `# managed by Certbot`）。

### 证书：acme.sh → certbot

- 装发行版包 `certbot`，不再 `curl | sh` 装 acme.sh。
- **不装 `python3-certbot-nginx`**：那个插件会改 nginx 配置，和 HAO 的模板打架，
  还会让 `drift` 天天报警。用 `certonly --webroot`——certbot 只签发，配置归模板。
- **续期不再由 HAO 负责**：`certbot.timer` 随包安装并自动启用。
- reload 钩子放 `/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh`（新模板），
  比 acme.sh 的 `--reloadcmd` 好在它是任何运维都能找到的文件，且对所有证书生效。
  钩子在 `nginx -t` 失败时拒绝 reload。
- 顺带修掉一处实际的配置退步：HAO 旧的 `nginx-ssl-params.conf` 里还留着 `3DES`
  密码套件，且 `ssl_session_tickets on`（不利于前向保密）。certbot 自带的
  `options-ssl-nginx.conf` 无 3DES 且 tickets 为 `off`，直接 include 它，
  HAO 只留 HSTS 一行。

### 新增 `hao-guard.sh unit-free`

去掉 `hao-site-` 前缀带来一个新风险：`/etc/systemd/system/<name>.service` 会
**静默覆盖** `/usr/lib/systemd/system/<name>.service`。站点 ID 叫 `nginx`、`cron`、
`ssh` 就会顶掉发行版的单元，且不报任何错。写单元前必须先查。

输出词汇与 `vhost-owner` 完全一致（`free` / `hao-site <id>` / `hao <service>` /
`foreign`）。两者现在共用 `classify_hao_file`。`HAO_UNIT_DIRS` 供测试覆盖搜索路径；
systemd 可用时还会问它一次，以覆盖 alias、generator 生成、以及被 mask 的单元。

### 顺带修的两个同类缺陷

- **`@@NODE_BIN@@` 不再用 `command -v node`**，强制 `/usr/bin/node`。原写法会取到
  家目录里的 node——真实事故：`/home/<user>/.hermes/node/bin/node` 被一个以 root
  运行的服务依赖，用户清理家目录时服务就坏。这正是 `references/node.md` 开头记录的
  那个场景。
- **启动后回读实际监听地址**。HAO 管不了应用绑 `0.0.0.0` 还是 `127.0.0.1`，但必须
  查一下并如实告诉用户：绑了全网卡意味着该端口绕过 Nginx 直接可达，TLS 和访问控制
  全被跳过，此时唯一挡着的是云安全组。

### 文档

- `docs/cloudflare-dns-guide.md` 清掉旧 CLI 时代的 `HAO_SITE_<ID>_REDIRECT=yes/no`
  （那些环境变量随 CLI 一起没了）、acme.sh 与 `/etc/nginx/ssl/` 引用；
  Origin Certificate 的存放位置改成 Debian 标准的 `/etc/ssl/{certs,private}`。
- `SECURITY.md` 新增「通用布局是安全属性，不只是易用性」一节。
- `HANDOFF.md` 里"可用的更新命令"改为 glob `*-update` 再按 `# Managed by HAO` 头筛
  ——通用命名下不能光靠文件名前缀认自己的东西。

### 测试

- `unit-free` 8 条：未占用 / 发行版单元必拒 / 本站点自己的 / 别的 HAO 单元 /
  带后缀 / `/etc` 覆盖 `/lib` 时报 `/etc` 那份 / 拒绝路径分隔符 /
  在真实系统上认出 `nginx.service`。
- `vhost-owner` 与 `managed-file` 的 fixture 改成通用文件名
  （`blog.example.com.conf`），用来证明归属判断确实不依赖文件名。

## 0.3.0（未发布）—— 部署意图可带走，凭据目录收紧

### 新增

- **`hao-state.sh intent <service> key=value ...`** 与生成物
  `/var/lib/hao/DEPLOY-INTENT.md`。记录部署时用户给出的那些回答（仓库、域名、
  类型、分支、构建命令），这是机器销毁后唯一还有用的东西——`HANDOFF.md` 描述
  「这台机器现在是什么样」，意图描述「怎么再造一台一样的」。原来的处理是在
  `handoff.md` 里写一句「让用户自己留一份」，等于把责任推给用户。
  收尾汇报现在必须让用户把这份文件存到他自己的笔记或仓库里。
- 意图文件**按构造不含凭据**：明显是密钥的 key 名（`*password*`、`*token*`、
  `*secret*`、`*apikey*`、`*credential*`…）直接拒绝，URL 里内嵌的凭据
  （`https://user:token@host/…`）在落盘和文档两处都脱敏成 `***`。这条必须由脚本
  强制而不能靠 agent 自觉——那份文件是 0644 且要交给用户带走的。
- `handoff` 顺带重建 `DEPLOY-INTENT.md`，所以卸载流程（删 `services/<svc>.*`
  再 `handoff`）会把意图一起带走，和 manifest 的生命周期一致。

### 安全

- **凭据目录改为 0700 创建。** 文件本来就是 0600，但目录可列出意味着同机任意
  用户能枚举「哪些服务有凭据」。已存在的目录**绝不 chmod**——写入目标可能直接
  落在 `/etc` 下，把 `/etc` 改成 0700 的后果远比元信息泄露严重——存量宽松目录
  改为告警并给出确切的修法。
- `docs/claude-code-guide.md` 原来教用户写
  `"CLAUDE_CODE_DISABLE_1M_CONTEXT": "0"` 和 `"CLAUDE_CODE_ATTRIBUTION_HEADER": "0"`。
  这类开关在实现里是纯真值判断（`function EO(){return a.CLAUDE_CODE_DISABLE_1M_CONTEXT}`），
  而 `"0"` 在 JavaScript 里是 truthy——写 `"0"` 的效果是**打开**开关，和字面意思
  相反。`references/claude-code.md` 早就写了这个坑的警告，但 guide 自己踩了进去，
  而 guide 正是 HAO 指给用户自己读的那份。两行删掉，并补上同样的警告。

### 文档

- `handoff.md` 补两节：为什么状态在 `/var/lib/hao` 而凭据在 `/etc/hao`
  （判据是可再生性与暴露等级），以及「`/var/lib/hao` 是索引不是容器」——
  vhost 在 `/etc/nginx`、单元在 `/etc/systemd/system`、apt 源在 `/etc/apt`，
  那些位置由消费它们的程序规定，挪不动。
- `SECURITY.md` 增加落盘位置表与「为什么不放用户 home」的说明：`sudo` 下没有
  唯一的 home，按用户分会把一台机器的记录拆成几份；而 `0600 root:root` 意味着
  部署用的非 root 用户不提权读不到数据库口令,换成 home 布局这层保护按定义就没了。

### 测试

- 新增：意图文档生成、内嵌凭据在文档与落盘两处均已脱敏、脱敏后仍保留可辨认的
  仓库地址、5 类凭据 key 名均被拒绝、拒绝时不破坏已有意图、非法 key/条目/service ID
  被拒、多服务共存、`handoff` 重建意图文档、`HANDOFF.md` 指向意图文档；
  凭据目录 0700、存量目录不被 chmod、告警含修法、已合规目录不刷告警。

## 0.2.0（未发布）—— 收窄范围到运维底座，修掉三个状态相关的缺陷

### 移除

- **`new-api` 与 `cliproxyapi` 两个模块**（含 4 份模板与 `references/images.md`）。
  这两个是具体第三方应用的部署过程，不属于「通用运维底座」。它们各有自己的
  初始化流程、默认口令和数据迁移语义，写成通用过程只会给出似是而非的步骤——
  New-API 上游就在首次启动时创建 `root`/`123456`（`model/main.go` 的
  `createRootAccountIfNeed`），而原来的过程文档让 agent 汇报「首次访问 Web 界面
  自行设置管理员」，等于把一个带默认口令的模型网关配好 TLS 挂到公网上。
  `SKILL.md` 改为给出一张必查清单（默认口令、数据位置、tag 固定、只绑本机），
  应用本身按上游官方文档装。
- `assets/readme/*.svg` 三张图：全仓库零引用，且画的是已删除的 CLI。

### 修复

- **多站点状态互相覆盖**：`record` 对一个 service ID 只保留一条记录、且是整体
  替换，而 `site.md` 让每个站点都记成 `site`。部署第二个站点会让第一个站点的
  nginx 配置、更新脚本静默从状态里消失，`drift` 从此不再检查它们。改为
  `record "site-$ID"`，并在 `SKILL.md` / `handoff.md` 写清这条规则。
- **`handoff` 不重建 `manifest.json`**：`uninstall.md` 的清理流程是「删
  `services/<svc>.*` 然后 `handoff`」，但 `rebuild_manifest` 只在 `record` 里被调用，
  清单里会永久留下一个已经不存在的服务。`cmd_handoff` 现在会重建清单。
- **悬空的 `docs/releasing.md` 引用**（`plugin.json` ×2、`SECURITY.md` ×1）：
  那份文档描述的是 CLI 时代的不可变发布标识模型，随 CLI 一起没了。改为直接
  说明当前的分发方式。结构测试新增一条检查，防止 `docs/` 链接再次悬空。

### 文档

- **`SECURITY.md` 重写**：原文整篇描述的是已删除的 CLI（`preflight`、
  `lib/credentials.sh`、`--admin-password-file`、`HAO_*` profile、`apply`、
  `/var/log/vps-deploy/`、`/opt/docker-services/<svc>/hao-credentials.txt`）。
  新版按「哪些由代码强制、哪些是 agent 的行为规则」分开写，并明说散文过程不受
  CI 保护、构建命令等于任意代码执行。
- `safety.md` 的密钥规则原文写「永不读取」，但 `claude-code.md` 为了深合并 JSON
  必须把 token 取出来。规则改为精确表述（值不得进对话/日志/argv），并把那一处
  标为唯一的、有范本的例外。
- 修掉 `nginx.md` 第 2 节「三个文件」但表里只有两行；删掉 README / CLAUDE.md /
  CI 注释里对 UFW 的提及（没有 UFW 模块）；README 里的插件缓存路径原来写死成
  一个不存在的形状（真实路径带内容哈希）。
- `docs/cloudflare-dns-guide.md` 的示例子域名改成与现有模块对应的站点。

### 测试

- 新增：`handoff` 重建 manifest（含已删服务不再出现、仍在的服务未被误删、
  重建后仍是合法 JSON）、多实例 service ID 记录共存、同一 service ID 重记仍是
  整体替换、`docs/` 引用不悬空。

## 未发布 —— 转为纯 skill 形式

HAO 从「一个由 agent 调用的 CLI」改成「一个 agent 直接执行的 skill」。
部署过程从 bash 脚本变成 `skills/hao-deploy/references/` 里的过程文档 +
`templates/` 里的配置模板，agent 自己执行并验证。

### 移除

- 根 CLI（`install.sh` 约 3100 行、`hao` 包装器）与 `lib/` 共享库：命令分派、
  profile 解析、依赖解析、plan/status 输出格式化这一整层由 agent 本身取代。
- 10 个模块目录下的 `install.sh` 及配套的卸载/升级脚本，合计约 11800 行 shell。
- `AGENTS.md`、`config/image-candidates.tsv`、skill 内的 CLI 包装
  （`hao-run.sh`、`install-skill.sh`）与 agent 专属文件。
- `integration.yml` / `release.yml` 工作流与 18 个针对 CLI 的测试。

### 新增

- `.claude-plugin/{plugin.json,marketplace.json}`：可用
  `/plugin marketplace add YoungHong1992/HAO` 一步安装。
- 10 份模块过程文档（`references/`），加上 `handoff.md`、`safety.md`、
  `images.md`、`uninstall.md`。
- 20 份配置模板（`templates/`）。共享片段（SSL 参数、ACME location、
  每站点内容块）改为写一份再 `include`，不再在每个 server 块里重复拼一遍。
- 三个保留确定性的脚本：`hao-secret.sh`（凭据生成/复用/注入，值不进对话）、
  `hao-state.sh`（状态与交接契约）、`hao-guard.sh`（覆盖前的只读归属判断）。
- 新测试套件：结构完整性（frontmatter、悬空引用、模板卫生）+ 三个脚本的行为测试。

### 行为变化

- **交接契约落地**：`hao-state.sh handoff` 生成 `/var/lib/hao/HANDOFF.md`，
  并把指针块写进本机 AI 助手的指令文件——下一个 agent 不需要被告知就能发现
  这台机器由 HAO 管理。
- **凭据文件改为合并语义**：少列一个 key 不会再把它从文件里抹掉。
  内容未变时完全不写文件（真正的 no-op），落盘顺序规范化为按 key 排序。
- **证书流程简化**：先让站点在 HTTP 上活起来再申请证书，去掉了临时 nginx 配置
  与挪动 `sites-enabled/default` 的腾挪步骤。
- 站点内容块不再在 80/443 两处各拼一份，消除了两处漂移的可能。
- 镜像固定 tag 从 TSV 数据文件改为 `references/images.md`，并要求部署前用
  `docker manifest inspect` 确认 tag 仍存在。

### 已知取舍

自动化测试不再覆盖部署过程的正确性——散文没法 shellcheck，真实安装验证也无法
在 CI 里可靠复现。改动 `references/` 后需在一次性 Ubuntu VM 上手工验证，
见 README 的「验收」一节。

---

以下为转为 skill 形式之前、CLI 时期的历史记录。

## 1.0 (GA) — build <YYMMDD-hash>

First milestone marking the toolkit as production-ready after a systematic
release-readiness review. Highlights:

### New modules & CLI
- **node**: new module installing Node.js LTS system-wide from the NodeSource apt
  repo, so `node`/`npm` live in `/usr/bin` for systemd units, other users, and
  non-login shells. `HAO_NODE_VERSION` (default `22`) and `HAO_NODE_ACTION`
  (`ensure`/`upgrade`); `ensure` is a clean no-op that never touches apt when the
  requested major version is already installed.
- **site**: new module deploying your own projects from git — clone → build →
  publish/start → Nginx vhost → Let's Encrypt certificate → per-site update
  script — for any number of sites declared via `HAO_SITES` + `HAO_SITE_<ID>_*`
  (static and Node types; node ports auto-allocate from 8100 and stay stable across
  re-runs). The HTTP→HTTPS redirect is explicit (`HAO_SITE_<ID>_REDIRECT`, default
  on) with a security-group 443 warning, and port 80 serves directly for
  self-signed or domain-less sites. Excluded from `--services all`.
- **git-github**: `hao-github-authorize` now requests the `admin:public_key` scope,
  registers `gh` as the Git credential helper (`gh auth setup-git`), generates an
  ed25519 keypair when missing, and uploads it via `gh ssh-key add` — printing a
  manual fallback (paste the public key in GitHub settings) when the upload fails,
  e.g. an expired device-code flow or an old token without the scope. `apply` in
  `web` auth mode pre-generates the keypair.
- **CLI**: new `hao update` subcommand (root + `--yes`) runs every generated
  `hao-site-update-*` script; new read-only `hao credentials` lists the secret file
  paths from the HAO manifest without printing contents. Preflight gained warn-only
  checks for DNS-vs-public-IP mismatch, Cloudflare-proxy detection with Full
  (strict) guidance, and a 443 security-group reminder.

### Security & correctness
- **claude-code**: `~/.claude/settings.json` is now deep-merged instead of overwritten,
  preserving existing `permissions`/`hooks`/MCP and other keys. Sensitive values are
  passed via environment (never argv) and written through the atomic 0600 credential
  helper. Added `HAO_CC_EXTRA_ENV` (pass through arbitrary `settings.json` `env` keys)
  and the `HAO_CC_DISABLE_NONESSENTIAL_TRAFFIC` convenience toggle; managed keys always
  win over passthrough, and the known "any set value including `0` means on" toggles are
  guarded with a warning.
- **docker**: no longer unconditionally wipes `/var/lib/apt/lists`; it tries
  `apt-get update` first and only cleans + retries on failure, so a healthy apt state on
  the host is never broken.
- **cliproxyapi / new-api**: default container images are pinned to reviewed fixed tags
  (`eceasy/cli-proxy-api:v7.2.71`, `calciumion/new-api:v1.0.0-rc.21`) for reproducible
  builds; `latest` is a documented opt-in alternative. nginx installs from the **stable**
  branch by default (`HAO_NGINX_REPO_BRANCH` to override).
- **new-api**: Redis password moved off the container command line into a mounted,
  0600 `redis.conf`; health checks use `REDISCLI_AUTH` instead of an argv `-a` flag.
  Removed the obsolete `version:` compose keys.
- **cliproxyapi**: real readiness is now verified by polling the bound port from the host
  (`wait_for_local_port`) instead of a fixed `sleep` + `grep Up`, so `apply` fails loudly
  when the service does not come up.
- **CLI**: added `--admin-password-file <PATH>`; the plain `--admin-password` flag now
  warns that a command-line secret is visible via `ps`. Argument parsing rejects
  option values that are missing or look like another flag, and the top-level
  `--help/--version` prescan no longer hijacks subcommand tokens.
- **validators**: `validate_ip` tightened for IPv6 (rejects `:::`, under/over-length
  group counts); `check_port_available` matches the port field exactly (no `:8080`
  false hit for `:80`). The `install.sh` copies and the `lib/` originals are kept
  byte-identical.
- **cliproxyapi** now honors `HAO_DOCKER_ROOT` / `HAO_NGINX_CONF_DIR` /
  `HAO_NGINX_SSL_DIR` like new-api, so overriding those no longer splits state between
  the recorded and on-disk paths.

### Testing & CI
- The `Release` workflow now runs a root **integration gate** (apply-safety, New-API
  PostgreSQL/MySQL, CliproxyAPI, uv, and maintenance idempotency) before it can build a
  release.
- New `tests/test-cliproxyapi-idempotency.sh` (docker two-apply + bare secret reuse) and
  `tests/test-helper-sync.sh` (guards `install.sh` ↔ `lib/` helper parity).
- `tests/run.sh` now fails loudly when `shellcheck` is missing instead of silently
  reporting success (override with `HAO_ALLOW_MISSING_SHELLCHECK=1`).

### Documentation
- Added `SECURITY.md`, `docs/uninstall.md`, and this changelog.
- `docs/releasing.md` documents the milestone-label model and the pinned-default image
  policy. Component READMEs no longer carry conflicting component `版本:` lines.
