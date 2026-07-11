## Parent PRD

`issues/prd.md`

## What to build

Port fzf key bindings and completion into a new `zsh/modules/fzf.zsh` module by sourcing fzf's own integration directly (e.g. `fzf --zsh`), rather than oh-my-zsh's `fzf` plugin wrapper. Per PRD Solution and Implementation Decisions ("Feature porting methodology": fzf module ported based on its actual non-alias behavior via `fzf --zsh` integration). Depends on `fzf` being installed, which the installer (`issues/002-installer-dependency-detection.md`) ensures.

## Acceptance criteria

- [ ] `zsh/modules/fzf.zsh` sources fzf's native zsh integration (`fzf --zsh` or equivalent), sourced automatically by the module loader
- [ ] Fuzzy history search (Ctrl-R) and fuzzy file/completion behavior are manually confirmed to work equivalently to the previous oh-my-zsh `fzf` plugin setup
- [ ] No dependency on oh-my-zsh's `fzf` plugin wrapper remains

## Blocked by

- Blocked by `issues/003-zsh-module-loader.md`
- Blocked by `issues/002-installer-dependency-detection.md`

## User stories addressed

- User story 6
