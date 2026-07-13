# HAO release process

HAO uses immutable release identifiers instead of semantic versions:

```text
YYMMDD-<7-character-git-hash>
```

The date is UTC. A release identifier names one Git commit and must never be reused
or overwritten.

## Release gates

Before triggering the GitHub `Release` workflow:

1. Update `config/image-candidates.tsv` from the upstream registries on the UTC release
   date. Keep `latest` as the default and record two fixed-tag alternatives with honest
   maturity labels. The release workflow rejects stale dates and missing registry tags.
2. Run `./tests/run.sh` locally and confirm the `CI` workflow passed on the target commit.
3. Complete real-VM acceptance on every supported OS release.
4. Store the acceptance output in an issue, workflow artifact, or other durable URL.
5. Trigger `Release`, selecting a commit on `main` and supplying that evidence URL.

The workflow repeats the complete test suite, verifies that the commit belongs to
`main`, creates the release identifier, bundles the repository, verifies embedded
metadata, generates SHA-256 checksums, and creates a GitHub Release. It fails if the
tag or release already exists.

## Supported OS acceptance matrix

Use a fresh, disposable amd64 or arm64 VM for each target:

| Distribution | Release |
|---|---|
| Debian | 13 |
| Debian | 12 |
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
