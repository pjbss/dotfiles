## Parent PRD

`issues/prd.md`

## What to build

Perform the direct-swap cutover: run the (now safe/idempotent) installer to back up the live, currently-disconnected `~/.zshrc` (a standalone oh-my-zsh-generated file, per PRD Further Notes) and symlink it to `zsh/zshrc` in this repo, using `install_link` from `issues/001-install-link-helper.md`. This is the point at which `~/.zshrc` first actually becomes a symlink into this repo. Validate by hand across real terminal sessions before considering the migration complete. Per PRD Implementation Decisions ("Cutover sequencing"): no dual-mode/toggle, and actual removal of `~/.oh-my-zsh` remains a separate, manual step taken by the user after validation — not part of this issue or any script in this repo.

This slice should only be started once the module loader and all plugin-parity/prompt slices are done, so the swap doesn't cause a loss of daily-driver functionality.

## Acceptance criteria

- [ ] Running the installer backs up the existing `~/.zshrc` (timestamped) and symlinks `~/.zshrc` to `zsh/zshrc`
- [ ] New interactive shell sessions are opened and manually driven to confirm parity: git aliases, common aliases, python helpers, aws completion/profile-switching, macOS helpers (if on Darwin), fzf key bindings, and all four new prompt segments (worktree count, ahead/behind, venv, AWS profile) all work as expected
- [ ] Any gaps found during manual validation are logged and fixed before considering this issue done
- [ ] Explicitly confirmed as a human decision: oh-my-zsh (`~/.oh-my-zsh`) is NOT removed as part of this issue — that remains a separate manual step for the maintainer once they're confident

## Blocked by

- Blocked by `issues/001-install-link-helper.md`
- Blocked by `issues/002-installer-dependency-detection.md`
- Blocked by `issues/003-zsh-module-loader.md`
- Blocked by `issues/004-git-plugin-port.md`
- Blocked by `issues/005-common-aliases-plugin-port.md`
- Blocked by `issues/006-python-plugin-port.md`
- Blocked by `issues/007-aws-plugin-port.md`
- Blocked by `issues/008-macos-plugin-port.md`
- Blocked by `issues/009-fzf-integration.md`
- Blocked by `issues/010-prompt-git-worktree-count.md`
- Blocked by `issues/011-prompt-git-ahead-behind.md`
- Blocked by `issues/012-prompt-python-venv.md`
- Blocked by `issues/013-prompt-aws-profile.md`
- Blocked by `issues/014-local-zsh-directory.md`
- Blocked by `issues/015-local-gitconfig-override.md`

## User stories addressed

- User story 1
- User story 8
