# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

HAO (HongAgentOps) is an **AI agent skill** for deploying websites and dev/ops tooling
on Debian/Ubuntu servers, aimed at users who don't know operations. It is not a CLI
toolkit: the deployment procedures live as prose in `skills/hao-deploy/references/`
and are executed by the agent itself. Docs and comments are largely in Chinese.

The repository doubles as a Claude Code **plugin** (`.claude-plugin/`), so the whole
repo is the distribution unit.

## Commands

```bash
# Full suite: bash -n, shellcheck, structure test, behavior tests, plugin validation
./tests/run.sh                      # requires shellcheck (apt-get install -y shellcheck)

# Individual suites
./tests/test-skill-structure.sh     # frontmatter, dangling refs, template hygiene
./tests/test-guard.sh               # hao-guard.sh behavior (read-only checks)
./tests/test-secret.sh              # credential generation, reuse, render
./tests/test-state.sh               # state records, drift, handoff, marker blocks

# Lint one file (CI uses these exact flags)
shellcheck -x -S warning path/to/script.sh

# Plugin
claude plugin validate . --strict
claude --plugin-dir . -p "..."      # load the skill locally to try it
```

There is no build step and no installer. The skill mutates a host only when an agent
follows a procedure in `references/` and the user has confirmed.

## Architecture

- **`skills/hao-deploy/SKILL.md`** is the entry point: intent→module mapping, the
  six-step workflow (ask → read-only checks → explain and confirm → execute per
  reference → verify with real evidence → record state and hand off), and the hard rules.
- **`references/<module>.md`** — one procedure per module ("how to check, how to
  install"), carrying the non-obvious operational knowledge: exact commands, ordering
  constraints, refusal conditions, and the reasons behind them. This is where the old
  installer scripts went. Cross-module docs: `handoff.md` (state format and the handoff
  contract), `safety.md`, `uninstall.md`.
- **`templates/`** — the authoritative content for every file written to a host
  (nginx configs, systemd units, generated update scripts). Tokens are
  `@@NAME@@`. Templates carrying secrets are rendered with `hao-secret.sh render`, never
  by reading a secret and interpolating it. Shared fragments (`hao-ssl-params.conf`,
  `hao-acme-location.conf`, per-site body files) are written once and `include`d rather
  than duplicated into each server block.
- **`scripts/`** — only three things stay deterministic, because improvising them
  breaks a guarantee:
  - `hao-secret.sh` — generates/reuses/injects credentials so values never enter the
    transcript. Reuses existing keys by default (that is the idempotency guarantee);
    refuses command-line literals because argv is world-readable via `/proc`.
  - `hao-state.sh` — writes `/var/lib/hao` state, computes drift, generates
    `HANDOFF.md`, and writes marker-block conventions into detected AI-assistant
    instruction files. The next agent must be able to *trust* this format.
  - `hao-guard.sh` — read-only ownership checks before overwriting anything
    (`vhost-owner`, `managed-file`, `cert-issuer`, `repo-identity`, `port-free`,
    `unit-port`, `os-supported`).
- **Runtime state on a deployed host**: `/var/lib/hao/` (`HANDOFF.md`,
  `manifest.json` schema_version 1, `services/<svc>.json` + `.resources`).
  `record` **replaces** a service ID's entry rather than appending, so anything a module
  can deploy more than once must carry an instance suffix in its service ID
  (`site-blog`, not `site`) — otherwise the earlier instance silently drops out of
  `drift`. `handoff` rebuilds `manifest.json`, which is what makes the uninstall flow
  (delete `services/<svc>.*`, then `handoff`) leave a consistent manifest.
- **Ownership classes** (`managed` / `shared` / `observed` / `secret`) decide what a
  later agent may do to a resource. Choosing wrong has concrete costs: marking a user's
  code directory `managed` makes `drift` report false positives forever; marking
  someone else's config `managed` invites a future agent to overwrite it.
- **Scope boundary**: HAO installs the generic ops substrate (web server, runtimes,
  container engine, hardening) and deploys sites from the user's own Git repo. Procedures
  for specific third-party applications are deliberately **out of scope** — they each
  have their own bootstrap flow, default credentials and data-migration semantics, so a
  generic procedure produces plausible-looking wrong steps. `SKILL.md` has a checklist
  for the agent to apply when a user asks for one (default admin password, data
  location, tag pinning, loopback binding).

## Hard constraints

- **Hidden modules exist.** `tests/test-hidden-modules.sh` enforces that certain
  in-repo directories are never referenced from any public file (`*.md`, `*.sh`,
  `*.yml`, `*.yaml`, `*.json` outside those directories and `tests/`). Read that test
  to see the protected names — do not write them anywhere else, including this file.
  Those directories are self-contained and must not be given a `references/` doc.
- **The skill must stay runtime-neutral.** `tests/test-generic-skills.sh` forbids
  writing the skill for one specific agent runtime. Agent-instruction-file detection
  goes by *file convention* (existing `AGENTS.md` / `CLAUDE.md` under dot-directories)
  plus a `--agent-file` override, not by naming products.
- All scripts must pass `bash -n` and `shellcheck -x -S warning`. Files under
  `templates/` that are shell scripts must end in `.sh.tmpl`, not `.sh`, or CI's glob
  will lint their `@@TOKEN@@` placeholders and fail.
- **Never log or echo secret values.** Use `hao-secret.sh`; report only file paths.
- Procedures must stay idempotent (re-running must be safe) and must refuse rather
  than overwrite anything not owned by HAO.
- **What the tests do and don't cover**: script behavior and skill structure are
  tested; the *correctness of the prose procedures* is not — you cannot shellcheck a
  paragraph. After changing a `references/` procedure, verify it on a throwaway Ubuntu VM.
- **Acceptance runs on Ubuntu only.** Debian 13/12 stay in the supported matrix but
  are not a release gate — GitHub-hosted runners have no Debian images, and containers
  can't exercise systemd/Docker realistically.

## Adding a module

1. Write `skills/hao-deploy/references/<module>.md` following the shape of an existing
   one: read-only checks first (with explicit refusal conditions), then install steps,
   then verification with real evidence, then `hao-state.sh record` + `handoff`, then
   common failures.
2. Add any host-written file to `templates/` with a `# Managed by HAO` +
   `# Service: <module>` header — `hao-guard.sh managed-file` depends on that header.
3. Add the module to the table in `SKILL.md` (an unreferenced reference fails the
   structure test).
4. Run `./tests/run.sh`, then verify on a throwaway Ubuntu VM.
