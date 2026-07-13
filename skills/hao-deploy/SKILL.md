---
name: hao-deploy
description: AI-assisted deployment of HAO (HongAgentOps) services on Debian or Ubuntu VPS hosts. Use when an AI agent needs to plan, preflight, apply, inspect, or troubleshoot server deployments for Maintenance, Nginx, Docker, CliproxyAPI, New-API, Pi, or Claude Code using the repository's hao CLI and profile-driven workflow.
---

# HAO Deploy

## Workflow

Use HAO as a deterministic executor, not as a chatty terminal menu. Keep all human interaction in the agent conversation, then call `hao` with explicit arguments or a generated `.env` profile.

1. Clarify the target service set, access mode, domains/IPs, database choice, and deployment mode.
2. Generate or inspect a profile with non-secret deployment choices.
3. Run `plan` and explain the planned system changes to the user.
4. Run `preflight` and address failures before installation.
5. Run `apply` only after explicit user confirmation, passing `--yes`.
6. Run `status` or `doctor` after deployment and summarize results.
7. Run `inventory` to report which resources are managed, shared, observed, or secret.

Never print secret values. If a password is supplied, refer to it as provided/hidden. Prefer generated credentials and report the credential file path after deployment.

HAO records ownership under `/var/lib/hao`. Preserve untracked resources by default.
If `doctor` reports drift in a managed resource, stop and explain the difference;
do not overwrite it without explicit user review.

## Commands

Use `scripts/hao-run.sh` to invoke the repo-local CLI from any working directory:

```bash
./scripts/hao-run.sh plan --profile deploy.env
./scripts/hao-run.sh preflight --profile deploy.env
sudo ./scripts/hao-run.sh apply --profile deploy.env --yes
./scripts/hao-run.sh status
./scripts/hao-run.sh doctor --profile deploy.env
./scripts/hao-run.sh inventory
```

If the script cannot find the repository, set `HAO_REPO_DIR=/path/to/hao`.

## Installation

To install this skill into an agent runtime's skill directory, run `scripts/install-skill.sh` from a full clone of the repository:

```bash
./scripts/install-skill.sh                       # Claude Code: ~/.claude/skills/hao-deploy (symlink)
./scripts/install-skill.sh --dir /path/to/skills # other runtimes
./scripts/install-skill.sh --copy                # copy instead of symlink; set HAO_REPO_DIR afterwards
```

Symlink installs track the repository: `git pull` updates the skill. Installation is optional — an agent can also just read this file and `references/` from the clone.

## Profile

Use `.env` profiles for repeatable AI-generated deployments:

```bash
HAO_SERVICES="maintenance,nginx,docker,new-api"
HAO_ACCESS_MODE="domain"
HAO_NEWAPI_DOMAIN="api.example.com"
HAO_DB_TYPE="postgresql"
```

For multiple Web services, use distinct domains:

```bash
HAO_SERVICES="maintenance,nginx,docker,cliproxyapi,new-api"
HAO_ACCESS_MODE="domain"
HAO_CLIPROXY_DOMAIN="cpa.example.com"
HAO_NEWAPI_DOMAIN="api.example.com"
```

## Safety

Before `apply`, state that HAO may install packages, enable systemd services, write under `/opt`, `/etc/nginx`, `/etc/docker`, `/var/log/vps-deploy`, and `/var/lib/hao`, and may request/replace Nginx service configs for selected Web services.

Do not run destructive uninstall, volume deletion, SSH hardening changes, or production certificate replacement unless the user explicitly asks and confirms the specific action.

## References

- Read `references/services.md` when choosing service names, dependencies, and profile variables.
- Read `references/safety.md` before applying changes on a real VPS.
