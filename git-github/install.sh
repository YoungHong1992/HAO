#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

HAO_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HAO_REPO_DIR="$(cd "$HAO_SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$HAO_REPO_DIR/lib/common.sh"
# shellcheck source=../lib/agent-convention.sh
source "$HAO_REPO_DIR/lib/agent-convention.sh"

readonly GH_KEYRING_URL="https://cli.github.com/packages/githubcli-archive-keyring.gpg"
readonly GH_KEYRING_PATH="/etc/apt/keyrings/githubcli-archive-keyring.gpg"
readonly GH_SOURCE_PATH="/etc/apt/sources.list.d/github-cli.list"
readonly AUTH_HELPER_PATH="/usr/local/bin/hao-github-authorize"
readonly GH_KEY_FINGERPRINT_ONE="2C6106201985B60E6C7AC87323F3D4EA75716059"
readonly GH_KEY_FINGERPRINT_TWO="7F38BBB59D064DBCB3D84D725612B36462313325"

show_help() {
    cat <<'EOF'
HAO Git + GitHub tooling

Required variables:
  HAO_GIT_NAME                 Exact Git commit display name
  HAO_GIT_EMAIL                Exact verified or GitHub noreply email
  HAO_GIT_MACHINE_ROLE         workstation | server
  HAO_GIT_SCOPE                global | repository

Optional variables:
  HAO_GIT_TARGET_USER          Target OS user; defaults to non-root SUDO_USER
  HAO_GIT_REPO_DIR             Required for repository scope
  HAO_GH_AUTH_MODE             web | skip (default: web)
  HAO_GIT_ALLOW_IDENTITY_CHANGE=yes
  HAO_GIT_ALLOW_SERVER_AUTH=yes
  HAO_GIT_CONFIG_ONLY=1        Configure an already installed Git; do not install packages/helper
  HAO_GIT_SKIP_AGENT_CONVENTION=1  Do not write the Git/GitHub convention block
                                   into detected AI-assistant instruction files
  HAO_GIT_AGENT_FILES          Comma-separated absolute paths overriding
                               assistant auto-detection

After installation a managed HAO-GIT-GITHUB convention block is written into
detected AI-assistant instruction files (Claude Code, Pi, Codex CLI, OpenCode)
so agents use `gh` for GitHub operations instead of raw API calls or tokens.

GitHub authorization is deliberately separate from apply. After installation,
run `hao-github-authorize` as the target user to complete browser/device login
with the SSH Git protocol.
EOF
}

for arg in "$@"; do
    case "$arg" in
        -h|--help) show_help; exit 0 ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

die() {
    log_error "$*"
    exit 1
}

is_hao_managed_file() {
    [ -f "$1" ] && head -n 12 "$1" 2>/dev/null | grep -q 'Managed by HAO'
}

verify_github_keyring() {
    local keyring="$1" fingerprints fingerprint found=false
    fingerprints="$(gpg --show-keys --with-colons "$keyring" 2>/dev/null \
        | awk -F: '$1 == "pub" { want_fingerprint=1; next }
                     want_fingerprint && $1 == "fpr" { print $10; want_fingerprint=0 }')"
    [ -n "$fingerprints" ] || return 1
    while IFS= read -r fingerprint; do
        case "$fingerprint" in
            "$GH_KEY_FINGERPRINT_ONE"|"$GH_KEY_FINGERPRINT_TWO") found=true ;;
            *) return 1 ;;
        esac
    done <<<"$fingerprints"
    [ "$found" = true ]
}

apt_source_matches() {
    local path="$1" expected="$2" active_lines
    active_lines="$(grep -Ev '^[[:space:]]*(#|$)' "$path" 2>/dev/null || true)"
    [ "$active_lines" = "$expected" ]
}

require_explicit_identity() {
    [ -n "${HAO_GIT_NAME:-}" ] || die "HAO_GIT_NAME is required; HAO never guesses a commit name."
    [ -n "${HAO_GIT_EMAIL:-}" ] || die "HAO_GIT_EMAIL is required; HAO never guesses a commit email."
    [[ "$HAO_GIT_NAME" != *$'\n'* && "$HAO_GIT_NAME" != *$'\r'* ]] || die "HAO_GIT_NAME contains a newline."
    if ! [[ "$HAO_GIT_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
        die "HAO_GIT_EMAIL is not a valid email address."
    fi
}

resolve_target_user() {
    local candidate="${HAO_GIT_TARGET_USER:-}"
    if [ -z "$candidate" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        candidate="$SUDO_USER"
    fi
    [ -n "$candidate" ] || die "HAO_GIT_TARGET_USER is required when no non-root SUDO_USER is available."
    id "$candidate" >/dev/null 2>&1 || die "Target user does not exist: $candidate"
    printf '%s' "$candidate"
}

target_home_for() {
    local user="$1" home
    home="$(getent passwd "$user" | awk -F: '{print $6}')"
    [ -n "$home" ] && [ -d "$home" ] || die "Target user has no usable home directory: $user"
    printf '%s' "$home"
}

run_as_target() {
    if [ "$TARGET_USER" = "$(id -un)" ]; then
        HOME="$TARGET_HOME" "$@"
    else
        runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" "$@"
    fi
}

github_authenticated() {
    command -v gh >/dev/null 2>&1 \
        && run_as_target gh auth status --hostname github.com >/dev/null 2>&1
}

validate_configuration() {
    require_explicit_identity
    case "${HAO_GIT_MACHINE_ROLE:-}" in
        workstation|server) ;;
        *) die "HAO_GIT_MACHINE_ROLE must be workstation or server." ;;
    esac
    case "${HAO_GIT_SCOPE:-}" in
        global) ;;
        repository)
            [ -n "${HAO_GIT_REPO_DIR:-}" ] || die "HAO_GIT_REPO_DIR is required for repository scope."
            [ -d "$HAO_GIT_REPO_DIR/.git" ] || die "Not a Git repository: $HAO_GIT_REPO_DIR"
            HAO_GIT_REPO_DIR="$(cd "$HAO_GIT_REPO_DIR" && pwd -P)"
            ;;
        *) die "HAO_GIT_SCOPE must be global or repository." ;;
    esac
    case "${HAO_GH_AUTH_MODE:-web}" in
        web|skip) ;;
        *) die "HAO_GH_AUTH_MODE must be web or skip." ;;
    esac
    if [ "$HAO_GIT_MACHINE_ROLE" = "server" ] \
        && [ "${HAO_GH_AUTH_MODE:-web}" = "web" ] \
        && [ "${HAO_GIT_ALLOW_SERVER_AUTH:-}" != "yes" ]; then
        die "Personal GitHub authorization on a server requires HAO_GIT_ALLOW_SERVER_AUTH=yes."
    fi
}

install_git_and_gh() {
    check_root
    export DEBIAN_FRONTEND=noninteractive
    local tmp_dir key_tmp source_tmp source_line
    source_line="deb [arch=$(dpkg --print-architecture) signed-by=$GH_KEYRING_PATH] https://cli.github.com/packages stable main"
    if [ -e "$GH_SOURCE_PATH" ] && ! apt_source_matches "$GH_SOURCE_PATH" "$source_line"; then
        die "Existing GitHub CLI apt source is not the expected official entry: $GH_SOURCE_PATH"
    fi
    if [ -e "$AUTH_HELPER_PATH" ] && ! is_hao_managed_file "$AUTH_HELPER_PATH"; then
        die "Refusing to overwrite an untracked authorization helper: $AUTH_HELPER_PATH"
    fi

    apt-get update -qq
    apt-get install -y -qq git ca-certificates curl gnupg util-linux

    tmp_dir="$(mktemp -d)"
    key_tmp="$tmp_dir/githubcli-archive-keyring.gpg"
    source_tmp="$tmp_dir/github-cli.list"
    trap 'rm -rf "$tmp_dir"' EXIT
    curl -fsSL --connect-timeout 30 "$GH_KEYRING_URL" -o "$key_tmp"
    if ! verify_github_keyring "$key_tmp"; then
        die "GitHub CLI archive key fingerprint verification failed."
    fi

    install -d -m 0755 /etc/apt/keyrings /etc/apt/sources.list.d
    if [ -e "$GH_KEYRING_PATH" ]; then
        verify_github_keyring "$GH_KEYRING_PATH" \
            || die "Existing GitHub CLI keyring has an unapproved fingerprint: $GH_KEYRING_PATH"
    else
        install -m 0644 "$key_tmp" "$GH_KEYRING_PATH"
    fi

    if [ ! -e "$GH_SOURCE_PATH" ]; then
        {
            echo "# Managed by HAO"
            echo "# Service: git-github"
            echo "$source_line"
        } > "$source_tmp"
        install -m 0644 "$source_tmp" "$GH_SOURCE_PATH"
    fi
    apt-get update -qq
    apt-get install -y -qq gh

    install -m 0755 "$HAO_SCRIPT_DIR/authorize.sh" "$AUTH_HELPER_PATH"
    rm -rf "$tmp_dir"
    trap - EXIT
}

git_config_get() {
    local key="$1"
    if [ "$HAO_GIT_SCOPE" = "global" ]; then
        run_as_target git config --global --get "$key" 2>/dev/null || true
    else
        run_as_target git -C "$HAO_GIT_REPO_DIR" config --local --get "$key" 2>/dev/null || true
    fi
}

git_config_set() {
    local key="$1" value="$2"
    if [ "$HAO_GIT_SCOPE" = "global" ]; then
        run_as_target git config --global "$key" "$value"
    else
        run_as_target git -C "$HAO_GIT_REPO_DIR" config --local "$key" "$value"
    fi
}

configure_identity() {
    local current_name current_email
    current_name="$(git_config_get user.name)"
    current_email="$(git_config_get user.email)"

    if { [ -n "$current_name" ] && [ "$current_name" != "$HAO_GIT_NAME" ]; } \
        || { [ -n "$current_email" ] && [ "$current_email" != "$HAO_GIT_EMAIL" ]; }; then
        [ "${HAO_GIT_ALLOW_IDENTITY_CHANGE:-}" = "yes" ] \
            || die "Git identity already exists with different values; set HAO_GIT_ALLOW_IDENTITY_CHANGE=yes after review."
    fi

    git_config_set user.name "$HAO_GIT_NAME"
    git_config_set user.email "$HAO_GIT_EMAIL"
    git_config_set hao.identityConfigured true
}

git_github_convention_text() {
    cat <<'EOF'
## Git / GitHub 操作约定（gh）

本机 GitHub 操作一律使用官方 GitHub CLI（`gh`），不要手写 GitHub REST/GraphQL
调用，也不要引导用户创建长期 Personal Access Token：

- PR：`gh pr create` / `gh pr view` / `gh pr checks` / `gh pr merge`。
- Issue：`gh issue create` / `gh issue list`。
- CI：`gh run list` / `gh run view` / `gh run watch`。
- Release：`gh release list` / `gh release view`（创建 release 前先确认项目的发布流程）。
- 需要裸 API 时用 `gh api`，它复用已有登录凭据。

授权与安全：

- 认证状态用 `gh auth status` 检查。未登录时提示用户运行 `hao-github-authorize`
  （web/设备码登录 + SSH Git 协议），不要代替用户输入凭据。
- 禁止在命令行、日志或提交内容中出现 token 值。
- Git 推送走 SSH 协议；提交身份已由系统配置好，不要擅自修改 `user.name` / `user.email`。
- 提交与 PR 前先运行项目自带的测试/检查（如有）。
EOF
}

print_result() {
    echo "Git/GitHub tooling configured"
    echo "  target_user: $TARGET_USER"
    echo "  machine_role: $HAO_GIT_MACHINE_ROLE"
    echo "  scope: $HAO_GIT_SCOPE"
    [ "$HAO_GIT_SCOPE" = "repository" ] && echo "  repository: $HAO_GIT_REPO_DIR"
    echo "  git_name: $HAO_GIT_NAME"
    echo "  git_email: $HAO_GIT_EMAIL"
    echo "  git: $(git --version)"
    command -v gh >/dev/null 2>&1 && echo "  gh: $(gh --version | head -1)"

    if [ "${HAO_GH_AUTH_MODE:-web}" = "web" ]; then
        if github_authenticated; then
            echo "  GitHub authorization: already configured for $TARGET_USER"
        else
            echo ""
            echo "User authorization is still required. Run as $TARGET_USER:"
            echo "  hao-github-authorize"
            echo "The helper uses GitHub web/device login with the SSH Git protocol."
        fi
    else
        echo "  GitHub authorization: skipped by profile"
    fi
}

write_agent_convention() {
    local agent_files=() agent_file line
    if [ "${HAO_GIT_SKIP_AGENT_CONVENTION:-}" = "1" ]; then
        return 0
    fi
    if [ -n "${HAO_GIT_AGENT_FILES:-}" ]; then
        IFS=',' read -ra agent_files <<< "$HAO_GIT_AGENT_FILES"
    else
        while IFS= read -r line; do
            [ -n "$line" ] && agent_files+=("$line")
        done < <(hao_detect_agent_files "$TARGET_HOME")
    fi
    if [ "${#agent_files[@]}" -eq 0 ]; then
        log_warning "No AI assistant detected; Git/GitHub agent convention not written."
        return 0
    fi
    for agent_file in "${agent_files[@]}"; do
        agent_file="$(echo "$agent_file" | tr -d '[:space:]')"
        [ -z "$agent_file" ] && continue
        git_github_convention_text | hao_write_agent_convention "$agent_file" "HAO-GIT-GITHUB" "$TARGET_USER"
        log_success "Agent convention written: $agent_file"
    done
}

validate_configuration
TARGET_USER="$(resolve_target_user)"
readonly TARGET_USER
TARGET_HOME="$(target_home_for "$TARGET_USER")"
readonly TARGET_HOME
if [ "$TARGET_USER" = "root" ] && [ "${HAO_GH_AUTH_MODE:-web}" = "web" ]; then
    log_warning "GitHub credentials and SSH keys will belong to root; use this only when root is the intended Git operator."
fi

if [ "${HAO_GIT_CONFIG_ONLY:-}" != "1" ]; then
    install_git_and_gh
else
    command -v git >/dev/null 2>&1 || die "Git is required for configuration-only mode."
fi

configure_identity
write_agent_convention
print_result
