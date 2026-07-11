## Parent PRD

`issues/prd.md`

## What to build

Audit actual shell history to determine which oh-my-zsh `git` plugin aliases/functions are genuinely used day to day, then port only that subset into a new `zsh/modules/git.zsh` module (loaded automatically by the loader built in `issues/003-zsh-module-loader.md`). Per PRD Solution and Implementation Decisions ("Feature porting methodology"): this is a usage audit, not a 1:1 port of oh-my-zsh's ~140-alias `git` plugin.

## Acceptance criteria

- [ ] Shell history has been reviewed to identify which `git` plugin aliases/functions are actually used
- [ ] `zsh/modules/git.zsh` contains only the audited/used subset, sourced automatically by the module loader
- [ ] Each ported alias/function is manually confirmed to behave identically to its oh-my-zsh equivalent (side-by-side check against the oh-my-zsh `git` plugin source)
- [ ] Aliases/functions from the plugin that were never used in history are explicitly left out (not silently copied "just in case")

## Blocked by

- Blocked by `issues/003-zsh-module-loader.md`

## User stories addressed

- User story 3
