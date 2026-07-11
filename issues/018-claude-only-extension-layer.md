## Parent PRD

`issues/prd.md`

## What to build

Add a clearly separated Claude-only extension layer (e.g. `agents/claude-only/`) for content with no Copilot equivalent — subagents, multi-step Workflow scripts. `dotfiles-sync-agents` (from `issues/017-neutral-skill-format-and-claude-sync.md`) renders this content into the Claude adapter's output only; the Copilot adapter must skip it entirely rather than attempt a lossy translation. Per PRD Implementation Decisions ("Claude-only extension layer").

## Acceptance criteria

- [ ] `agents/claude-only/` exists as a documented, clearly-labeled directory distinct from `agents/skills/`
- [ ] `dotfiles-sync-agents` renders content under `agents/claude-only/` into the appropriate location under `~/.claude/` (e.g. subagent/workflow definitions)
- [ ] Manually verified: content placed under `agents/claude-only/` shows up in Claude Code after sync, and is confirmed absent/ignored when the Copilot render path (once built in `issues/019-copilot-skill-sync.md`) runs
- [ ] The neutral `agents/skills/` core is unaffected by the presence of `agents/claude-only/` content

## Blocked by

- Blocked by `issues/017-neutral-skill-format-and-claude-sync.md`

## User stories addressed

- User story 21
