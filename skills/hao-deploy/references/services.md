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

Aliases accepted by the CLI include `git`, `github`, `gh`, `newapi`, `cliproxy`,
`cpa`, `claudecode`, `cc`, and `all`. `git-github` is deliberately excluded from
`all` because it configures personal identity.

## Dependencies

- `cliproxyapi` depends on `nginx` and `docker` in Docker mode.
- `cliproxyapi` depends on `nginx` in bare mode.
- `new-api` depends on `nginx` and `docker`.
- `maintenance`, `nginx`, `docker`, `git-github`, `claude-code`, and `uv` have no root-level service dependencies.

Already installed dependencies are detected and skipped unless selected directly.

## Profile Variables

- `HAO_SERVICES`: comma-separated service IDs
- `HAO_ACCESS_MODE`: `domain`, `ip`, or `http`
- `HAO_DOMAIN`: single Web service endpoint
- `HAO_CLIPROXY_DOMAIN`: CliproxyAPI endpoint
- `HAO_NEWAPI_DOMAIN`: New-API endpoint
- `HAO_CLIPROXY_MODE`: `docker` or `bare`
- `HAO_CLIPROXY_IMAGE`: CliproxyAPI Docker image tag or digest
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
- `HAO_CC_USER`: user whose `~/.claude/settings.json` is written (default: invoking user)
- `HAO_CC_CONFIGURE_ONLY`: set to `1` to write configuration without installing Node.js/CLI
- `HAO_CC_ACTION`: `ensure` (default, keep an existing Claude Code CLI version) or `upgrade`
- `HAO_UV_ACTION`: `ensure` (default, keep an existing uv version; convention block still refreshes) or `upgrade`
- `HAO_UV_PYTHON`: comma-separated Python versions to preinstall via uv (e.g. `3.12`)
- `HAO_UV_USER`: user whose AI-assistant instruction files receive the uv convention (default: invoking user)
- `HAO_UV_AGENT_FILES`: comma-separated absolute paths overriding assistant auto-detection
- `HAO_UV_SKIP_AGENT_CONVENTION`: set to `1` to install uv without writing any convention block
- `HAO_CONFIRM_APPLY`: set to `yes` only after user confirmation
- `HAO_ALLOW_MANAGED_DRIFT`: set to `yes` only after separately reviewing managed drift
- `HAO_ALLOW_UNTRACKED_OVERWRITE`: set to `yes` only after separately reviewing each untracked target

Only `HAO_*` variables are supported.

GitHub authorization is intentionally not performed during `apply`. With `web`
selected, the target user runs `hao-github-authorize` afterwards. Root is allowed
with a warning that credentials and SSH keys will be root-owned. Public
repository deployment on a server normally uses `skip`; private unattended
deployment should prefer a read-only Deploy Key or GitHub App.

Docker images default to `latest`. The CLI plan also reads `config/image-candidates.tsv`
and prints two reviewed fixed-tag alternatives. At the 2026-07-13 review, CliproxyAPI
offers `v7.2.71` and `v7.2.70` as stable candidates; New-API offers
`v1.0.0-rc.21` and `v1.0.0-rc.20` as release-candidate builds.

## Supported operating systems

- Debian 13 and 12
- Ubuntu 26.04, 24.04, and 22.04 LTS

Other versions fail HAO preflight and are not release-qualified.
