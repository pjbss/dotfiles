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

## Implementation notes (AFK pass)

- `agents/claude-only/{subagents,workflows}/` created, documented in
  `agents/claude-only/README.md`, cross-linked from `agents/README.md`.
- `bin/dotfiles-sync-agents` renders `subagents/*.md` ->
  `~/.claude/agents/<name>.md` and `workflows/*.js` ->
  `~/.claude/workflows/<name>.js`, full-fidelity copy, using zsh's `(N)`
  glob qualifier so an empty/missing source dir no-ops silently.
- Added `agents/claude-only/subagents/dotfiles-example.md` as the minimal
  proof-of-pipeline example (mirrors `dotfiles-help` for skills).
- Verified in a sandboxed `$HOME` (never the real one, per standing
  feedback): file renders byte-identical, empty `workflows/` no-ops
  cleanly, and a second run is checksum-identical (idempotent).
- Not yet verified: opening real Claude Code and confirming it picks up
  `~/.claude/agents/dotfiles-example.md` as an invokable subagent -- that's
  a quick manual check for the maintainer, same caveat as issue 017's
  skill-side verification.
- The "Copilot adapter skips agents/claude-only/ entirely" criterion is
  currently true only because issue 019 hasn't been built yet -- when it
  is, its scan must explicitly exclude this directory rather than just
  happening not to visit it.
