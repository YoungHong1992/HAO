# Changelog

HAO ships **immutable release identifiers** (`YYMMDD-<git-hash>`), not semantic
versions. Maturity milestones like "1.0 (GA)" are documentation labels that point at
one immutable build — see `docs/releasing.md`. Fill in the concrete `build <YYMMDD-hash>`
when the corresponding `Release` workflow run mints it.

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
