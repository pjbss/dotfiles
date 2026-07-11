## Parent PRD

`issues/prd.md`

## What to build

Update the root `README` to reflect the rebuilt repo structure: the hand-rolled zsh module loader (`zsh/modules/*.zsh`), the new prompt segments, the `local/` convention (zsh, gitconfig, skills), and the `dotfiles-sync-agents` command for the agent-agnostic skill system. Per PRD Solution ("this effort... documents itself") and Implementation Decisions.

## Acceptance criteria

- [ ] README describes the `zsh/modules/*.zsh` loader and how to add a new module
- [ ] README describes the new prompt segments (worktree count, ahead/behind, venv, AWS profile)
- [ ] README describes the `local/` directory convention (`local/zsh/`, `local/gitconfig.local`, `local/skills/`) and that it's gitignored/single-machine by design
- [ ] README describes `bin/dotfiles-sync-agents`, the neutral `agents/skills/` format, the `agents/claude-only/` extension layer, and how/where rendered output lands for Claude and Copilot
- [ ] README's install instructions still accurately reflect running `./install.sh`

## Blocked by

- Blocked by `issues/001-install-link-helper.md`
- Blocked by `issues/002-installer-dependency-detection.md`
- Blocked by `issues/003-zsh-module-loader.md`
- Blocked by `issues/010-prompt-git-worktree-count.md`
- Blocked by `issues/011-prompt-git-ahead-behind.md`
- Blocked by `issues/012-prompt-python-venv.md`
- Blocked by `issues/013-prompt-aws-profile.md`
- Blocked by `issues/014-local-zsh-directory.md`
- Blocked by `issues/015-local-gitconfig-override.md`
- Blocked by `issues/017-neutral-skill-format-and-claude-sync.md`
- Blocked by `issues/018-claude-only-extension-layer.md`
- Blocked by `issues/019-copilot-skill-sync.md`
- Blocked by `issues/020-local-skills-sync.md`

## User stories addressed

- User story 29
