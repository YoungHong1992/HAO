# Changelog

HAO 通过插件市场分发（`.claude-plugin/marketplace.json`）。
`plugin.json` 里的 `version` 只是插件打包版本。

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
