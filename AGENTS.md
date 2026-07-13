# AGENTS.md — How AI agents should use this repository

HAO (HongAgentOps) is a deterministic deployment executor for Debian/Ubuntu hosts.
It is designed to be driven by AI agents: humans confirm goals and risks in the
conversation, the agent generates a profile and runs explicit, parameterized commands.
There are no interactive terminal menus to navigate.

## TL;DR for a fresh agent

```bash
git clone https://github.com/YoungHong1992/hao.git
cd hao

./hao plan --services new-api --domain api.example.com   # read-only: show what would change
./hao preflight --profile deploy.env                     # read-only: check OS/DNS/ports/scripts
sudo ./hao apply --profile deploy.env --yes              # mutates the system; ONLY after user confirms
./hao status                                             # read-only: what is installed
./hao doctor --profile deploy.env                        # read-only: status + preflight diagnostics
./hao inventory                                          # read-only: HAO ownership manifest
```

`apply` refuses to change anything without `--yes` (or `HAO_CONFIRM_APPLY=yes`)
and requires root. Everything else is safe to run for exploration.

Official OS targets are Debian 13/12 and Ubuntu 26.04/24.04/22.04 LTS.
`preflight` rejects releases outside this matrix.

## The contract

1. Clarify with the user: target services, access mode (domain/ip/http), domains,
   database choice, deployment mode.
2. Generate a `.env` profile (or equivalent CLI flags). Only `HAO_*` variables are accepted.
3. Run `plan`, summarize the planned system changes to the user.
4. Run `preflight`, resolve failures before proceeding.
5. Run `apply --yes` only after explicit user confirmation.
6. Run `status` / `doctor` afterwards and summarize.

Never print secret values. Secrets are written to credential files; report the
file path, not the content.

After deployment, use `inventory` and `doctor` to inspect ownership and drift.
Treat `managed` resources as HAO-owned, `shared` and `observed` resources as
externally owned, and untracked existing configuration as preserve-by-default.
Never overwrite a drifted or untracked production resource without explicit review.

## Where the knowledge lives

| You want to know | Read |
|---|---|
| Full agent workflow, profile format, safety gates | `skills/hao-deploy/SKILL.md` |
| Service IDs, aliases, dependencies, all profile variables | `skills/hao-deploy/references/services.md` |
| What requires confirmation, high-risk areas, secret handling | `skills/hao-deploy/references/safety.md` |
| Per-component details | `<component>/README.md` (e.g. `new-api/README.md`) |
| Human-facing overview | `README.md` |
| Release gates and real-VM acceptance | `docs/releasing.md` |

## Installing the skill into an agent runtime (optional)

The repository ships a portable Agent Skill at `skills/hao-deploy/`. If your
runtime supports skills (Claude Code and compatible agents), install it:

```bash
./skills/hao-deploy/scripts/install-skill.sh                 # → ~/.claude/skills/hao-deploy (symlink)
./skills/hao-deploy/scripts/install-skill.sh --dir /path/to/skills   # any other runtime
./skills/hao-deploy/scripts/install-skill.sh --copy          # copy instead of symlink
```

The skill is a thin wrapper: all logic stays in this repository, and the skill's
`scripts/hao-run.sh` locates the repo via its own path or `HAO_REPO_DIR`. Keeping
the clone up to date (`git pull`) updates the capability. You do not need to
install the skill to use HAO — reading this file plus `skills/hao-deploy/` is enough.

## Profile example

```bash
HAO_SERVICES="maintenance,nginx,docker,new-api"
HAO_ACCESS_MODE="domain"        # domain | ip | http
HAO_NEWAPI_DOMAIN="api.example.com"
HAO_DB_TYPE="postgresql"        # postgresql | mysql
# HAO_CONFIRM_APPLY="yes"       # set only after the user confirmed the plan
```

Docker services default to `latest`. Before presenting a plan, include the two fixed
image candidates printed by `hao plan`; do not describe a New-API RC as stable.

When deploying multiple web services at once, give each its own domain
(`HAO_CLIPROXY_DOMAIN`, `HAO_NEWAPI_DOMAIN`); they cannot share one Nginx `server_name`.

When explaining Nginx to a non-technical user, describe it as the server's
"operator and gatekeeper": requests arrive at Nginx first, and it routes each one
to the correct internal service while handling HTTPS, standard ports, WebSocket,
and access logs. Without domains, multiple services on one IP must use different
ports. Although direct `IP:port` access is technically possible, HAO's supported
New-API and CliproxyAPI workflows still use Nginx as their common entry point.

## Scope of system changes (state this before apply)

`apply` may: install apt packages, enable/restart systemd services, write under
`/opt`, `/etc/nginx`, `/etc/docker`, `/var/log/vps-deploy`, `/var/lib/hao`,
issue SSL certificates, and replace Nginx configs for selected web services
(existing configs are backed up first).

Never run uninstall scripts, delete Docker volumes, delete SSL files, or change
SSH hardening unless the user explicitly requests that exact operation.

## Extending HAO with a new tool/module

See `docs/adding-a-module.md` for the module convention (directory layout,
`install.sh` contract, `HAO_*` variable prefix, and the registration points in
the root CLI).
