# Uninstalling HAO components

HAO does not ship a single "uninstall everything" command, and **agents must never run
an uninstall unprompted** — removal is destructive and requires explicit human intent.
Each web service has a dedicated uninstaller; the base modules (maintenance, nginx,
docker) are reversed manually.

Run all commands as root on the target host.

## Web services

### CliproxyAPI

```bash
sudo ./cliproxyapi/uninstall_cliproxyapi.sh        # interactive; add -h for help
```

Stops and removes the service (Docker Compose stack or the `cliproxyapi` systemd unit),
and deletes its program/config/data/log files and the CliproxyAPI-specific Nginx config.
It backs up removable state before deleting and prompts for confirmation; set
`HAO_UNATTENDED=1` only in throwaway environments where you accept non-interactive
removal.

### New-API

```bash
sudo ./new-api/uninstall_newapi_docker.sh          # interactive; add -h for help
```

Stops and removes the New-API containers, optionally backing up the Docker volumes
(default backup dir `/backup/newapi-uninstall-<timestamp>`), then removes the service
directory under `/opt/docker-services/new-api` and its Nginx config. Database and Redis
**data volumes are deleted** — take the offered backup if you need the data.

## Base modules (manual reversal)

These modules configure the host and have no dedicated uninstaller:

- **nginx** — remove the service and the HAO-managed site configs you no longer want:
  `sudo systemctl disable --now nginx` and delete the relevant files under
  `/etc/nginx/conf.d/` (HAO-managed files begin with a `# Managed by HAO` header).
- **docker** — `sudo systemctl disable --now docker` and remove the Docker packages via
  your package manager if Docker was installed solely for HAO. Removing Docker also
  affects any container workload on the host.
- **maintenance** — reverts to standard system configuration; review changes it recorded
  before undoing them.

## Clearing HAO runtime state

HAO records ownership and resource hashes under `/var/lib/hao/` and writes logs under
`/var/log/vps-deploy/`. After removing the components you no longer want:

```bash
# Inspect first — this is what HAO believes it manages.
sudo cat /var/lib/hao/manifest.json

# Remove state/markers only once the corresponding services are actually gone.
sudo rm -f /var/lib/hao/maintenance.installed
sudo rm -f /var/lib/hao/manifest.json          # or delete /var/lib/hao entirely
```

Only clear state for components you have actually removed; a stale manifest will make
`status`/`doctor` report services that no longer exist, while deleting the manifest
while services remain makes HAO treat them as untracked on the next `apply`.
