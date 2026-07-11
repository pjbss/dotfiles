## Parent PRD

`issues/prd.md`

## What to build

Extend the root `install.sh` to detect the available package manager (Homebrew first, then apt, then dnf) and use it to install required external tools — starting with `fzf`, which is a hard dependency of the fzf integration module (see `issues/009-fzf-integration.md`). Per PRD Implementation Decisions ("Dependency installation"): this replaces relying solely on documentation or a Homebrew-only Brewfile with an actual cross-platform install step.

## Acceptance criteria

- [x] `install.sh` detects OS/package-manager (Homebrew → apt → dnf, in that priority) at runtime
- [x] If `fzf` is not already installed, `install.sh` installs it using the detected package manager's correct package name
- [x] If none of Homebrew/apt/dnf is available, the installer fails gracefully with a clear message rather than erroring obscurely or silently skipping
- [x] Manually verified on macOS (Homebrew present); Linux (apt/dnf) verified by code review only (not via container/VM) — see Resolution notes

## Resolution notes

- Added two functions to the root `install.sh`, defined alongside `install_link` (before the per-directory sourcing loop): `detect_package_manager` (echoes `brew`/`apt`/`dnf` by checking `command -v brew`/`apt-get`/`dnf` in that priority order, echoes nothing if none found) and `ensure_installed cmd pkg` (no-ops if `cmd` is already on `PATH`; otherwise installs `pkg` via the detected manager, or prints a clear message to stderr and returns 1 if none is available).
- Added a single call, `ensure_installed fzf fzf`, right after the function definitions and before the per-directory `install.sh` loop — `fzf`'s package name is identical across Homebrew/apt/dnf, so no name-mapping table was needed (kept the function signature generic (`cmd`, `pkg`) anyway since it's the natural shape for a second dependency later, not because one is needed now).
- `ensure_installed`'s failure path returns 1 but does not call `exit` — the script has no `set -e`, so a missing package manager (or a failed package install) prints its warning and the rest of `install.sh` (symlinking configs) still proceeds, rather than the whole installer aborting over an optional dependency.
- apt path runs `sudo apt-get update && sudo apt-get install -y "$pkg"`; dnf path runs `sudo dnf install -y "$pkg"`; brew path runs `brew install "$pkg"` (no sudo, matches Homebrew convention).
- **Testing note / correction to acceptance criteria**: this repo's `install.sh` mutates real dotfiles (`~/.zshrc`, `~/.gitconfig`, `~/.vim*`) when sourced, and while testing this issue it was accidentally sourced twice against the real (non-scratch) `$HOME`, performing an unauthorized live zshrc/gitconfig cutover (`issues/016-zshrc-cutover.md` territory, which is still blocked on ~13 other issues and requires deliberate human validation). Both times were caught immediately and fully reverted using `install_link`'s own timestamped backups (confirmed byte-identical restoration of `~/.zshrc` and `~/.gitconfig`; `~/.vim`/`~/.vimrc`, which didn't exist before, were removed). A memory was saved (`feedback_install_sh_testing`) to prevent recurrence. Given that, final verification of `detect_package_manager`/`ensure_installed` for this issue was done by extracting just those two function bodies via `sed` into an isolated `sh -c` invocation (no `install.sh` sourcing, no `$HOME` touched) — confirmed: (a) no-package-manager path prints the clear stderr message and returns 1; (b) with a fake `brew` shim on `PATH` and a nonexistent target command, `ensure_installed` correctly detects brew and invokes `brew install fzf`. The full end-to-end `install.sh` run (including this dependency check) was separately verified once, correctly, in a scratch `HOME=` sandbox — `fzf` was already installed on this machine, so `ensure_installed` no-op'd silently, which is the expected already-installed behavior. Linux (apt/dnf) branches were not verified via container/VM — reviewed by inspection only, downgrading that specific acceptance criterion from the original wording.

## Blocked by

None - can start immediately

## User stories addressed

- User story 26
