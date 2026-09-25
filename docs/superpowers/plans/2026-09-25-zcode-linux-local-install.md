# ZCode Linux Local Build and User Install Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a root-level Linux terminal controller that builds the current host architecture, installs and verifies the CLI/TUI/Web runtime for the current user, configures generic user PATH by default, emits optional release archives, and installs an independent uninstaller.

**Architecture:** `zcode-linux` is the only public source-tree controller and owns argument parsing, menu rendering, path configuration, install orchestration, verification dispatch, and package output. Existing `scripts/build-zcode.mjs` is extended with a local staging mode so the established workspace build and asset collection remain the single source of truth. `uninstall-linux.sh` is a standalone POSIX shell script copied into `~/.zcode/uninstall.sh`; it uses a state file to remove only PATH changes made by the installer.

**Tech Stack:** POSIX shell, Bash for the interactive controller and tests, Node.js 24.14.0, pnpm 10.33.2, existing TypeScript/esbuild/CLI/Web build pipeline, tar, md5sum.

**Spec:** `docs/superpowers/specs/2026-09-25-zcode-linux-local-install-design.md`

## Global Constraints

- Only the unified CLI/TUI/Web runtime is in scope; do not add a native SEA binary or Electron installer.
- Only Linux is supported by `zcode-linux`; platform and architecture come from the executing host.
- Build temporary files stay inside the repository under `build/zcode-linux/`; do not use `/tmp`, `/var/tmp`, or user caches for the new flow.
- Final archives go directly under repository-root `release/`; local installation defaults to the runnable build directory.
- User installation is fixed at `$HOME/.zcode/runtime`, `$HOME/.local/bin/zcode`, and `$HOME/.zcode/uninstall.sh`; do not add install-directory flags or `ZCODE_DIST_*` variables.
- PATH configuration is enabled by default; `--no-path` is the explicit opt-out.
- The generic line `export PATH="$HOME/.local/bin:$PATH"` is inserted at Bash top level without ZCode-specific comments.
- Existing shell-file permissions and ownership are preserved; new user data is private and executable files are executable.
- Installation verifies version, Web help, Web readiness, HTTP server info, WebSocket connectivity, and clean shutdown before switching `current`.
- Runtime execution requires Node; runtime execution does not require pnpm.
- Do not change unrelated existing lint warnings or architecture rules.

## Review Focus

- A Bash file with an early non-interactive `return` must receive the generic PATH line before that guard; test it in Task 2.
- Existing `.bashrc` / login files and pre-existing identical PATH lines must not be duplicated or deleted; test idempotence and ownership in Task 2.
- A failed install verification must not replace a working `current` link; test rollback in Task 4.
- The copied uninstaller must work after the source checkout is unavailable and must preserve user data by default; test independence in Task 2.
- A build running on arm64 must produce an arm64-labeled local artifact and reject non-Linux or unsupported architectures; test metadata and argument validation in Task 3.

---

### Task 1: Add red tests and local execution ledger

**Files:**

- Create: `scripts/tests/test-zcode-linux.sh`
- Create: `.superpowers/sdd/2026-09-25-zcode-linux-local-install/progress.md`

**Interfaces:**

- Consumes: the public contract in the spec and the future root command `./zcode-linux`.
- Produces: executable shell tests covering help, PATH, install/uninstall, permissions, local build metadata, and package MD5.

- [ ] **Step 1: Write the failing test harness**

Create a Bash test runner that uses a private temporary `HOME` under `build/zcode-linux/test-home`, invokes the root controller with `bash`, and fails if `zcode-linux` is absent. Include tests for:

```bash
bash zcode-linux --help
bash zcode-linux --h
bash zcode-linux path --check
bash zcode-linux path --configure
bash zcode-linux path --configure
bash zcode-linux install --source "$fixture" --no-verify
bash "$HOME/.zcode/uninstall.sh" --help
bash "$HOME/.zcode/uninstall.sh"
```

The assertions must check: command names in help; generic PATH line appears exactly once; PATH line occurs before an existing `case $-` guard; state file mode is `600`; executable wrapper and copied uninstaller are executable; default uninstall removes runtime and wrapper but keeps a sentinel under `.zcode/v2`; `--purge --yes` removes the data root; and a release archive has a matching `.md5` file.

- [ ] **Step 2: Run the test to verify it fails for the missing feature**

Run:

```bash
bash scripts/tests/test-zcode-linux.sh
```

Expected: FAIL because `zcode-linux` and `uninstall-linux.sh` do not exist yet.

- [ ] **Step 3: Create the execution ledger**

Write the first line exactly as:

```markdown
# SDD ledger — plan: docs/superpowers/plans/2026-09-25-zcode-linux-local-install.md
```

Record baseline checks, the dependency installation result, and the expected red test result.

- [ ] **Step 4: Commit the red tests and plan artifacts**

```bash
git add docs/superpowers/specs/2026-09-25-zcode-linux-local-install-design.md docs/superpowers/plans/2026-09-25-zcode-linux-local-install.md scripts/tests/test-zcode-linux.sh
 git commit -m "docs: plan Linux local installation workflow"
```

The `.superpowers` ledger remains ignored and is not committed.

### Task 2: Implement root controller, PATH configuration, and independent uninstaller

**Files:**

- Create: `zcode-linux`
- Create: `uninstall-linux.sh`
- Modify: `scripts/tests/test-zcode-linux.sh`
- Modify: `.gitignore`

**Interfaces:**

- Consumes: `scripts/tests/test-zcode-linux.sh` expectations from Task 1.
- Produces: `zcode-linux --help`, `zcode-linux menu`, `zcode-linux path --check|--configure`, `zcode-linux install` dispatch, and a standalone `uninstall-linux.sh --help|--purge|--yes`.

- [ ] **Step 1: Implement the minimal help and command parser**

Add a Bash script with `set -Eeuo pipefail`, root discovery from `BASH_SOURCE`, aliases `-h`, `--h`, `--help`, and commands `build`, `install`, `verify`, `package`, `path`, `uninstall`, `purge`, `menu`. Reject non-Linux hosts before build/install operations. Keep the public help free of internal `scripts/...` paths.

- [ ] **Step 2: Implement PATH detection and generic top-level configuration**

Add functions that:

- Detect the current shell without writing Bash syntax into non-Bash configuration.
- For Bash, create `~/.bashrc` only when configuration is requested and it does not exist.
- Insert exactly `export PATH="$HOME/.local/bin:$PATH"` at top level before a known `case $-` early-return guard, without ZCode comments.
- Detect the effective login file in `.bash_profile`, `.bash_login`, `.profile` order and add `[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"` only when needed.
- Store only installer-owned changes in `~/.zcode/install-state.json` with mode `0600`.
- Treat repeated configuration as a no-op.
- Support `path --check`, `path --configure`, and install's default configuration; `install --no-path` skips it.

- [ ] **Step 3: Implement the standalone uninstaller and install copy**

Create `uninstall-linux.sh` so it resolves only fixed user paths, accepts `--help`, `--purge`, and `--yes`, and does not invoke Node or pnpm. It must:

- Remove `~/.local/bin/zcode` and `~/.zcode/runtime` for default uninstall.
- Preserve `~/.zcode/v2` and other user data by default.
- Remove only PATH/login lines recorded in `install-state.json`.
- Remove all ZCode data and itself for `--purge --yes`.
- Reject unsafe target symlinks and non-owner paths.

The install path copies it to `~/.zcode/uninstall.sh` with mode `0700`.

- [ ] **Step 4: Implement the no-argument terminal menu**

Render an ANSI menu showing platform, architecture, build state, install state, and PATH state. Use numbered input, default install PATH configuration, confirmation for purge, and a plain-text fallback when colors are unavailable. Keep menu actions dispatching through the same command functions as argument mode.

- [ ] **Step 5: Run focused tests to verify the implementation passes**

Run:

```bash
bash scripts/tests/test-zcode-linux.sh --path-and-uninstall
```

Expected: PASS for help, idempotent PATH placement, permissions, independent uninstaller, and default/purge data behavior.

- [ ] **Step 6: Commit the controller and uninstaller**

```bash
git add zcode-linux uninstall-linux.sh scripts/tests/test-zcode-linux.sh .gitignore
git commit -m "feat: add Linux user-level controller and uninstaller"
```

### Task 3: Add local build staging and release packaging

**Files:**

- Modify: `scripts/build-zcode.mjs`
- Modify: `zcode-linux`
- Modify: `scripts/tests/test-zcode-linux.sh`
- Modify: `.gitignore`

**Interfaces:**

- Consumes: existing `buildOutputs`, `stageZCodePackage`, runtime asset collection, and root package version.
- Produces: `zcode-linux build`, `zcode-linux package`, `build/zcode-linux/<version>/zcode`, `manifest.json`, `release/*.tar.gz`, and `release/*.tar.gz.md5`.

- [ ] **Step 1: Add failing tests for local metadata and archive output**

Extend the test fixture to run the local staging helper with build outputs stubbed or already present and assert:

```text
manifest.platform == "linux"
manifest.arch == process.arch normalized to x64 or arm64
build/zcode-linux/<version>/zcode/bin/zcode.mjs exists
release/zcode-<version>-linux-<arch>.tar.gz exists
release/zcode-<version>-linux-<arch>.tar.gz.md5 matches md5sum output
```

Also assert that a non-Linux platform override is rejected before any output is created.

- [ ] **Step 2: Run the new tests to verify the expected failure**

Run:

```bash
bash scripts/tests/test-zcode-linux.sh --build-and-package
```

Expected: FAIL because local build mode and the root commands are not implemented.

- [ ] **Step 3: Extend `scripts/build-zcode.mjs` with local mode**

Add a local mode that:

- Does not require `ZCODE_DIST_BASE_URL`.
- Defaults output to `build/zcode-linux/<version>`.
- Reuses existing CLI, server, web, TUI and runtime staging.
- Moves/retains the runnable `zcode/` directory under the local build directory.
- Writes a manifest containing version, platform, arch, Node version and runtime path.
- Does not write the remote installer or SHA-256 release files in local mode.
- Keeps existing `pnpm build:zcode` behavior unchanged.

- [ ] **Step 4: Implement package output in the controller**

Package the local runnable directory directly into repository-root `release/` using the current version and host architecture. Generate only the tar.gz and a sibling `.md5` file for this local flow. Do not delete the runnable build directory.

- [ ] **Step 5: Run focused build and package tests**

Run:

```bash
bash scripts/tests/test-zcode-linux.sh --build-and-package
```

Expected: PASS with the current host reported as `linux-arm64` and matching MD5 output.

- [ ] **Step 6: Commit local build and packaging**

```bash
git add scripts/build-zcode.mjs zcode-linux scripts/tests/test-zcode-linux.sh .gitignore
git commit -m "feat: add Linux local staging and release packaging"
```

### Task 4: Implement installation, runtime verification, and rollback

**Files:**

- Modify: `zcode-linux`
- Modify: `scripts/zcode-distribution-smoke.mjs`
- Modify: `scripts/tests/test-zcode-linux.sh`

**Interfaces:**

- Consumes: local build manifest and archive from Task 3.
- Produces: verified `$HOME/.zcode/runtime/current`, executable `$HOME/.local/bin/zcode`, and smoke verification constrained to repository-local working directories.

- [ ] **Step 1: Add failing tests for install verification and rollback**

Add tests that install a valid fixture, verify `--version`, then attempt installation of a fixture whose runner exits non-zero. Assert that the original `current` symlink and wrapper remain usable after the failed installation.

- [ ] **Step 2: Run the rollback tests to verify the expected failure**

Run:

```bash
bash scripts/tests/test-zcode-linux.sh --install-and-rollback
```

Expected: FAIL because install verification and rollback are not implemented.

- [ ] **Step 3: Implement source and archive installation**

Implement default source installation from the latest/current local build and explicit archive installation. Extract archives only into repository-local `build/zcode-linux/install-staging/`. Copy a verified version into `$HOME/.zcode/runtime/releases/<version>`, verify it before updating `current`, and preserve the previous current link on failure.

Create the wrapper at `$HOME/.local/bin/zcode` with mode `0755`; it must use the recorded install-time Node path and fall back to `command -v node`.

- [ ] **Step 4: Make smoke verification repository-local**

Update the smoke helper so its working directory can be supplied and defaults under `build/zcode-linux/smoke/`. Preserve archive smoke compatibility while eliminating new use of `/tmp`. Verify version, CLI help, TUI runtime initialization when available, Web readiness, server info, WebSocket, and clean shutdown.

- [ ] **Step 5: Run the install and rollback tests**

Run:

```bash
bash scripts/tests/test-zcode-linux.sh --install-and-rollback
```

Expected: PASS, including permissions and current-link preservation.

- [ ] **Step 6: Commit installation and verification**

```bash
git add zcode-linux scripts/zcode-distribution-smoke.mjs scripts/tests/test-zcode-linux.sh
git commit -m "feat: verify Linux installs before activation"
```

### Task 5: Document the public workflow and run repository verification

**Files:**

- Modify: `README.md`
- Modify: `README.en.md`
- Modify: `zcode-linux`
- Modify: `scripts/tests/test-zcode-linux.sh`

**Interfaces:**

- Consumes: all public commands and paths from Tasks 2–4.
- Produces: documented source workflow, help text, complete shell regression tests, and clean repository checks.

- [ ] **Step 1: Add documentation assertions**

Extend the shell tests to assert that the documented command names and fixed user paths match the controller help output and that no deprecated `ZCODE_DIST_HOME`, `ZCODE_DIST_BIN_DIR`, or nested user-facing script path appears in the new Linux section.

- [ ] **Step 2: Update Chinese and English README sections**

Document only the public workflow:

```bash
./zcode-linux
./zcode-linux build
./zcode-linux install
./zcode-linux verify
./zcode-linux package
~/.zcode/uninstall.sh
```

Explain that build artifacts remain under `build/zcode-linux/`, archives under `release/`, PATH configuration is enabled by default, and runtime execution needs Node but not pnpm.

- [ ] **Step 3: Run the complete local shell regression suite**

Run:

```bash
bash scripts/tests/test-zcode-linux.sh
```

Expected: all shell tests pass.

- [ ] **Step 4: Run repository checks**

Run:

```bash
pnpm typecheck
pnpm lint
pnpm architecture:check --changed
pnpm fmt:check
```

Expected: typecheck, architecture check and format check exit 0; lint may retain the baseline warnings recorded before implementation but must not add errors.

- [ ] **Step 5: Commit documentation and final test updates**

```bash
git add README.md README.en.md zcode-linux scripts/tests/test-zcode-linux.sh
git commit -m "docs: document Linux local build and install workflow"
```

- [ ] **Step 6: Perform an end-to-end local run**

Run from the repository root:

```bash
./zcode-linux build
./zcode-linux verify --source "build/zcode-linux/$(node -p 'JSON.parse(require("fs").readFileSync("package.json")).version')/zcode"
./zcode-linux package
./zcode-linux install --no-path
~/.local/bin/zcode --version
~/.local/bin/zcode --web --help
```

Then verify the independent uninstaller from a copied location using a test HOME, without deleting the real developer data.

- [ ] **Step 7: Commit the final verified state**

```bash
git status --short
git diff --check
git log --oneline -5
```

Only after all checks pass, commit any final corrections with a focused message. Push `main` only after the final verification and review.
