## Parent PRD

`issues/prd.md`

## What to build

Add a new prompt function showing the count of git worktrees for the current repo, following the existing pattern in `zsh/prompt/functions.zsh` (alongside `git_prompt_info`, `git_prompt_status`, etc.) and wired into `PROMPT`/`RPROMPT` in `zsh/prompt/settings.zsh`. Per PRD Solution/Implementation Decisions: extends the existing prompt, no new prompt framework.

## Acceptance criteria

- [ ] A new function (e.g. `git_prompt_worktree_count`) is added to `zsh/prompt/functions.zsh` that reports the number of worktrees for the current repo (e.g. via `git worktree list`)
- [ ] The function is composed into `PROMPT`/`RPROMPT` in `zsh/prompt/settings.zsh` alongside existing segments
- [ ] Function is a no-op (prints nothing / doesn't error) outside a git repo
- [ ] Manually verified: prompt shows nothing extra in a repo with a single worktree, and shows a worktree count in a repo with `git worktree add` used to create additional worktrees

## Blocked by

- Blocked by `issues/003-zsh-module-loader.md`

## User stories addressed

- User story 9
- User story 13
