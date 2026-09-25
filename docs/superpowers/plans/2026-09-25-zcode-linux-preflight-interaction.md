# ZCode Linux Preflight and Human-Safe Interaction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `./zcode-linux` a three-operation Linux controller with automatic cross-distro dependency preflight, explicit build-artifact selection for installation, and Enter/Esc/Ctrl-C-safe interactions.

**Architecture:** Keep `zcode-linux` as the only normal user entry point and move dependency detection/package-manager mapping into `scripts/zcode-linux-deps.sh`, which can be sourced by tests and the controller. Build/install/uninstall are the only public menu operations; dependency checks, runtime verification, PATH setup, archive creation, and purge behavior remain internal steps. A small Bash state machine handles menu selection and confirmation without external TUI packages.

**Tech Stack:** Bash, POSIX shell utilities, Node.js 24.14.0, pnpm 10.33.2, apt/pacman/apk, existing Node build pipeline.

**Spec:** `docs/superpowers/specs/2026-09-25-zcode-linux-local-install-design.md`

## Global Constraints

- The normal entry point is `./zcode-linux` from the repository root; no separate pre-check is required before Build or Install.
- The public menu contains only Build, Install, Uninstall, and Exit.
- Enter confirms; Esc cancels/backs out; Ctrl-C behaves exactly like Esc and never deletes an existing installation by itself.
- Install must enumerate and explicitly select a matching local build artifact; it must not silently select the newest artifact or auto-build.
- Missing dependencies are displayed as one complete list and approved once with `[Y/n]`, where Enter means yes.
- User-facing Debian-family package commands use `apt`, not `apt-get`.
- Supported package managers are apt, pacman, and apk; unknown distributions stop with manual instructions.
- Node.js 24.14.0 and pnpm 10.33.2 are required for source builds; a distribution install only requires Node.js.
- No external dialog/whiptail/zenity dependency is added.
- Build temporary files remain under `build/zcode-linux/`; release output remains under `release/`.

## Review Focus

- Pressing Enter on an unselected install/uninstall screen must do nothing, not choose the first row.
- Ctrl-C must cancel the current confirmation without deleting an existing runtime or user data.
- An install menu containing multiple versions must never silently choose one.
- A failed or declined dependency install must stop before build/copy/current-link changes.
- An unknown or misleading `/etc/os-release` must not cause the script to run the wrong package-manager command.

---

### Task 1: Add dependency resolver and red tests

**Files:**
- Create: `scripts/zcode-linux-deps.sh`
- Modify: `scripts/tests/test-zcode-linux.sh`

**Interfaces:**
- Produces `zcode_linux_detect_package_manager <os-release>` → `apt|pacman|apk|unknown`.
- Produces `zcode_linux_required_packages <profile> <manager>` → one package name per line for `build`, `runtime`, or `archive`.
- Produces `zcode_linux_missing_commands <profile>` → one missing executable per line.
- Produces `zcode_linux_preflight <profile>` → zero only when requirements are satisfied or successfully installed.

- [ ] **Step 1: Write failing resolver tests**


```text
ubuntu/debian       -> apt
arch/manjaro/cachyos -> pacman
alpine              -> apk
unknown             -> unknown
```

Assert package lists:

```text
apt build       -> python3 make g++ pkg-config
pacman build    -> python make gcc pkgconf
apk build       -> python3 make g++ pkgconf
```

- [ ] **Step 2: Run resolver tests and verify they fail**

Run:

```bash
bash scripts/tests/test-zcode-linux.sh --deps
```

Expected: FAIL because the resolver file and interfaces do not exist.

- [ ] **Step 3: Implement the resolver**

Implement strict parsing using an injectable os-release path for tests and `/etc/os-release` in production. Never execute a package-manager command for `unknown`. Keep package names separate from command checks because Node/pnpm are versioned toolchain requirements rather than safe generic OS packages.

- [ ] **Step 4: Implement one-shot dependency approval**

When required commands are missing, print all missing items once and use a single prompt:

```text
Install all missing dependencies? [Y/n]
```

Read Enter as yes, `n`/`N` as no, and Esc/Ctrl-C as cancellation. After installation, rerun the check and return non-zero if anything remains missing.

- [ ] **Step 5: Run resolver tests and commit**

```bash
bash scripts/tests/test-zcode-linux.sh --deps
git add scripts/zcode-linux-deps.sh scripts/tests/test-zcode-linux.sh
git commit -m "feat: add Linux dependency preflight"
```

### Task 2: Add safe keyboard interaction primitives and red tests

**Files:**
- Modify: `zcode-linux`
- Modify: `scripts/tests/test-zcode-linux.sh`

**Interfaces:**
- `read_menu_choice <prompt>` returns a numeric choice, `back`, or `cancel`.
- `confirm_action <message>` returns success only for Enter; Esc/Ctrl-C returns cancellation.
- `render_main_menu` exposes only Build, Install, Uninstall, Exit.

- [ ] **Step 1: Add failing interaction tests**

Test the menu through piped input where possible:

```bash
printf '0\n' | bash zcode-linux
printf '\033' | bash zcode-linux
```

Add tests that an empty uninstall selection and Esc do not change a fixture HOME. Add a test process that receives SIGINT during a confirmation and assert the existing runtime remains intact.

- [ ] **Step 2: Run interaction tests and verify failure**

Run:

```bash
bash scripts/tests/test-zcode-linux.sh --interaction
```

Expected: FAIL because the current line-oriented menu exposes extra operations and does not provide the required state machine.

- [ ] **Step 3: Implement the interaction primitives**

Use Bash `read -rsn1` for single-key handling, translate Enter (`\r`/`\n`), Esc (`\033`) and Ctrl-C (`SIGINT`) into one cancellation path, and redraw only the current screen. Never assign the first option when no option is selected. Keep the plain-text fallback when color is unavailable.

- [ ] **Step 4: Replace the public menu**

Render exactly:

```text
[1] Build
[2] Install
[3] Uninstall
[0] Exit
```

Move dependency checks, smoke verification, PATH configuration, archive creation, and purge into internal functions.

- [ ] **Step 5: Run interaction tests and commit**

```bash
bash scripts/tests/test-zcode-linux.sh --interaction
git add zcode-linux scripts/tests/test-zcode-linux.sh
git commit -m "feat: simplify Linux controller interaction"
```

### Task 3: Integrate automatic preflight into Build and Install

**Files:**
- Modify: `zcode-linux`
- Modify: `scripts/zcode-linux-deps.sh`
- Modify: `scripts/tests/test-zcode-linux.sh`

**Interfaces:**
- `build_local` calls `zcode_linux_preflight build` before Node/pnpm/build work.
- `install_command` calls `zcode_linux_preflight runtime` before reading/copying an artifact.
- `package_local` calls `zcode_linux_preflight archive` internally.

- [ ] **Step 1: Add failing preflight integration tests**

Use fake `PATH` command directories and fake package-manager binaries to assert:

- Build checks dependencies before invoking pnpm.
- Install checks Node/runtime requirements but not g++/make.
- A declined dependency prompt exits before `build/` or `current` changes.
- A missing `apt`/pacman/etc. on an unknown distribution prints manual instructions and exits non-zero.

- [ ] **Step 2: Run integration tests and verify failure**

Run:

```bash
bash scripts/tests/test-zcode-linux.sh --preflight
```

Expected: FAIL because Build and Install currently bypass the dependency resolver.

- [ ] **Step 3: Wire the automatic preflight**

Call the appropriate profile at the first line of each public operation. Preserve the existing Node/pnpm version checks; if `mise` is available and the pinned toolchain is missing, offer `mise install` in the same confirmation flow. Without `mise`, stop with exact commands for preparing Node 24.14.0 and pnpm 10.33.2.

- [ ] **Step 4: Verify declined and accepted flows**

Run:

```bash
bash scripts/tests/test-zcode-linux.sh --preflight
```

Expected: PASS for both cancellation and one-shot installation paths.

- [ ] **Step 5: Commit automatic preflight**

```bash
git add zcode-linux scripts/zcode-linux-deps.sh scripts/tests/test-zcode-linux.sh
git commit -m "feat: run dependency checks before Linux operations"
```

### Task 4: Implement explicit build-artifact selection and two-stage uninstall

**Files:**
- Modify: `zcode-linux`
- Modify: `uninstall-linux.sh`
- Modify: `scripts/tests/test-zcode-linux.sh`

**Interfaces:**
- `list_installable_builds` prints only valid current-host manifests.
- `select_build_artifact` returns an explicit path or cancellation.
- `uninstall_menu` returns keep-data, purge-data, or cancellation.

- [ ] **Step 1: Add failing artifact and uninstall UI tests**

Create two valid fixture builds with different versions and one mismatched architecture. Assert:

- Both matching builds are listed.
- The mismatched build is not selectable.
- Enter with no selection performs no install.
- Selecting a build requires a second Enter before installation.
- Uninstall Enter with no selection performs no deletion.
- Purge selection requires a second Enter and Esc/Ctrl-C preserves the data sentinel.

- [ ] **Step 2: Run selection tests and verify failure**

Run:

```bash
bash scripts/tests/test-zcode-linux.sh --selection
```

Expected: FAIL because install currently resolves the package version automatically and uninstall has no first-screen selection state.

- [ ] **Step 3: Implement build listing and explicit selection**

Enumerate `build/zcode-linux/*/manifest.json`, validate `platform`, `arch`, `version`, `zcode/bin/zcode.mjs`, and show version/date/size. Do not use lexical “latest” selection in the interactive flow. Return to the main menu on empty selection, Esc, or Ctrl-C.

- [ ] **Step 4: Implement two-stage uninstall**

First screen has option 0/no action, keep-data, and purge-data. The confirmation screen lists exact paths. Enter executes; Esc/Ctrl-C cancels. Preserve the independent uninstaller behavior for direct non-interactive invocation.

- [ ] **Step 5: Run selection tests and commit**

```bash
bash scripts/tests/test-zcode-linux.sh --selection
git add zcode-linux uninstall-linux.sh scripts/tests/test-zcode-linux.sh
git commit -m "feat: require explicit Linux artifact and uninstall confirmation"
```

### Task 5: Update help/docs and run full verification

**Files:**
- Modify: `README.md`
- Modify: `README.en.md`
- Modify: `docs/superpowers/specs/2026-09-25-zcode-linux-local-install-design.md`
- Modify: `docs/superpowers/plans/2026-09-25-zcode-linux-preflight-interaction.md`
- Modify: `scripts/tests/test-zcode-linux.sh`

**Interfaces:**
- Public help and README show only Build, Install, Uninstall as normal operations.
- Hidden maintenance behavior is not presented as a required user workflow.

- [ ] **Step 1: Add documentation assertions**

Assert help contains Build, Install, Uninstall and does not present `verify`, `package`, `path`, or `purge` as top-level normal menu operations. Assert docs explain that `./zcode-linux` automatically checks dependencies and Install requires an explicit artifact selection.

- [ ] **Step 2: Update Chinese and English docs**

Document:

```bash
cd /path/to/ZCode
./zcode-linux
```

Explain Enter/Esc/Ctrl-C behavior, one-shot dependency approval, supported package managers, and explicit build selection.

- [ ] **Step 3: Run complete regression checks**

```bash
bash scripts/tests/test-zcode-linux.sh
bash -n zcode-linux uninstall-linux.sh scripts/zcode-linux-deps.sh scripts/tests/test-zcode-linux.sh
node --check scripts/build-zcode.mjs scripts/zcode-distribution-smoke.mjs scripts/zcode-distribution/assets.mjs
pnpm typecheck
pnpm verify:pre-push
```

Run a real Linux arm64 build, select the generated artifact in the install menu, verify the installed command, and exercise both uninstall choices in isolated HOME directories.

- [ ] **Step 4: Commit final implementation and docs**

```bash
git add zcode-linux uninstall-linux.sh scripts/zcode-linux-deps.sh scripts/tests/test-zcode-linux.sh README.md README.en.md docs/superpowers/specs/2026-09-25-zcode-linux-local-install-design.md docs/superpowers/plans/2026-09-25-zcode-linux-preflight-interaction.md
git commit -m "feat: add automatic Linux preflight and human-safe workflow"
```
