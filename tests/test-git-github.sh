#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

REPO_DIR="$TMP_DIR/repository"
mkdir -p "$REPO_DIR"
git -C "$REPO_DIR" init -q

configure_repo_identity() {
  HAO_GIT_CONFIG_ONLY=1 \
  HAO_GIT_NAME="$1" \
  HAO_GIT_EMAIL="$2" \
  HAO_GIT_MACHINE_ROLE=workstation \
  HAO_GIT_SCOPE=repository \
  HAO_GIT_REPO_DIR="$REPO_DIR" \
  HAO_GIT_TARGET_USER="$(id -un)" \
  HAO_GH_AUTH_MODE=skip \
    "$ROOT_DIR/git-github/install.sh" >/dev/null
}

configure_repo_identity "Exact User" "exact.user@example.com"
test "$(git -C "$REPO_DIR" config --local user.name)" = "Exact User"
test "$(git -C "$REPO_DIR" config --local user.email)" = "exact.user@example.com"
test "$(git -C "$REPO_DIR" config --local --get hao.identityConfigured)" = "true"

# Idempotent with the same exact values.
configure_repo_identity "Exact User" "exact.user@example.com"

if configure_repo_identity "Different User" "different@example.com" 2>/dev/null; then
  echo "Different existing Git identity was overwritten without confirmation" >&2
  exit 1
fi

HAO_GIT_CONFIG_ONLY=1 \
HAO_GIT_NAME="Different User" \
HAO_GIT_EMAIL="different@example.com" \
HAO_GIT_MACHINE_ROLE=workstation \
HAO_GIT_SCOPE=repository \
HAO_GIT_REPO_DIR="$REPO_DIR" \
HAO_GIT_TARGET_USER="$(id -un)" \
HAO_GH_AUTH_MODE=skip \
HAO_GIT_ALLOW_IDENTITY_CHANGE=yes \
  "$ROOT_DIR/git-github/install.sh" >/dev/null
test "$(git -C "$REPO_DIR" config --local user.name)" = "Different User"

if "$ROOT_DIR/hao" plan --services git-github >/dev/null 2>&1; then
  echo "Git/GitHub plan accepted an inferred identity" >&2
  exit 1
fi

plan_output="$("$ROOT_DIR/hao" plan \
  --services git-github \
  --git-name "Confirmed User" \
  --git-email "confirmed@example.com" \
  --git-machine-role workstation \
  --git-scope repository \
  --git-repo-dir "$REPO_DIR" \
  --git-target-user "$(id -un)" \
  --gh-auth-mode skip)"
grep -q 'git_name: Confirmed User' <<<"$plan_output"
grep -q 'git_email: confirmed@example.com' <<<"$plan_output"
grep -q 'github_auth: skip' <<<"$plan_output"

if [ "$EUID" -eq 0 ]; then
  root_plan_output="$("$ROOT_DIR/hao" plan \
    --services git-github \
    --git-name "Confirmed User" \
    --git-email "confirmed@example.com" \
    --git-machine-role workstation \
    --git-scope repository \
    --git-repo-dir "$REPO_DIR" \
    --git-target-user root \
    --gh-auth-mode web)"
  grep -q 'warning: GitHub credentials and SSH keys will belong to root' <<<"$root_plan_output"
fi

PROFILE="$TMP_DIR/git.env"
cat > "$PROFILE" <<EOF
HAO_SERVICES="git-github"
HAO_GIT_NAME="Profile User"
HAO_GIT_EMAIL="profile@example.com"
HAO_GIT_MACHINE_ROLE="workstation"
HAO_GIT_SCOPE="repository"
HAO_GIT_REPO_DIR="$REPO_DIR"
HAO_GIT_TARGET_USER="$(id -un)"
HAO_GH_AUTH_MODE="skip"
EOF
profile_output="$("$ROOT_DIR/hao" plan --profile "$PROFILE")"
grep -q 'github_auth: skip' <<<"$profile_output"

NON_ROOT_USER="$(getent passwd | awk -F: '$3 != 0 { print $1; exit }')"
server_error="$TMP_DIR/server-error"
if HAO_GIT_ALLOW_SERVER_AUTH='' "$ROOT_DIR/hao" plan \
  --services git-github \
  --git-name "Confirmed User" \
  --git-email "confirmed@example.com" \
  --git-machine-role server \
  --git-scope repository \
  --git-repo-dir "$REPO_DIR" \
  --git-target-user "$NON_ROOT_USER" \
  --gh-auth-mode web >/dev/null 2>"$server_error"; then
  echo "Server personal authorization passed without the extra confirmation" >&2
  exit 1
fi
grep -q 'HAO_GIT_ALLOW_SERVER_AUTH=yes' "$server_error"

all_output="$("$ROOT_DIR/hao" plan --services all \
  --access-mode domain \
  --cliproxy-domain cpa.example.com \
  --newapi-domain api.example.com)"
if grep -q 'Git + GitHub' <<<"$all_output"; then
  echo "Personal Git/GitHub tooling was unexpectedly included in --services all" >&2
  exit 1
fi

if [ "$EUID" -eq 0 ]; then
  FAKE_BIN="$TMP_DIR/fake-bin"
  GH_CALLS="$TMP_DIR/gh-calls"
  AUTH_OUTPUT="$TMP_DIR/auth-output"
  mkdir -p "$FAKE_BIN"
  cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
if [ "${1:-} ${2:-}" = "auth login" ]; then
  mkdir -p "$HOME/.config/gh"
  printf 'test credential\n' > "$HOME/.config/gh/hosts.yml"
  chmod 644 "$HOME/.config/gh/hosts.yml"
fi
EOF
  chmod +x "$FAKE_BIN/gh"
  AUTH_HOME="$TMP_DIR/auth-home"
  mkdir -p "$AUTH_HOME"
  PATH="$FAKE_BIN:$PATH" GH_CALLS="$GH_CALLS" HOME="$AUTH_HOME" \
    "$ROOT_DIR/git-github/authorize.sh" >"$AUTH_OUTPUT" 2>&1
  grep -q 'WARNING: GitHub credentials and SSH keys will belong to root' "$AUTH_OUTPUT"
  grep -q '^auth login --hostname github.com --web --git-protocol ssh$' "$GH_CALLS"
  grep -q '^auth status --hostname github.com$' "$GH_CALLS"
  test "$(stat -c '%a' "$AUTH_HOME/.config/gh/hosts.yml")" = "600"
fi
