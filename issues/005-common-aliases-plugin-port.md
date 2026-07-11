## Parent PRD

`issues/prd.md`

## What to build

Audit shell history to determine which oh-my-zsh `common-aliases` plugin aliases are genuinely used, then port only that subset into a new `zsh/modules/common-aliases.zsh` module (loaded automatically by the loader from `issues/003-zsh-module-loader.md`). Per PRD Solution and Implementation Decisions ("Feature porting methodology").

## Acceptance criteria

- [ ] Shell history has been reviewed to identify which `common-aliases` plugin aliases are actually used
- [ ] `zsh/modules/common-aliases.zsh` contains only the audited/used subset, sourced automatically by the module loader
- [ ] Each ported alias is manually confirmed to behave identically to its oh-my-zsh equivalent
- [ ] Unused aliases from the plugin are explicitly left out

## Blocked by

- Blocked by `issues/003-zsh-module-loader.md`

## User stories addressed

- User story 4
