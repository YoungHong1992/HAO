# Changelog

HAO 通过插件市场分发（`.claude-plugin/marketplace.json`）。
`plugin.json` 里的 `version` 是语义化版本，供插件生态的 semver 校验使用。

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
