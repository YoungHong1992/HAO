# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

HAO (HongAgentOps) is a pure-Bash, zero-dependency deployment toolkit for Debian/Ubuntu VPS hosts, designed to be driven by AI agents through a deterministic `plan → preflight → apply → status/doctor` CLI workflow instead of interactive terminal menus. Docs and code comments are largely in Chinese.

## Commands

```bash
# Full test suite: bash -n syntax check, shellcheck, unit tests, CLI smoke tests
./tests/run.sh                      # requires shellcheck installed (apt-get install -y shellcheck)

# Run a single test
./tests/test-cli-profile.sh
./tests/test-credentials.sh

# Manual lint of one file (CI uses these exact flags)
shellcheck -x -S warning path/to/script.sh

# CLI smoke checks (safe, read-only)
./hao plan --services new-api --domain api.example.com
./hao preflight --profile deploy.env
./hao status

# Real-install idempotency test — MODIFIES THE MACHINE, only run in CI/throwaway VMs
sudo ./tests/test-maintenance-idempotency.sh
```

There is no build step. `apply` only mutates the system when given `--yes` (or `HAO_CONFIRM_APPLY=yes`) and root.

## Architecture

- **`hao`** is a 5-line wrapper that `exec`s **`install.sh`** — the single ~1800-line CLI executor. It contains all command dispatch (`plan|preflight|apply|status|doctor|help` case at the bottom), profile parsing (`load_profile_file`, `parse_cli_args`), dependency resolution (`resolve_deps`), preflight checks, and the `run_install` orchestrator. It also doubles as the remote bootstrap entry (`curl | bash` downloads the full repo, shows help only).
- **Component directories** (`maintenance/`, `nginx/`, `docker/`, `cliproxyapi/`, `new-api/`, `claude-code/`, `uv/`) each expose a uniformly named `install.sh` that `hao apply` calls non-interactively. CPA and New-API deploy via Docker Compose by default (`docker-compose.yml` in the dir); CPA supports bare-metal via `HAO_CLIPROXY_MODE=bare`. `claude-code/` is the template for "tool configuration" modules (install a CLI + write user-level config from `HAO_CC_*` vars). `uv/` installs the uv Python manager and writes a managed convention block into detected AI-assistant instruction files.
- **`lib/`** holds shared helpers: `common.sh` (logging, OS/port/domain validation, SSL via acme.sh, nginx conf discovery), `crypto.sh` (secret generation), `credentials.sh` (atomic 0600 credential-file writes), `agent-convention.sh` (detect installed AI assistants and write managed marker-block conventions into their instruction files — used by `uv/` and `git-github/`). Only components that write credentials (new-api, cliproxyapi) source these via `$HAO_REPO_DIR/lib/...`; base scripts (maintenance, nginx, docker) are intentionally self-contained so they can be run standalone. Note `install.sh` duplicates many `common.sh` helpers rather than sourcing it — keep them in sync when changing shared behavior.
- **Configuration** flows through `HAO_*` environment variables, either from a `deploy.env` profile (`--profile`) or CLI flags. Per-service variables use the `service_env_prefix` mapping (e.g. `HAO_NEWAPI_DOMAIN`, `HAO_CLIPROXY_DOMAIN`).
- **Runtime state**: install markers under `/var/lib/hao/`, logs under `/var/log/vps-deploy/`.
- **`skills/hao-deploy/`** is a distributable AI-agent skill wrapping the same CLI; its safety contract (confirm before `apply`, never print secret values, report credential file paths only) applies to work in this repo too. `AGENTS.md` at the repo root is the entry point for consumer agents.
- **Adding a module**: follow `docs/adding-a-module.md` — it lists every registration point in the root `install.sh` (service constants, detection, aliases, plan/status output, completeness checks) plus packaging and skill-reference updates.

## Hard constraints

- **Hidden modules exist.** `tests/test-hidden-modules.sh` enforces that certain in-repo directories are never referenced from public files (any `*.md`, `*.sh`, `*.yml` outside those directories and `tests/`) and stay out of the release tarball. Read that test to see the protected names — do not write them anywhere else, including this file. CI runs the check.
- All scripts must pass `bash -n` and `shellcheck -x -S warning` — CI checks every `*.sh` in the repo.
- Never log or echo secret values; use `lib/credentials.sh` helpers and log only the credential file path.
- Installers must stay idempotent (re-running must be safe) and non-interactive when invoked through `hao apply`.
- **Acceptance and integration testing run on Ubuntu only.** Debian 13/12 stay in the supported-OS matrix (`is_supported_os_release`, `preflight`), but do not add Debian jobs to CI, run Debian acceptance tests, or treat Debian acceptance as a release gate — GitHub-hosted runners have no Debian images, and containers can't exercise systemd/Docker/UFW realistically. See `docs/releasing.md`.
