#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "This integration test must run as root." >&2
  exit 1
fi

export HAO_UNATTENDED=1
export HAO_DISABLE_SWAP=1

"$ROOT_DIR/maintenance/install.sh"
"$ROOT_DIR/maintenance/install.sh"

test -f /var/lib/hao/maintenance.installed

grep -q 'release=' /var/lib/hao/maintenance.installed
grep -q 'Managed by HAO' /var/lib/hao/maintenance.installed

echo "Maintenance idempotency test passed."
