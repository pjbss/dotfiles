## Parent PRD

`issues/prd.md`

## What to build

Add a `local/gitconfig.local`-style override mechanism that layers on top of the public `git/gitconfig.partial`, so company-specific git config (e.g. a WhiskerLabs-specific `user.email`, or extra aliases) can apply without ever being committed to the public repo. This uses the `install_link`/backup pattern established in `issues/001-install-link-helper.md` in `git/install.sh`, and lives under the same gitignored `local/` root as `issues/014-local-zsh-directory.md`.

## Acceptance criteria

- [x] `git/install.sh` (or the generated `~/.gitconfig`) is set up so that `local/gitconfig.local`, if present, overrides/extends values from `git/gitconfig.partial`
- [x] `local/gitconfig.local` is covered by the repo-root `local/` gitignore entry (no separate gitignore rule needed)
- [x] Manually verified: adding a test value to `local/gitconfig.local` (e.g. a distinct `user.email`) and re-running the installer results in that value taking effect in `~/.gitconfig`
- [x] Manually verified: with no `local/gitconfig.local` present, the installer behaves exactly as it does today (only `git/gitconfig.partial` applied)

## Resolution notes

- `git/install.sh`'s managed block (appended into `~/.gitconfig` after the existing marker/backup logic from `issues/001-install-link-helper.md`) now ends with an `[include] path = $DOTFILES_HOME/local/gitconfig.local` line, appended unconditionally right after `git/gitconfig.partial`'s contents.
- Chose an *unconditional* include (rather than only adding it when `local/gitconfig.local` already exists at install time) because git silently ignores an `include.path` pointing at a nonexistent file (verified directly with `git config -f ... --list`, exit 0, no error/warning). This means the override takes effect live as soon as `local/gitconfig.local` is created/edited — no re-running the installer required — mirroring how `zsh/zshrc` re-globs `local/zsh/*.zsh` on every shell start (`issues/014-local-zsh-directory.md`) rather than requiring a reinstall.
- No changes needed to the existing marker/backup/no-op idempotency logic from issue 001 — the include line is just additional static content inside the same managed block.
- Manually verified in a scratch `$HOME` (via `HOME=<scratch dir> bash install.sh`), per the install.sh testing safety rule (never run against the real home dir):
  - First run: symlinks + `~/.gitconfig` created with the managed block ending in the `[include]` stanza pointing at this repo's `local/gitconfig.local`.
  - Second run: clean no-op, no duplicate backups.
  - With `local/gitconfig.local` absent: `HOME=<scratch> git config --get user.email` exits 1 (no value) — identical to pre-change behavior.
  - Created a temporary `local/gitconfig.local` with a distinct `user.email`, confirmed `HOME=<scratch> git config --get user.email` returned it; removed the temporary file afterward (repo's `local/` stayed empty/untracked, confirmed via `git status --short`).

## Blocked by

- Blocked by `issues/001-install-link-helper.md`

## User stories addressed

- User story 16
