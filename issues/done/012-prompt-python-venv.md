## Parent PRD

`issues/prd.md`

## What to build

Add a new prompt function showing the active Python virtualenv or pyenv version, following the existing pattern in `zsh/prompt/functions.zsh` and wired into `PROMPT`/`RPROMPT` in `zsh/prompt/settings.zsh`.

## Acceptance criteria

- [ ] Prompt function reports the active virtualenv name (e.g. from `$VIRTUAL_ENV`) or active pyenv version, whichever is applicable
- [ ] Composed into `PROMPT`/`RPROMPT` in `zsh/prompt/settings.zsh` alongside existing segments
- [ ] Function is a no-op when no venv/pyenv version is active
- [ ] Manually verified: prompt shows the venv name after `source .venv/bin/activate` (or equivalent), and shows nothing when deactivated

## Blocked by

- Blocked by `issues/003-zsh-module-loader.md`

## User stories addressed

- User story 11
- User story 13
