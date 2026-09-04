# HongAgentOps Services

## Service IDs

Use these IDs in `HAO_SERVICES` or `--services`:

- `maintenance`: fail2ban, swap, journald limits, Docker log rotation
- `nginx`: Nginx mainline with HTTP/3/QUIC and BBR tuning
- `docker`: Docker Engine and Docker Compose plugin
- `git-github`: Git identity, official GitHub CLI, separate Web + SSH authorization helper, and a managed "use gh" convention block written to detected AI assistant instruction files
- `cliproxyapi`: CliproxyAPI, default Docker Compose deployment
- `new-api`: New-API model gateway, Docker Compose deployment
- `claude-code`: Anthropic Claude Code CLI, with optional gateway/model/token configuration
- `uv`: uv Python package/environment manager, plus a managed "always use uv" convention block written to detected AI assistant instruction files (Claude Code, Pi, and others — see `uv/README.md` for the full detection table)
- `node`: Node.js LTS system runtime from the NodeSource apt repo; `node`/`npm` land in `/usr/bin` for systemd units, other users, and non-login shells
- `site`: generic multi-site deployment from git — clone, build, publish/start, Nginx vhost, Let's Encrypt certificate, and a per-site update script. Excluded from `all`; requires an explicit `HAO_SITES` list

Aliases accepted by the CLI include `git`, `github`, `gh`, `newapi`, `cliproxy`,
`cpa`, `claudecode`, `cc`, `nodejs`, `sites`, and `all`. `git-github` is deliberately
excluded from `all` because it configures personal identity; `site` is excluded
because it needs a per-site configuration (`HAO_SITES`).

## Dependencies

- `cliproxyapi` depends on `nginx` and `docker` in Docker mode.
- `cliproxyapi` depends on `nginx` in bare mode.
- `new-api` depends on `nginx` and `docker`.
- `site` depends on `nginx`; node-type sites additionally need Node.js (select the `node` service or have Node.js preinstalled).
- `maintenance`, `nginx`, `docker`, `git-github`, `claude-code`, `uv`, and `node` have no root-level service dependencies.

Already installed dependencies are detected and skipped unless selected directly.

## Profile Variables

- `HAO_SERVICES`: comma-separated service IDs
- `HAO_ACCESS_MODE`: `domain`, `ip`, or `http`
- `HAO_DOMAIN`: single Web service endpoint
- `HAO_CLIPROXY_DOMAIN`: CliproxyAPI endpoint
- `HAO_NEWAPI_DOMAIN`: New-API endpoint
- `HAO_CLIPROXY_MODE`: `docker` or `bare`
- `HAO_CLIPROXY_IMAGE`: CliproxyAPI Docker image tag or digest
- `HAO_ADMIN_PASSWORD` (CLI: `--admin-password`): CliproxyAPI management panel
  password; auto-generated when omitted. Prefer omitting it so the generated value
  only lands in the credentials file — never echo or log the value either way.
  **Avoid the `--admin-password` flag: a command-line value is visible to any local
  user via `ps`/`/proc/<pid>/cmdline`.** Set `HAO_ADMIN_PASSWORD` in the profile, or
  pass `--admin-password-file <PATH>` (reads the secret from the file's first line),
  or omit it entirely to use the auto-generated value.
- `HAO_DB_TYPE`: `postgresql` or `mysql`
- `HAO_NEWAPI_IMAGE`: New-API Docker image tag or digest
- `HAO_NEWAPI_ACTION`: `ensure` (default), `upgrade`, or `migrate-db`. An existing
  deployment is a no-op under `ensure`; `upgrade` reuses existing secrets and cannot
  change database engines; automatic cross-engine migration is deliberately refused.
- `HAO_GIT_NAME`: exact commit display name confirmed by the user; never infer it
- `HAO_GIT_EMAIL`: exact verified or noreply email confirmed by the user; never infer it
- `HAO_GIT_TARGET_USER`: OS user that owns the Git/gh configuration
- `HAO_GIT_MACHINE_ROLE`: `workstation` or `server`
- `HAO_GIT_SCOPE`: `global` or `repository`
- `HAO_GIT_REPO_DIR`: repository path, required for repository scope
- `HAO_GH_AUTH_MODE`: `web` or `skip`
- `HAO_GIT_ALLOW_IDENTITY_CHANGE`: `yes` only after reviewing a conflicting existing identity
- `HAO_GIT_ALLOW_SERVER_AUTH`: `yes` only after separately confirming personal GitHub auth on a server
- `HAO_GIT_SKIP_AGENT_CONVENTION`: set to `1` to skip writing the gh usage convention into AI-assistant instruction files
- `HAO_GIT_AGENT_FILES`: comma-separated absolute paths overriding assistant auto-detection for the gh convention
- `HAO_CC_BASE_URL`: Claude Code Anthropic-compatible gateway URL
- `HAO_CC_TOKEN_FILE`: file containing the Claude Code API token (preferred over `HAO_CC_AUTH_TOKEN`; keeps the secret out of the profile)
- `HAO_CC_MODEL`: Claude Code default model (also sets Sonnet/Opus/Haiku defaults)
- `HAO_CC_DISABLE_NONESSENTIAL_TRAFFIC`: set to `1` to turn off Claude Code's nonessential traffic to Anthropic (auto-update/telemetry/error reporting) — recommended for self-hosted gateway deployments
- `HAO_CC_EXTRA_ENV`: extra `settings.json` `env` keys as `KEY=VALUE`, newline- or comma-separated (keys must be uppercase). Managed keys (base URL / token / model) always override same-named entries here. Note some Claude Code toggles (`DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`) treat any set value including `0` as "on" — to disable, omit the key rather than setting it to `0`
- `HAO_CC_USER`: user whose `~/.claude/settings.json` is written (default: invoking user)
- `HAO_CC_CONFIGURE_ONLY`: set to `1` to write configuration without installing Node.js/CLI
- `HAO_CC_ACTION`: `ensure` (default, keep an existing Claude Code CLI version) or `upgrade`
- `HAO_UV_ACTION`: `ensure` (default, keep an existing uv version; convention block still refreshes) or `upgrade`
- `HAO_UV_PYTHON`: comma-separated Python versions to preinstall via uv (e.g. `3.12`)
- `HAO_UV_USER`: user whose AI-assistant instruction files receive the uv convention (default: invoking user)
- `HAO_UV_AGENT_FILES`: comma-separated absolute paths overriding assistant auto-detection
- `HAO_UV_SKIP_AGENT_CONVENTION`: set to `1` to install uv without writing any convention block
- `HAO_NODE_VERSION`: Node.js major version to install from NodeSource (default `22`)
- `HAO_NODE_ACTION`: `ensure` (default; clean no-op without touching apt when `/usr/bin/node` already matches the requested major) or `upgrade` (refresh to the latest minor of that major)
- `HAO_SITES`: comma-separated site IDs (lowercase letters, digits, hyphens) — required when `site` is selected; each site reads a `HAO_SITE_<ID>_*` family where `<ID>` is the site ID uppercased with hyphens replaced by underscores (`blog-v2` → `HAO_SITE_BLOG_V2_*`)
- `HAO_SITE_<ID>_REPO`: git URL (ssh/https) or local path / `file://` (required per site)
- `HAO_SITE_<ID>_TYPE`: `static` or `node` (required per site)
- `HAO_SITE_<ID>_DOMAIN`: site domain; empty = default site on port 80 (`server_name _`) with no certificate, allowed for at most one site per run
- `HAO_SITE_<ID>_BRANCH`: deploy branch (default `main`)
- `HAO_SITE_<ID>_BUILD`: static build command, run as the target user inside the clone
- `HAO_SITE_<ID>_OUTPUT`: static output directory relative to the clone (default `build` when BUILD is set, `.` otherwise)
- `HAO_SITE_<ID>_START`: node entry file (default `server.js`)
- `HAO_SITE_<ID>_PORT`: node listen port; empty auto-allocates from 8100 and reuses the existing unit's port on re-runs
- `HAO_SITE_<ID>_TARGET_USER`: existing OS user that clones/builds/runs the site (default `$SUDO_USER`, else `root`)
- `HAO_SITE_<ID>_CERT`: `yes` (default) requests a Let's Encrypt certificate when DOMAIN is set
- `HAO_SITE_<ID>_REDIRECT`: `yes` (default) 301s port 80 to 443 once a real certificate is issued — confirm the cloud security group allows 443 first. `no`, an empty DOMAIN, or a self-signed fallback serves the site directly on port 80
- `HAO_SITE_<ID>_ENV`: node-only extra `Environment=` entries as `KEY=VALUE,KEY2=VALUE2` (no `PORT` here; use `HAO_SITE_<ID>_PORT`)
- `HAO_CONFIRM_APPLY`: set to `yes` only after user confirmation
- `HAO_ALLOW_MANAGED_DRIFT`: set to `yes` only after separately reviewing managed drift
- `HAO_ALLOW_UNTRACKED_OVERWRITE`: set to `yes` only after separately reviewing each untracked target

Only `HAO_*` variables are supported.

GitHub authorization is intentionally not performed during `apply`. With `web`
selected, the target user runs `hao-github-authorize` afterwards. Root is allowed
with a warning that credentials and SSH keys will be root-owned. Public
repository deployment on a server normally uses `skip`; private unattended
deployment should prefer a read-only Deploy Key or GitHub App.

Deployed sites are refreshed through the generated `/usr/local/bin/hao-site-update-<id>`
scripts — individually, or all at once via `hao update` (mutating; requires root and
`--yes`). `hao credentials` is read-only: it lists the secret file paths recorded in
the HAO manifest and never prints their contents.

Docker images default to `latest`. The CLI plan also reads `config/image-candidates.tsv`
and prints two reviewed fixed-tag alternatives. At the 2026-07-13 review, CliproxyAPI
offers `v7.2.71` and `v7.2.70` as stable candidates; New-API offers
`v1.0.0-rc.21` and `v1.0.0-rc.20` as release-candidate builds.

## Supported operating systems

- Debian 13 and 12
- Ubuntu 26.04, 24.04, and 22.04 LTS

Other versions fail HAO preflight and are not release-qualified.
