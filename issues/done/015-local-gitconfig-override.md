## Parent PRD

`issues/prd.md`

## What to build

Add a `local/gitconfig.local`-style override mechanism that layers on top of the public `git/gitconfig.partial`, so company-specific git config (e.g. a WhiskerLabs-specific `user.email`, or extra aliases) can apply without ever being committed to the public repo. This uses the `install_link`/backup pattern established in `issues/001-install-link-helper.md` in `git/install.sh`, and lives under the same gitignored `local/` root as `issues/014-local-zsh-directory.md`.

## Acceptance criteria

- [ ] `git/install.sh` (or the generated `~/.gitconfig`) is set up so that `local/gitconfig.local`, if present, overrides/extends values from `git/gitconfig.partial`
- [ ] `local/gitconfig.local` is covered by the repo-root `local/` gitignore entry (no separate gitignore rule needed)
- [ ] Manually verified: adding a test value to `local/gitconfig.local` (e.g. a distinct `user.email`) and re-running the installer results in that value taking effect in `~/.gitconfig`
- [ ] Manually verified: with no `local/gitconfig.local` present, the installer behaves exactly as it does today (only `git/gitconfig.partial` applied)

## Blocked by

- Blocked by `issues/001-install-link-helper.md`

## User stories addressed

- User story 16
