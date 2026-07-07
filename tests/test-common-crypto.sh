#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=../lib/crypto.sh
source "$ROOT_DIR/lib/crypto.sh"

validate_domain "api.example.com" >/dev/null
if validate_domain "bad_domain" >/dev/null 2>&1; then
  echo "Invalid domain unexpectedly passed validation" >&2
  exit 1
fi

validate_ip "127.0.0.1" >/dev/null
validate_ip "2001:db8::1" >/dev/null
if validate_ip "999.1.1.1" >/dev/null 2>&1; then
  echo "Invalid IPv4 unexpectedly passed validation" >&2
  exit 1
fi

password="$(generate_password 32)"
if [ "${#password}" -ne 32 ]; then
  echo "Unexpected password length: ${#password}" >&2
  exit 1
fi

session_secret="$(generate_session_secret 48)"
if [ "${#session_secret}" -ne 48 ]; then
  echo "Unexpected session secret length: ${#session_secret}" >&2
  exit 1
fi

api_key="$(generate_api_key sk-)"
if ! [[ "$api_key" =~ ^sk-[A-Za-z0-9]{45}$ ]]; then
  echo "Unexpected API key format: $api_key" >&2
  exit 1
fi
