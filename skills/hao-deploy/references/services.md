# HongAgentOps Services

## Service IDs

Use these IDs in `HAO_SERVICES` or `--services`:

- `maintenance`: fail2ban, swap, journald limits, Docker log rotation
- `nginx`: Nginx mainline with HTTP/3/QUIC and BBR tuning
- `docker`: Docker Engine and Docker Compose plugin
- `cliproxyapi`: CliproxyAPI, default Docker Compose deployment
- `new-api`: New-API model gateway, Docker Compose deployment
- `pi`: terminal AI coding assistant
- `claude-code`: Anthropic Claude Code CLI, with optional gateway/model/token configuration

Aliases accepted by the CLI include `newapi`, `cliproxy`, `cpa`, `claudecode`, `cc`, and `all`.

## Dependencies

- `cliproxyapi` depends on `nginx` and `docker` in Docker mode.
- `cliproxyapi` depends on `nginx` in bare mode.
- `new-api` depends on `nginx` and `docker`.
- `maintenance`, `nginx`, `docker`, `pi`, and `claude-code` have no root-level service dependencies.

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
- `HAO_CC_BASE_URL`: Claude Code Anthropic-compatible gateway URL
- `HAO_CC_TOKEN_FILE`: file containing the Claude Code API token (preferred over `HAO_CC_AUTH_TOKEN`; keeps the secret out of the profile)
- `HAO_CC_MODEL`: Claude Code default model (also sets Sonnet/Opus/Haiku defaults)
- `HAO_CC_USER`: user whose `~/.claude/settings.json` is written (default: invoking user)
- `HAO_CC_CONFIGURE_ONLY`: set to `1` to write configuration without installing Node.js/CLI
- `HAO_CONFIRM_APPLY`: set to `yes` only after user confirmation

Only `HAO_*` variables are supported.

Docker images default to `latest`. The CLI plan also reads `config/image-candidates.tsv`
and prints two reviewed fixed-tag alternatives. At the 2026-07-13 review, CliproxyAPI
offers `v7.2.71` and `v7.2.70` as stable candidates; New-API offers
`v1.0.0-rc.21` and `v1.0.0-rc.20` as release-candidate builds.

## Supported operating systems

- Debian 13 and 12
- Ubuntu 26.04, 24.04, and 22.04 LTS

Other versions fail HAO preflight and are not release-qualified.
