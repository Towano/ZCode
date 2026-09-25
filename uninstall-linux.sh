#!/usr/bin/env bash
set -Eeuo pipefail

ZCODE_HOME="${HOME:?HOME is required}/.zcode"
RUNTIME_HOME="$ZCODE_HOME/runtime"
COMMAND_PATH="$HOME/.local/bin/zcode"
STATE_FILE="$ZCODE_HOME/install-state.json"
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
LOGIN_BRIDGE='[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"'

usage() {
  cat <<'EOF'
Usage:
  uninstall.sh [options]

Options:
  -h, --h, --help
      Show this help.
  --purge
      Remove the program and ZCode user data.
  --yes
      Skip confirmation for --purge.

Default behavior removes the program and keeps user data.
EOF
}

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

state_true() {
  local key="$1"
  [ -f "$STATE_FILE" ] && grep -Eq '"'"$key"'"[[:space:]]*:[[:space:]]*true' "$STATE_FILE"
}

state_value() {
  local key="$1"
  [ -f "$STATE_FILE" ] || return 0
  sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$STATE_FILE" | head -n 1
}

safe_user_path() {
  local path="$1"
  case "$path" in
    "$HOME"/*) ;;
    *) fail "refusing to operate outside the current user's home: $path" ;;
  esac
  if [ -L "$path" ]; then
    local target
    target=$(readlink -f "$path" 2>/dev/null || true)
    case "$target" in
      "$HOME"/*) ;;
      *) fail "refusing to follow a symlink outside the current user's home: $path" ;;
    esac
  fi
  if [ -e "$path" ] && [ "$(stat -c '%u' "$path")" != "$(id -u)" ]; then
    fail "refusing to modify a path not owned by the current user: $path"
  fi
}

remove_path_line() {
  local file="$1"
  [ -f "$file" ] || return 0
  sed -i '/^export PATH="\$HOME\/\.local\/bin:\$PATH"$/d' "$file"
}

remove_login_bridge() {
  local file="$1"
  [ -f "$file" ] || return 0
  sed -i '/^\[ -f "\$HOME\/\.bashrc" \] && \. "\$HOME\/\.bashrc"$/d' "$file"
}

remove_recorded_shell_changes() {
  local path_file login_file
  if state_true pathLineAdded; then
    path_file=$(state_value pathFile)
    [ -n "$path_file" ] && remove_path_line "$path_file"
  fi
  if state_true loginBridgeAdded; then
    login_file=$(state_value loginFile)
    [ -n "$login_file" ] && remove_login_bridge "$login_file"
  fi
}

confirm_purge() {
  if [ "${1:-false}" = true ]; then
    return 0
  fi
  printf 'This removes ZCode program data under %s. Continue? [y/N] ' "$ZCODE_HOME"
  local answer
  read -r answer || return 1
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) printf 'Purge cancelled.\n'; return 1 ;;
  esac
}

uninstall_program() {
  safe_user_path "$RUNTIME_HOME"
  safe_user_path "$COMMAND_PATH"
  remove_recorded_shell_changes
  rm -rf "$RUNTIME_HOME"
  rm -f "$COMMAND_PATH"
  printf 'ZCode program removed. User data was kept.\n'
}

purge_program() {
  local yes=false
  [ "${1:-}" = true ] && yes=true
  confirm_purge "$yes" || return 0
  safe_user_path "$ZCODE_HOME"
  safe_user_path "$COMMAND_PATH"
  remove_recorded_shell_changes
  rm -rf "$ZCODE_HOME"
  rm -f "$COMMAND_PATH"
  printf 'ZCode program and user data removed.\n'
}

main() {
  local purge=false
  local yes=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --purge) purge=true; shift ;;
      --yes) yes=true; shift ;;
      -h|--h|--help) usage; return 0 ;;
      *) fail "unknown option: $1" ;;
    esac
  done
  if [ "$purge" = true ]; then
    purge_program "$yes"
  else
    uninstall_program
  fi
}

main "$@"
