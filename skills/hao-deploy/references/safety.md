# HongAgentOps Deployment Safety

## Required Gates

Always run `plan` before `apply`.

Always run `preflight` before `apply` on a real host unless the user explicitly asks to skip it.

Only run `apply` after the user has confirmed the plan. Use `--yes` or `HAO_CONFIRM_APPLY=yes` only after that confirmation.

`--yes` does not authorize overwriting drifted or untracked resources. Managed drift
requires the separate `--allow-managed-drift` / `HAO_ALLOW_MANAGED_DRIFT=yes`
confirmation. An existing target that is not managed by the selected service requires
`--allow-untracked-overwrite` / `HAO_ALLOW_UNTRACKED_OVERWRITE=yes`. Review the exact
paths first; the two confirmations are intentionally independent.

For an existing New-API deployment, the default `ensure` action is a no-op. Use the
explicit `upgrade` action to refresh its image/config while reusing existing secrets.
An engine change is not an upgrade, and HAO refuses to present an empty replacement
database as a migration.

## Sensitive Values

Do not print passwords, API keys, database passwords, or generated secrets.

Prefer automatic secret generation. Report credential file paths instead of values.

If the user provides a secret in chat, avoid repeating it back.

## High-Risk Areas

Call out these areas in the plan summary:

- Package installation through `apt`
- Systemd service enable/restart
- Nginx config writes under `/etc/nginx`
- Docker daemon config writes under `/etc/docker`
- Docker Compose state under `/opt/docker-services`
- SSL certificate issuance or replacement
- Maintenance baseline changes such as fail2ban, swap, journald, and Docker log rotation
- Git identity changes and installation of the official GitHub CLI apt repository
- Personal GitHub authorization on a server (requires separate confirmation)

For `git-github`, ask for the exact Git name, email, target user, machine role,
scope, and auth mode. Never infer identity from a login name, repository history,
or GitHub account. Root authorization is allowed on root-only VPS hosts, but warn
that GitHub credentials, Git configuration, and SSH keys will be root-owned.

Do not run uninstall scripts, delete Docker volumes, delete SSL files, or remove service directories unless the user explicitly asks for that exact operation.
