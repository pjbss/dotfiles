## Parent PRD

`issues/prd.md`

## What to build

Extend `dotfiles-sync-agents` (from `issues/017-neutral-skill-format-and-claude-sync.md`) to also render neutral skills into GitHub Copilot's instruction-file format on a best-effort basis (body content extracted/adapted; frontmatter fields with no Copilot equivalent dropped), proven against the `dotfiles-help` example skill. Per PRD Solution and Implementation Decisions ("Rendering mechanism") and Further Notes.

This requires a human research/decision step first: **Copilot's exact current mechanism for personal/global custom instructions is not yet finalized** (per PRD Further Notes — the product surface here has been in flux; needs verification against Copilot's current docs/behavior to confirm the right target, e.g. a VS Code user-settings field vs. a dropped-in file, rather than assuming from prior knowledge). That's why this slice is HITL rather than AFK.

## Acceptance criteria

- [ ] Human decision made and documented: what is Copilot's actual current mechanism for personal/global custom instructions, and where does `dotfiles-sync-agents` need to write output for Copilot to pick it up
- [ ] `dotfiles-sync-agents` renders each `agents/skills/*/SKILL.md` into that confirmed Copilot format/location on a best-effort basis
- [ ] Frontmatter fields with no Copilot equivalent are dropped cleanly (no errors, no garbage output)
- [ ] Manually verified: running `dotfiles-sync-agents` produces Copilot-readable output for the `dotfiles-help` example skill, and Copilot in VS Code demonstrably picks it up

## Blocked by

- Blocked by `issues/017-neutral-skill-format-and-claude-sync.md`

## User stories addressed

- User story 20
