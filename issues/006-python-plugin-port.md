## Parent PRD

`issues/prd.md`

## What to build

Audit shell history to determine which oh-my-zsh `python` plugin aliases/functions are genuinely used, then port only that subset into a new `zsh/modules/python.zsh` module (loaded automatically by the loader from `issues/003-zsh-module-loader.md`). Per PRD Solution and Implementation Decisions ("Feature porting methodology").

Note: the prompt-facing part of Python support (showing the active venv/pyenv version in the prompt) is a separate slice — `issues/012-prompt-python-venv.md`. This slice is scoped to the plugin's shell aliases/functions only (e.g. virtualenv helpers, pip shortcuts).

## Acceptance criteria

- [ ] Shell history has been reviewed to identify which `python` plugin aliases/functions are actually used
- [ ] `zsh/modules/python.zsh` contains only the audited/used subset, sourced automatically by the module loader
- [ ] Each ported alias/function is manually confirmed to behave identically to its oh-my-zsh equivalent
- [ ] Unused aliases/functions from the plugin are explicitly left out

## Blocked by

- Blocked by `issues/003-zsh-module-loader.md`

## User stories addressed

- User story 4
