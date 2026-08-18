# Security Policy

## Supported environments

HAO targets Debian/Ubuntu VPS hosts. Release acceptance is performed on Ubuntu only
(26.04 / 24.04 / 22.04 LTS); Debian 13/12 remain supported install targets accepted by
`preflight` but are not a release gate. See `docs/releasing.md`.

## Secret-handling contract

This contract is enforced in the code and required of any agent or human operating the
toolkit:

- **Secrets are never printed or logged.** Generated API keys, admin passwords, database
  and Redis passwords, and session secrets are written only to per-service credential
  files created atomically with `0600` permissions (`lib/credentials.sh`).
- **Report the path, not the value.** Tools and agents surface the credential file path
  (e.g. `/opt/docker-services/<service>/hao-credentials.txt`) and never echo the secret.
- **Secrets stay off the command line.** Passwords are passed through profiles
  (`HAO_*` variables), files (`--admin-password-file`), or mounted config — never as a
  process argument, because argv is world-readable via `ps` / `/proc/<pid>/cmdline`.
  The legacy `--admin-password` flag still works but warns for this reason.
- **Re-applying does not rotate secrets.** Idempotent `apply`/upgrade paths reuse the
  existing secrets rather than regenerating them.
- **Logs may capture context**, so log files under `/var/log/vps-deploy/` are created
  `0600`.

## Deployment hardening notes

- Default container images are pinned to reviewed fixed tags for reproducibility.
- Web services bind to `127.0.0.1` and are expected to be reached through the managed
  Nginx reverse proxy with TLS. Do not expose service ports directly to the internet.
- New-API ships with an upstream default login (`root` / `123456`). **Change it on first
  login and do not expose the service publicly until you have.** See `new-api/README.md`.

## Reporting a vulnerability

Report suspected vulnerabilities privately to the repository maintainers via a GitHub
[private security advisory](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
on this repository, or by opening a minimal issue that requests a private channel
**without** including exploit details or secrets. Please allow a reasonable window for a
fix before any public disclosure.
