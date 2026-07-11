## Parent PRD

`issues/prd.md`

## What to build

Introduce a gitignored `local/` directory at the repo root, with `local/zsh/*.zsh` sourced automatically by `zsh/zshrc` after the public `zsh/modules/*.zsh` (the loader from `issues/003-zsh-module-loader.md` already has the hook point for this). Per PRD Solution and Implementation Decisions ("Private/company config"): this holds company-specific (WhiskerLabs) aliases/functions with zero risk of being committed to the public repo.

## Acceptance criteria

- [ ] `local/` is added to `.gitignore` at the repo root
- [ ] `zsh/zshrc` sources `local/zsh/*.zsh` after `zsh/modules/*.zsh`, if `local/zsh/` exists
- [ ] Manually verified: creating a test file at `local/zsh/test.zsh` with a sample alias and re-sourcing `zsh/zshrc` activates it with no additional wiring
- [ ] Manually verified: `git status` shows nothing under `local/` after adding the test file (confirming the gitignore is effective)

## Blocked by

- Blocked by `issues/003-zsh-module-loader.md`

## User stories addressed

- User story 14
- User story 15
