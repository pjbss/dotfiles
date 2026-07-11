## Parent PRD

`issues/prd.md`

## What to build

Rebuild `zsh/zshrc` around a hand-rolled module loader, replacing the current "source every `.zsh` file found anywhere in the repo tree" approach. Per PRD Implementation Decisions ("Zsh module loading"): `zsh/zshrc` builds `fpath` and sources `zsh/modules/*.zsh`, then `local/zsh/*.zsh` if present, then runs `compinit`. Restructure the existing `zsh/global/*.zsh` files (`aliases.zsh`, `functions.zsh`, `settings.zsh`) into `zsh/modules/` so the current, already-working configuration keeps working under the new loader before any oh-my-zsh plugin porting begins. The `local/zsh/*.zsh` sourcing should no-op cleanly (no error) when `local/` doesn't exist yet — the `local/` directory itself is fleshed out in `issues/014-local-zsh-directory.md`.

This slice does NOT touch the live `~/.zshrc` — it only rebuilds the loader and module files in-repo. Verify by sourcing `zsh/zshrc` directly in a fresh interactive shell (e.g. `zsh -c 'source zsh/zshrc; ...'`) rather than symlinking it into `~/.zshrc` (that cutover is `issues/016-zshrc-cutover.md`).

## Acceptance criteria

- [x] `zsh/zshrc` sources `zsh/modules/*.zsh`, then `local/zsh/*.zsh` (if present), then runs `compinit`
- [x] Existing settings/aliases/functions (currently in `zsh/global/`) are moved into `zsh/modules/` and confirmed still active after sourcing the new `zsh/zshrc` in a test shell
- [x] `zsh/prompt/*.zsh` continues to be sourced and the existing prompt still renders correctly
- [x] Sourcing `zsh/zshrc` in a shell with no `local/` directory present produces no errors
- [x] Dropping a new test `.zsh` file into `zsh/modules/` and re-sourcing confirms it becomes active with no other wiring required

## Resolution notes

- `zsh/global/{aliases,functions,settings}.zsh` moved to `zsh/modules/` via `git mv` (content unchanged).
- `zsh/zshrc` rewritten around the hand-rolled loader: builds `fpath` from `zsh/modules` and `zsh/prompt`, sources `zsh/modules/*.zsh`, then `zsh/prompt/*.zsh` (kept in the load order so the existing prompt keeps rendering, per this issue's own acceptance criteria — the PRD's one-line loader description didn't call this out explicitly), then `$DOTFILES_HOME/local/zsh/*.zsh` if present, then runs `compinit -i`. All three module-loading globs use the `(N)` (nullglob) qualifier so a missing directory (e.g. no `local/` yet) produces zero matches instead of a glob error.
- **Bug fixed while rewriting**: the old self-location logic (`SOURCE="$HOME/.zshrc"` + resolve-symlink loop) only worked when `~/.zshrc` was already a symlink into this repo — exactly the case that doesn't exist yet (per PRD Further Notes) and that this issue's own verification method (`source zsh/zshrc` directly, not via `~/.zshrc`) would never exercise correctly. Replaced with zsh's `${(%):-%x}` expansion, which gives the real path of the file currently being sourced regardless of how it was invoked, then resolves any symlinks from there. Verified this works both sourced directly by relative/absolute path and (once `issues/016-zshrc-cutover.md` lands) via a `~/.zshrc` symlink.
- Changed the shebang from `#!/bin/sh` to `#!/bin/zsh` — the file was already using zsh-only syntax (glob qualifiers, `${(%):-%x}`, `(s/./)` splitting elsewhere in the repo) and is never executed directly (always sourced), so this is documentation-only, not a behavior change.
- No automated tests added, per PRD Testing Decisions. Verified manually via `zsh -c 'source zsh/zshrc; ...'`: (1) direct source from repo root — aliases/functions/prompt all active, exit 0; (2) dropped a throwaway module into `zsh/modules/`, re-sourced, confirmed it activated with zero extra wiring, then removed it; (3) sourced via absolute path from a different `$PWD` (`/tmp`) to confirm self-location isn't cwd-dependent; (4) temporarily created `local/zsh/test.zsh` in-repo, confirmed it gets sourced, then removed it (the `local/` directory and its `.gitignore` entry are `issues/014-local-zsh-directory.md`'s responsibility, not this issue's).

## Blocked by

None - can start immediately

## User stories addressed

- User story 2
