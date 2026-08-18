# HAO release process

HAO uses immutable release identifiers instead of semantic versions:

```text
YYMMDD-<7-character-git-hash>
```

The date is UTC. A release identifier names one Git commit and must never be reused
or overwritten.

## Maturity milestones (e.g. "1.0 GA")

Maturity milestones such as "1.0 (GA)" are **documentation labels that point at one
immutable release ID** — they never replace or reformat the `YYMMDD-<hash>` identity.
`./hao --version`, the `Release` workflow, and the release archive always report the
immutable ID only.

To mark a milestone:

- Record it in `CHANGELOG.md` against the concrete build it refers to
  (`## 1.0 (GA) — build <YYMMDD-hash>`).
- Optionally add an **annotated git tag** `milestone-1.0` on that commit for
  discoverability. This tag is a pointer only; it is **not** a GitHub Release and does
  not trigger the `Release` workflow (which is `workflow_dispatch` and always mints a
  fresh immutable ID).

There is no semantic-version scheme for the toolkit itself. Per-component README files
that once carried a component `版本:` line now defer to this release model.

## Release gates

Before triggering the GitHub `Release` workflow:

1. Update `config/image-candidates.tsv` from the upstream registries on the UTC release
   date. The `default` column must hold a **reviewed, fixed tag** (never `latest`); record
   `latest` and one more fixed tag as alternatives with honest maturity labels. Installers
   ship these pinned defaults so a build is reproducible; `latest` remains a documented,
   opt-in alternative. The release workflow rejects stale dates and missing registry tags.
2. Run `./tests/run.sh` locally and confirm the `CI` workflow passed on the target commit.
3. Confirm the `Integration` workflow passed on the target commit (or on the same PR). The
   integration gate runs on `ubuntu-latest` — a real Ubuntu VM with systemd, Docker, and
   UFW — and exercises `apply --yes` twice for each service to verify idempotency. Passing
   CI is the acceptance gate.
4. Trigger `Release`, selecting a commit on `main` and supplying the URL of the passing
   CI or Integration workflow run as the `acceptance_evidence` input.

The workflow repeats the complete test suite, verifies that the commit belongs to
`main`, creates the release identifier, bundles the repository, verifies embedded
metadata, generates SHA-256 checksums, and creates a GitHub Release. It fails if the
tag or release already exists.

## Supported OS acceptance matrix

Release acceptance runs on Ubuntu only. Debian 13/12 remain supported install
targets (`preflight` accepts them), but they are explicitly excluded from release
acceptance: GitHub-hosted runners provide no Debian images, and container-based
Debian runs cannot exercise systemd, Docker, and UFW the way a real VM does.
Do not add Debian acceptance jobs or record Debian acceptance evidence — it is
not a release gate and reviewers will not wait for it.

Use a fresh, disposable amd64 or arm64 VM for each target:

| Distribution | Release |
|---|---|
| Ubuntu LTS | 26.04 |
| Ubuntu LTS | 24.04 |
| Ubuntu LTS | 22.04 |

For every VM, record:

- OS image name, architecture, kernel, and HAO commit.
- `plan` and `preflight` output.
- First `apply --yes` result.
- Second `apply --yes` result to validate idempotency.
- `status` and `doctor` output.
- Service health checks and relevant Nginx/Docker/systemd status.
- Cleanup or destruction of the disposable VM.

Web-service acceptance additionally covers domain, IP, and HTTP access modes,
distinct domains for multiple services, both New-API database choices, and both
CliproxyAPI deployment modes. Never put credentials in the acceptance record.

## Artifact verification

After GitHub creates the release, download it through the immutable release URL and run:

```bash
sha256sum -c checksums.txt
tar -xzf hao.tar.gz
cd hao
test "$(cat RELEASE)" = "<expected-release-id>"
./hao --version
./tests/run.sh  # when testing a source checkout; tests are not bundled in the release archive
```

The extracted CLI version must equal `RELEASE`, and `build-info.json` must contain
the full target commit and acceptance evidence identifier.
