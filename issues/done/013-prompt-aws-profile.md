## Parent PRD

`issues/prd.md`

## What to build

Add a new prompt function showing the active `$AWS_PROFILE`, following the existing pattern in `zsh/prompt/functions.zsh` and wired into `PROMPT`/`RPROMPT` in `zsh/prompt/settings.zsh`.

## Acceptance criteria

- [ ] Prompt function reports `$AWS_PROFILE` when set
- [ ] Composed into `PROMPT`/`RPROMPT` in `zsh/prompt/settings.zsh` alongside existing segments
- [ ] Function is a no-op when `$AWS_PROFILE` is unset
- [ ] Manually verified: prompt shows the profile name after `export AWS_PROFILE=foo`, and shows nothing after `unset AWS_PROFILE`

## Blocked by

- Blocked by `issues/003-zsh-module-loader.md`

## User stories addressed

- User story 12
- User story 13
