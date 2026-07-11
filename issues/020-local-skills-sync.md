## Parent PRD

`issues/prd.md`

## What to build

Extend `dotfiles-sync-agents` (from `issues/017-neutral-skill-format-and-claude-sync.md`) to also scan `local/skills/*/SKILL.md` — same neutral format and directory shape as `agents/skills/*/`, but gitignored under the repo-root `local/` convention (`issues/014-local-zsh-directory.md` establishes the `local/` gitignore) — so private/company skills get the same rendering treatment (Claude, and Copilot once `issues/019-copilot-skill-sync.md` lands) without ever being committed. Per PRD Solution and Implementation Decisions ("Private/company config").

## Acceptance criteria

- [ ] `dotfiles-sync-agents` scans `local/skills/*/SKILL.md` in addition to `agents/skills/*/SKILL.md`
- [ ] Skills found under `local/skills/` are rendered identically to public skills (Claude output at minimum; Copilot output if that slice has landed)
- [ ] Manually verified: adding a test skill under `local/skills/test-skill/SKILL.md` and running `dotfiles-sync-agents` produces rendered output in `~/.claude/skills/test-skill/`
- [ ] Manually verified: `git status` shows nothing under `local/skills/` (confirming it's covered by the existing `local/` gitignore entry)

## Blocked by

- Blocked by `issues/017-neutral-skill-format-and-claude-sync.md`

## User stories addressed

- User story 23
