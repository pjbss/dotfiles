## Parent PRD

`issues/prd.md`

## What to build

Update the root `README` to reflect the rebuilt repo structure: the hand-rolled zsh module loader (`zsh/modules/*.zsh`), the new prompt segments, the `local/` convention (zsh, gitconfig, skills), and the `dotfiles-sync-agents` command for the agent-agnostic skill system. Per PRD Solution ("this effort... documents itself") and Implementation Decisions.

## Acceptance criteria

- [x] README describes the `zsh/modules/*.zsh` loader and how to add a new module
- [x] README describes the new prompt segments (worktree count, ahead/behind, venv, AWS profile)
- [x] README describes the `local/` directory convention (`local/zsh/`, `local/gitconfig.local`, `local/skills/`) and that it's gitignored/single-machine by design
- [x] README describes `bin/dotfiles-sync-agents`, the neutral `agents/skills/` format, the `agents/claude-only/` extension layer, and how/where rendered output lands for Claude and Copilot
- [x] README's install instructions still accurately reflect running `./install.sh`

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

## Resolution notes

Rewrote the root `README` (previously just the two-line clone/install instructions) to
document the rebuilt repo end-to-end:

- **Install**: kept `git submodule update --init --recursive` + `./install.sh` (verified
  `.gitmodules` still governs `vim/bundle/*`), plus a short explanation of the shared
  `install_link` behavior (idempotent, timestamped backups) and package-manager dependency
  detection, both from issues 001/002.
- **zsh**: documented the `zsh/zshrc` module loader's three-stage source order (`zsh/modules/`
  -> `zsh/prompt/` -> `local/zsh/`), how to add a module, and listed the current modules
  (pulled from each file's header comment). Documented all four prompt segments (worktree
  count, ahead/behind, python venv/pyenv, AWS profile) from `zsh/prompt/functions.zsh`.
- **local/**: documented all three pieces (`local/zsh/`, `local/gitconfig.local`,
  `local/skills/`) and that the whole directory is gitignored/single-machine by design, not
  a sync mechanism.
- **agents/**: documented the neutral `SKILL.md` format, `dotfiles-sync-agents`'s two render
  targets (`~/.claude/skills/` and `~/.copilot/skills/`, the latter per issue 019's
  resolution -- Copilot CLI, not VS Code), and the `agents/claude-only/` extension layer.

No code changes, README only. No automated tests to run per PRD Testing Decisions.
