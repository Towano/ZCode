#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
TEST_ROOT="$ROOT_DIR/build/zcode-linux/test-run"
MODE="${1:-all}"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$*"
}

assert_file() {
  [ -f "$1" ] || fail "expected file: $1"
}

assert_dir() {
  [ -d "$1" ] || fail "expected directory: $1"
}

assert_contains() {
  grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"
}

assert_not_contains() {
  ! grep -Fq -- "$2" "$1" || fail "did not expect '$2' in $1"
}

assert_equals() {
  [ "$1" = "$2" ] || fail "expected '$2', got '$1'"
}

assert_command_success() {
  local output_file="$1"
  shift
  if ! "$@" >"$output_file" 2>&1; then
    cat "$output_file" >&2 || true
    fail "command failed: $*"
  fi
}

assert_command_failure() {
  local output_file="$1"
  shift
  if "$@" >"$output_file" 2>&1; then
    cat "$output_file" >&2 || true
    fail "command unexpectedly succeeded: $*"
  fi
}

prepare_fixture() {
  local fixture="$TEST_ROOT/fixture"
  rm -rf "$fixture"
  mkdir -p "$fixture/zcode/bin"
  cat >"$fixture/zcode/bin/zcode.mjs" <<'NODE'
const args = process.argv.slice(2);
if (args.includes("--version")) {
  console.log("fixture-1.0.0");
} else if (args[0] === "--web" && args.includes("--help")) {
  console.log("Usage: zcode --web");
} else {
  console.log("fixture-runtime");
}
NODE
  chmod 0644 "$fixture/zcode/bin/zcode.mjs"
  cat >"$fixture/manifest.json" <<'JSON'
{
  "version": "fixture-1.0.0",
  "platform": "linux",
  "arch": "arm64",
  "runtimePath": "zcode",
  "nodeVersion": "24.14.0"
}
JSON
  printf '%s\n' "$fixture"
}

test_dependency_resolver() {
  local fixture="$TEST_ROOT/os-release-fixtures"
  rm -rf "$fixture"
  mkdir -p "$fixture"

  cat >"$fixture/ubuntu" <<'EOF'
ID=ubuntu
ID_LIKE=debian
EOF
  cat >"$fixture/debian" <<'EOF'
ID=debian
EOF
  cat >"$fixture/arch" <<'EOF'
ID=arch
EOF
  cat >"$fixture/manjaro" <<'EOF'
ID=manjaro
ID_LIKE=arch
EOF
  cat >"$fixture/cachyos" <<'EOF'
ID=cachyos
ID_LIKE=arch
EOF
  cat >"$fixture/alpine" <<'EOF'
ID=alpine
EOF
  cat >"$fixture/unknown" <<'EOF'
ID=some-linux
ID_LIKE=some-family
EOF

  # This is intentionally red before scripts/zcode-linux-deps.sh exists.
  # shellcheck disable=SC1090
  source "$ROOT_DIR/scripts/zcode-linux-deps.sh"
  assert_equals "$(zcode_linux_detect_package_manager "$fixture/ubuntu")" "apt"
  assert_equals "$(zcode_linux_detect_package_manager "$fixture/debian")" "apt"
  assert_equals "$(zcode_linux_detect_package_manager "$fixture/arch")" "pacman"
  assert_equals "$(zcode_linux_detect_package_manager "$fixture/manjaro")" "pacman"
  assert_equals "$(zcode_linux_detect_package_manager "$fixture/cachyos")" "pacman"
  assert_equals "$(zcode_linux_detect_package_manager "$fixture/alpine")" "apk"
  assert_equals "$(zcode_linux_detect_package_manager "$fixture/unknown")" "unknown"
  assert_equals "$(zcode_linux_required_packages build apt | paste -sd ' ' -)" "python3 make g++ pkg-config"
  assert_equals "$(zcode_linux_required_packages build pacman | paste -sd ' ' -)" "python make gcc pkgconf"
  assert_equals "$(zcode_linux_required_packages build apk | paste -sd ' ' -)" "python3 make g++ pkgconf"
  assert_equals "$(zcode_linux_required_packages runtime apt | paste -sd ' ' -)" "bash tar coreutils"
  assert_equals "$(zcode_linux_required_packages archive pacman | paste -sd ' ' -)" "tar gzip coreutils"
  pass "Linux dependency distribution mapping"
}

test_uninstall_menu_is_safe_by_default() {
  local home="$TEST_ROOT/home-uninstall-menu"
  rm -rf "$home"
  mkdir -p "$home/.zcode/v2"
  printf 'keep\n' >"$home/.zcode/v2/sentinel"
  assert_command_success "$TEST_ROOT/uninstall-menu.txt" bash -c \
    "printf '3\n\n' | env HOME='$home' bash '$ROOT_DIR/zcode-linux'"
  assert_file "$home/.zcode/v2/sentinel"
  pass "uninstall menu does nothing when no option is selected"
}

test_explicit_artifact_selection() {
  local home="$TEST_ROOT/home-selection"
  local build_root="$ROOT_DIR/build/zcode-linux"
  local first="$build_root/selection-a"
  local second="$build_root/selection-b"
  local wrong="$build_root/selection-wrong"
  local fixture
  rm -rf "$home" "$build_root"
  mkdir -p "$home"
  fixture=$(prepare_fixture)
  cp -a "$fixture" "$first"
  cp -a "$fixture" "$second"
  cp -a "$fixture" "$wrong"
  sed -i 's/fixture-1.0.0/selection-a/g' "$first/manifest.json"
  sed -i 's/fixture-1.0.0/selection-b/g' "$second/manifest.json"
  sed -i 's/"arm64"/"x64"/' "$wrong/manifest.json"

  assert_command_success "$TEST_ROOT/selection-empty.txt" bash -c \
    "printf '\n' | env HOME='$home' bash '$ROOT_DIR/zcode-linux' install --no-path --no-verify"
  [ ! -e "$home/.zcode/runtime/current" ] || fail "Enter without an artifact selection installed a runtime"

  assert_command_success "$TEST_ROOT/selection-install.txt" bash -c \
    "printf '2\n\n' | env HOME='$home' bash '$ROOT_DIR/zcode-linux' install --no-path --no-verify"
  [ "$(basename "$(readlink -f "$home/.zcode/runtime/current")")" = "selection-b" ] || fail "selected artifact was not installed"
  assert_contains "$TEST_ROOT/selection-install.txt" "selection-a"
  assert_contains "$TEST_ROOT/selection-install.txt" "selection-b"
  assert_not_contains "$TEST_ROOT/selection-install.txt" "selection-wrong"
  pass "install requires explicit matching artifact selection"
}

test_automatic_preflight() {
  local home="$TEST_ROOT/home-preflight"
  local fixture
  rm -rf "$home"
  mkdir -p "$home"
  fixture=$(prepare_fixture)
  # Hide Node.js while retaining the host's shell utilities. Esc must cancel
  # the one-shot preflight before any install path is changed.
  assert_command_failure "$TEST_ROOT/preflight.txt" bash -c \
    "printf '\033' | env HOME='$home' PATH='/usr/bin:/bin' bash '$ROOT_DIR/zcode-linux' install --source '$fixture' --no-verify"
  assert_contains "$TEST_ROOT/preflight.txt" "ENVIRONMENT CHECK"
  assert_contains "$TEST_ROOT/preflight.txt" "Missing dependencies"
  [ ! -e "$home/.zcode/runtime/current" ] || fail "cancelled preflight changed current runtime"
  pass "install performs automatic preflight before changing runtime"
}

test_interactive_menu() {
  local output="$TEST_ROOT/menu.txt"
  assert_command_success "$output" bash -c "printf '0\n' | bash '$ROOT_DIR/zcode-linux'"
  assert_contains "$output" "[1] Build"
  assert_contains "$output" "[2] Install"
  assert_contains "$output" "[3] Uninstall"
  assert_not_contains "$output" "[3] Verify"
  assert_not_contains "$output" "[4] Package"
  assert_not_contains "$output" "[5] PATH"
  assert_not_contains "$output" "[7] Purge"
  pass "interactive menu exposes only build, install, and uninstall"
}

test_help() {
  local output="$TEST_ROOT/help.txt"
  assert_command_success "$output" bash "$ROOT_DIR/zcode-linux" --help
  assert_contains "$output" "build"
  assert_contains "$output" "install"
  assert_contains "$output" "uninstall"
  assert_contains "$output" "Advanced maintenance commands"
  assert_contains "$output" "verify"
  assert_contains "$output" "package"
  assert_contains "$output" "path"
  assert_contains "$output" "purge"
  assert_contains "$output" "--no-path"
  pass "help exposes the public Linux workflow"
}

test_path_and_uninstall() {
  local home="$TEST_ROOT/home-path"
  local fixture
  rm -rf "$home"
  mkdir -p "$home"
  cat >"$home/.bashrc" <<'BASHRC'
# existing user configuration
case $- in
  *i*) ;;
  *) return ;;
esac
BASHRC
  HOME="$home" bash "$ROOT_DIR/zcode-linux" path --configure >"$TEST_ROOT/path-configure.txt" 2>&1
  local path_line case_line
  path_line=$(grep -n '^export PATH="\$HOME/.local/bin:\$PATH"$' "$home/.bashrc" | head -1 | cut -d: -f1)
  case_line=$(grep -n '^case \$- in$' "$home/.bashrc" | head -1 | cut -d: -f1)
  [ -n "$path_line" ] || fail "generic PATH line was not added"
  [ "$path_line" -lt "$case_line" ] || fail "PATH line was added after the early return"
  [ "$(grep -Fc 'export PATH="$HOME/.local/bin:$PATH"' "$home/.bashrc")" -eq 1 ] || fail "PATH line duplicated"
  assert_not_contains "$home/.bashrc" 'zcode managed path'
  assert_file "$home/.profile"
  assert_contains "$home/.profile" '[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"'
  assert_file "$home/.zcode/install-state.json"
  [ "$(stat -c '%a' "$home/.zcode/install-state.json")" = 600 ] || fail "state file permissions are not 600"

  HOME="$home" bash "$ROOT_DIR/zcode-linux" path --configure >"$TEST_ROOT/path-configure-again.txt" 2>&1
  [ "$(grep -Fc 'export PATH="$HOME/.local/bin:$PATH"' "$home/.bashrc")" -eq 1 ] || fail "PATH configuration is not idempotent"

  local late_home="$TEST_ROOT/home-late-path"
  rm -rf "$late_home"
  mkdir -p "$late_home"
  cat >"$late_home/.bashrc" <<'BASHRC'
case $- in
  *i*) ;;
  *) return ;;
esac
export PATH="$HOME/.local/bin:$PATH"
BASHRC
  HOME="$late_home" bash "$ROOT_DIR/zcode-linux" path --configure >"$TEST_ROOT/path-late.txt" 2>&1
  local late_path_line late_case_line
  late_path_line=$(grep -n '^export PATH="\$HOME/.local/bin:\$PATH"$' "$late_home/.bashrc" | head -1 | cut -d: -f1)
  late_case_line=$(grep -n '^case \$- in$' "$late_home/.bashrc" | head -1 | cut -d: -f1)
  [ "$late_path_line" -lt "$late_case_line" ] || fail "late PATH line was not supplemented at Bash top level"
  [ "$(grep -Fc 'export PATH="$HOME/.local/bin:$PATH"' "$late_home/.bashrc")" -eq 2 ] || fail "existing late PATH line was incorrectly moved or removed"

  fixture=$(prepare_fixture)
  local unsafe_home="$TEST_ROOT/home-unsafe"
  local unsafe_target="$TEST_ROOT/unsafe-target"
  rm -rf "$unsafe_home" "$unsafe_target"
  mkdir -p "$unsafe_home" "$unsafe_target"
  ln -s "$unsafe_target" "$unsafe_home/.zcode"
  assert_command_failure "$TEST_ROOT/unsafe-install.txt" env HOME="$unsafe_home" bash "$ROOT_DIR/zcode-linux" install --source "$fixture" --no-verify
  [ ! -e "$unsafe_target/runtime" ] || fail "install followed an external .zcode symlink"

  HOME="$home" bash "$ROOT_DIR/zcode-linux" install --source "$fixture" --no-verify >"$TEST_ROOT/install.txt" 2>&1
  assert_file "$home/.zcode/uninstall.sh"
  [ -x "$home/.zcode/uninstall.sh" ] || fail "copied uninstaller is not executable"
  assert_file "$home/.local/bin/zcode"
  [ -x "$home/.local/bin/zcode" ] || fail "installed wrapper is not executable"
  mkdir -p "$home/.zcode/v2"
  printf 'keep\n' >"$home/.zcode/v2/sentinel"

  (cd / && HOME="$home" bash "$home/.zcode/uninstall.sh") >"$TEST_ROOT/uninstall.txt" 2>&1
  [ ! -e "$home/.zcode/runtime" ] || fail "default uninstall removed runtime incompletely"
  [ ! -e "$home/.local/bin/zcode" ] || fail "default uninstall kept command wrapper"
  assert_file "$home/.zcode/v2/sentinel"
  assert_not_contains "$home/.bashrc" 'export PATH="$HOME/.local/bin:$PATH"'
  pass "PATH configuration, permissions, independent uninstall, and data preservation"
}

test_install_and_rollback() {
  local home="$TEST_ROOT/home-rollback"
  local first_fixture="$TEST_ROOT/fixture-first"
  local bad_fixture="$TEST_ROOT/fixture-bad"
  local fresh_home="$TEST_ROOT/home-fresh-failure"
  rm -rf "$home" "$first_fixture" "$bad_fixture" "$fresh_home"
  mkdir -p "$home" "$first_fixture/zcode/bin" "$bad_fixture/zcode/bin" "$fresh_home"
  cat >"$first_fixture/zcode/bin/zcode.mjs" <<'NODE'
const args = process.argv.slice(2);
if (args.includes("--version")) console.log("first-1.0.0");
else if (args[0] === "--web" && args.includes("--help")) console.log("Usage: zcode --web");
NODE
  cp "$first_fixture/zcode/bin/zcode.mjs" "$bad_fixture/zcode/bin/zcode.mjs"
  cat >"$first_fixture/manifest.json" <<'JSON'
{"version":"first-1.0.0","platform":"linux","arch":"arm64","runtimePath":"zcode","nodeVersion":"24.14.0"}
JSON
  cat >"$bad_fixture/manifest.json" <<'JSON'
{"version":"bad-1.0.0","platform":"linux","arch":"arm64","runtimePath":"zcode","nodeVersion":"24.14.0"}
JSON
  assert_command_failure "$TEST_ROOT/rollback-fresh.txt" env HOME="$fresh_home" bash "$ROOT_DIR/zcode-linux" install --source "$bad_fixture"
  [ ! -e "$fresh_home/.local/bin/zcode" ] || fail "failed first install left a command wrapper"
  [ ! -e "$fresh_home/.zcode/runtime/current" ] || fail "failed first install created current"

  HOME="$home" bash "$ROOT_DIR/zcode-linux" install --source "$first_fixture" --no-verify >"$TEST_ROOT/rollback-first.txt" 2>&1
  local current_before
  current_before=$(readlink -f "$home/.zcode/runtime/current")
  assert_command_failure "$TEST_ROOT/rollback-bad.txt" env HOME="$home" bash "$ROOT_DIR/zcode-linux" install --source "$bad_fixture"
  [ "$(readlink -f "$home/.zcode/runtime/current")" = "$current_before" ] || fail "failed install replaced current runtime"
  [ "$(HOME="$home" "$home/.local/bin/zcode" --version)" = first-1.0.0 ] || fail "previous runtime is no longer usable"
  pass "failed install preserves the previous current runtime"
}

test_runtime_dependencies() {
  local version runtime
  version=$(node -e 'const fs=require("node:fs"); process.stdout.write(JSON.parse(fs.readFileSync("package.json", "utf8")).version)')
  runtime="$ROOT_DIR/build/zcode-linux/$version/zcode"
  [ -d "$runtime" ] || return 0
  assert_file "$runtime/agent/node_modules/@zcode/tui/package.json"
  assert_file "$runtime/agent/node_modules/@mbears/opentui-core/package.json"
  pass "local runtime includes TUI package dependencies"
}

test_package() {
  local home="$TEST_ROOT/home-package"
  local fixture
  rm -rf "$home" "$ROOT_DIR/release"
  mkdir -p "$home"
  local build_help="$TEST_ROOT/build-zcode-help.txt"
  assert_command_success "$build_help" node "$ROOT_DIR/scripts/build-zcode.mjs" --help
  assert_contains "$build_help" "--local"
  fixture=$(prepare_fixture)
  HOME="$home" bash "$ROOT_DIR/zcode-linux" package --source "$fixture" >"$TEST_ROOT/package.txt" 2>&1
  local archive="$ROOT_DIR/release/zcode-fixture-1.0.0-linux-arm64.tar.gz"
  assert_file "$archive"
  assert_file "$archive.md5"
  (cd "$ROOT_DIR" && md5sum -c "$archive.md5") >"$TEST_ROOT/md5.txt" 2>&1 || {
    cat "$TEST_ROOT/md5.txt" >&2
    fail "MD5 verification failed"
  }
  local archive_home="$TEST_ROOT/home-archive"
  rm -rf "$archive_home"
  mkdir -p "$archive_home"
  HOME="$archive_home" bash "$ROOT_DIR/zcode-linux" install --archive "$archive" --no-path --no-verify >"$TEST_ROOT/archive-install.txt" 2>&1
  [ "$(HOME="$archive_home" "$archive_home/.local/bin/zcode" --version)" = fixture-1.0.0 ] || fail "archive installation did not produce a runnable command"
  pass "release archive and MD5 are generated and installable"
}

rm -rf "$TEST_ROOT"
mkdir -p "$TEST_ROOT"

case "$MODE" in
  --interaction)
    test_interactive_menu
    ;;
  --preflight)
    test_automatic_preflight
    ;;
  --selection)
    test_explicit_artifact_selection
    ;;
  --uninstall-menu)
    test_uninstall_menu_is_safe_by_default
    ;;
  --deps)
    test_dependency_resolver
    ;;
  --path-and-uninstall)
    test_help
    test_path_and_uninstall
    ;;
  --build-and-package|--install-and-rollback)
    test_help
    if [ "$MODE" = "--build-and-package" ]; then
      test_runtime_dependencies
      test_package
    else
      test_install_and_rollback
    fi
    ;;
  all)
    test_dependency_resolver
    test_interactive_menu
    test_help
    test_path_and_uninstall
    test_install_and_rollback
    test_runtime_dependencies
    test_package
    test_automatic_preflight
    test_uninstall_menu_is_safe_by_default
    test_explicit_artifact_selection
    ;;
  *)
    fail "unknown test mode: $MODE"
    ;;
esac

pass "zcode Linux shell regression suite"
