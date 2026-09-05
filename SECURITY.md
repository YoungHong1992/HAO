# Security Policy

## What HAO is, in security terms

HAO is an **AI agent skill**, not a program. There is no CLI and no installer. The
deployment procedures live as prose in `skills/hao-deploy/references/` and are executed
by an agent, as root, on the host the agent is running on. Three small scripts under
`skills/hao-deploy/scripts/` are the only deterministic parts.

That shape decides how the guarantees below are enforced. Some are enforced *in code*
(the scripts refuse to do the unsafe thing). The rest are **behavioural rules the
executing agent must follow**, written down in `references/safety.md`. We say which is
which, because a rule that only exists in prose can be broken by a careless agent and
you should know that when you decide to run this.

## Supported environments

Debian 13/12 and Ubuntu 26.04/24.04/22.04 LTS. `hao-guard.sh os-supported` returns
`unsupported` for anything else and the procedures require the agent to stop there.

Release acceptance is performed on Ubuntu only. Debian remains a supported install
target but is not a release gate: GitHub-hosted runners have no Debian images, and
containers cannot realistically exercise systemd or Docker.

## Secret-handling contract

**Enforced in `scripts/hao-secret.sh`:**

- Generated credentials are written only to per-service files created atomically with
  `0600` permissions. The value is never printed to stdout — the script reports the file
  path and the key *names* only.
- **Command-line literals are refused.** `KEY=hunter2` is rejected with an explanation,
  because argv is world-readable via `ps` and `/proc/<pid>/cmdline`. User-supplied
  secrets must come in as `KEY=@file:PATH` or `KEY=@env:VARNAME`.
- **Re-running does not rotate.** Existing keys in the target file are reused by
  default; rotation requires an explicit `--rotate KEY`. Keys already in the file but
  absent from the current invocation are preserved rather than dropped, because
  silently losing a credential a live service is using is an unacceptable failure.
- Injecting a secret into a config file goes through `hao-secret.sh render`, which
  substitutes `@@KEY@@` placeholders without printing any value, and refuses to write a
  half-populated file if the credential file is missing a key the template needs.

**Enforced in `scripts/hao-state.sh`:**

- State records contain only resource paths, ownership classes and content hashes.
  Resources classed `secret` are recorded with the hash literally `redacted` and are
  never hashed or read.
- `credentials` lists credential file *paths* and nothing else.

**Behavioural rules for the executing agent** (`references/safety.md`):

- Never print, echo or paraphrase the contents of a credential file. Report paths.
- The one sanctioned exception is passing a value to a program that cannot be served by
  `render` (deep-merging JSON is the only current case): the value goes through an
  environment variable, never argv, never stdout, never the report.
- Repository URLs may embed tokens; logs and reports redact them
  (`sed -E 's#(://)[^/@]+@#\1***@#'`).
- If the user pastes a password into the conversation, do not repeat it; point out that
  it is now in the transcript.

## Deployment hardening

- Services bind to `127.0.0.1` and are reached through the managed Nginx reverse proxy
  with TLS. Do not expose application ports directly to the internet.
- Private keys are `600`, certificates `644`. `/.well-known/acme-challenge/` stays
  reachable on port 80 so renewal does not break.
- **80→443 redirect requires three conditions**, all of them: a real Let's Encrypt
  certificate (not the self-signed fallback), the user not having opted out, and the
  user having confirmed that the cloud firewall / security group allows 443/TCP.
  Enabling a redirect to an unreachable 443 takes a working site completely offline
  (the classic Cloudflare 522). Self-signed certificates never redirect.
- Procedures must refuse rather than overwrite. `hao-guard.sh` answers "who owns this?"
  read-only (`vhost-owner`, `managed-file`, `cert-issuer`, `repo-identity`), and
  `foreign` / `not-git` / `remote-mismatch` require the agent to stop and report the
  path rather than delete or overwrite anything.
- HAO does not change the SSH port, disable password login, or alter firewall default
  policy on its own initiative — those can lock the user out of their own machine with
  no second way in.

## Third-party applications are out of scope

HAO deliberately ships **no procedure for installing specific third-party
applications**. Those applications each have their own bootstrap flow, and some ship
with a **default administrator password that is live from the moment the service
starts** — a generic "deploy it behind TLS" procedure would put such a service on the
public internet before the user has changed it.

If you use HAO's `docker` + `nginx` modules as a substrate for such an application,
changing any upstream default credential before the service becomes publicly reachable
is **your responsibility**. `SKILL.md` requires the agent to raise this explicitly.

## Threat model, stated plainly

- **The agent runs as root and can execute user-supplied build commands.** Deploying a
  site runs that repository's build command on your host. That is arbitrary code
  execution by design; only deploy repositories you trust.
- **Prose procedures are not verified by CI.** Script behaviour and skill structure are
  tested; you cannot shellcheck a paragraph. A change to a `references/` procedure is
  verified by running it on a throwaway VM, not by the test suite.
- **The transcript is a secret-bearing artifact.** The contract above keeps generated
  credentials out of it, but anything the user types into the conversation is in it.

## Reporting a vulnerability

Report suspected vulnerabilities privately to the repository maintainers via a GitHub
[private security advisory](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
on this repository, or by opening a minimal issue that requests a private channel
**without** including exploit details or secrets. Please allow a reasonable window for a
fix before any public disclosure.
