## Parent PRD

`issues/prd.md`

## What to build

Add a new prompt function showing ahead/behind commit counts relative to the current branch's upstream, following the existing pattern in `zsh/prompt/functions.zsh` and wired into `PROMPT`/`RPROMPT` in `zsh/prompt/settings.zsh`. Note the repo already has a partial `git_prompt_ahead` (ahead-only, boolean) in `zsh/prompt/functions.zsh` — this should be replaced/extended to show both ahead and behind counts (e.g. via `git rev-list --left-right --count @{upstream}...HEAD`).

## Acceptance criteria

- [ ] Prompt function reports both ahead and behind commit counts vs. the branch's upstream (not just a boolean ahead flag)
- [ ] Composed into `PROMPT`/`RPROMPT` in `zsh/prompt/settings.zsh` alongside existing segments
- [ ] Function is a no-op when there is no upstream configured for the current branch (no error, no misleading output)
- [ ] Manually verified: prompt correctly shows counts after using `git commit` locally (ahead) and after a remote-only commit is fetched (behind)

## Blocked by

- Blocked by `issues/003-zsh-module-loader.md`

## User stories addressed

- User story 10
- User story 13
