#!/usr/bin/env bash
# Shared Linux dependency detection for zcode-linux and shell regression tests.
# Source this file; it intentionally has no main routine.

zcode_linux_read_os_field() {
  local file="$1" key="$2"
  [ -r "$file" ] || return 0
  sed -n \
    -e "s/^${key}=\"\(.*\)\"$/\1/p" \
    -e "s/^${key}=\([^#]*\)$/\1/p" \
    "$file" 2>/dev/null | head -n 1
}

zcode_linux_detect_package_manager() {
  local os_release="${1:-/etc/os-release}"
  local id id_like
  id=$(zcode_linux_read_os_field "$os_release" ID)
  id_like=$(zcode_linux_read_os_field "$os_release" ID_LIKE)
  case " $id $id_like " in
    *\ debian\ *|*\ ubuntu\ *) printf '%s\n' apt ;;
    *\ arch\ *|*\ manjaro\ *|*\ cachyos\ *) printf '%s\n' pacman ;;
    *\ alpine\ *) printf '%s\n' apk ;;
    *) printf '%s\n' unknown ;;
  esac
}

zcode_linux_current_package_manager() {
  zcode_linux_detect_package_manager "${ZCODE_LINUX_OS_RELEASE:-/etc/os-release}"
}

zcode_linux_required_packages() {
  local profile="$1" manager="$2"
  case "$profile:$manager" in
    build:apt) printf '%s\n' coreutils grep python3 make g++ pkg-config ;;
    build:pacman) printf '%s\n' coreutils grep python make gcc pkgconf ;;
    build:apk) printf '%s\n' coreutils grep python3 make g++ pkgconf ;;
    runtime:apt|runtime:pacman|runtime:apk) printf '%s\n' bash tar coreutils ;;
    archive:apt|archive:pacman|archive:apk) printf '%s\n' tar gzip coreutils ;;
    *) return 2 ;;
  esac
}

zcode_linux_required_commands() {
  local profile="$1" manager="${2:-$(zcode_linux_current_package_manager)}"
  case "$profile:$manager" in
    build:apt|build:apk) printf '%s\n' python3 make g++ pkg-config grep find tee date ;;
    build:pacman) printf '%s\n' python make gcc pkg-config grep find tee date ;;
    runtime:*) printf '%s\n' node bash tar md5sum ;;
    archive:*) printf '%s\n' tar gzip md5sum ;;
    *) return 2 ;;
  esac
}

zcode_linux_missing_commands() {
  local profile="$1" manager="${2:-$(zcode_linux_current_package_manager)}"
  local command_name
  zcode_linux_required_commands "$profile" "$manager" | while IFS= read -r command_name; do
    command -v "$command_name" >/dev/null 2>&1 || printf '%s\n' "$command_name"
  done
}

zcode_linux_print_missing() {
  local missing="$1"
  printf '%s\n' "$missing" | sed '/^$/d; s/^/  /'
}

zcode_linux_print_command() {
  local argument
  printf '  $'
  for argument in "$@"; do
    printf ' %q' "$argument"
  done
  printf '\n'
}

zcode_linux_print_package_install_commands() {
  local manager="$1"
  shift
  local packages=("$@") privilege=() missing_sudo=false
  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
      privilege=(sudo)
    else
      missing_sudo=true
    fi
  fi
  case "$manager" in
    apt)
      zcode_linux_print_command "${privilege[@]}" apt update
      zcode_linux_print_command "${privilege[@]}" apt install -y "${packages[@]}"
      ;;
    pacman)
      zcode_linux_print_command "${privilege[@]}" pacman -Sy --needed --noconfirm "${packages[@]}"
      ;;
    apk)
      zcode_linux_print_command "${privilege[@]}" apk add "${packages[@]}"
      ;;
    *)
      printf 'Unsupported package manager: %s\n' "$manager" >&2
      return 1
      ;;
  esac
  if [ "$missing_sudo" = true ]; then
    printf 'sudo is missing; run the displayed commands as root or install sudo before continuing.\n' >&2
    return 1
  fi
}

zcode_linux_confirm_install() {
  local key
  printf 'Run the commands above to install dependencies? [Y/n] '
  if ! IFS= read -r -n 1 -s key; then
    printf '\n'
    return 1
  fi
  printf '\n'
  case "$key" in
    $'\e'|n|N) return 1 ;;
    ''|y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

zcode_linux_run_package_install() {
  local manager="$1"
  shift
  local packages=("$@") privilege=()
  if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || {
      printf 'Missing sudo; cannot execute the package installation commands.\n' >&2
      return 1
    }
    privilege=(sudo)
  fi
  case "$manager" in
    apt)
      "${privilege[@]}" apt update && "${privilege[@]}" apt install -y "${packages[@]}"
      ;;
    pacman)
      "${privilege[@]}" pacman -Sy --needed --noconfirm "${packages[@]}"
      ;;
    apk)
      "${privilege[@]}" apk add "${packages[@]}"
      ;;
    *)
      printf 'Unsupported package manager: %s\n' "$manager" >&2
      return 1
      ;;
  esac
}

zcode_linux_preflight() {
  local profile="$1" manager missing packages
  local -a package_args=()
  manager=$(zcode_linux_current_package_manager)
  missing=$(zcode_linux_missing_commands "$profile" "$manager")
  if [ -z "$missing" ]; then
    return 0
  fi

  printf 'ENVIRONMENT CHECK\n\n'
  printf 'Package manager: %s\n\n' "$manager"
  printf 'Missing dependencies:\n'
  zcode_linux_print_missing "$missing"

  case "$manager" in
    apt|pacman|apk) ;;
    *)
      printf '\nUnknown or unsupported distribution; install these requirements manually.\n' >&2
      return 1
      ;;
  esac

  if printf '%s\n' "$missing" | grep -Eq '^(node|pnpm)$'; then
    printf '\nNode.js 24.14.0 and pnpm 10.33.2 are required; use the pinned toolchain in mise.toml.\n' >&2
    return 1
  fi

  packages=$(zcode_linux_required_packages "$profile" "$manager")
  mapfile -t package_args <<<"$packages"
  printf '\nSolution: install the packages that provide the missing commands.\n'
  printf 'Commands to run:\n'
  zcode_linux_print_package_install_commands "$manager" "${package_args[@]}" || return 1
  zcode_linux_confirm_install || {
    printf 'Dependency installation cancelled.\n' >&2
    return 1
  }
  zcode_linux_run_package_install "$manager" "${package_args[@]}" || return 1
  missing=$(zcode_linux_missing_commands "$profile" "$manager")
  if [ -n "$missing" ]; then
    printf 'Dependencies are still missing after installation:\n' >&2
    zcode_linux_print_missing "$missing" >&2
    return 1
  fi
}
