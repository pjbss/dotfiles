# agents/claude-only/

Claude-only extensions: content with no GitHub Copilot equivalent
(subagents, multi-step Workflow scripts). Kept separate from
`agents/skills/` (the tool-neutral core) so it's obvious at a glance what's
portable and what isn't.

`dotfiles-sync-agents` renders this directory into the Claude adapter's
output only. When the Copilot adapter (`issues/019-copilot-skill-sync.md`)
lands, it must skip `agents/claude-only/` entirely rather than attempt a
lossy translation.

## Layout

- `subagents/<name>.md` — a Claude Code subagent definition (YAML
  frontmatter + markdown system prompt), rendered at full fidelity into
  `~/.claude/agents/<name>.md`.
- `workflows/<name>.js` — a Claude Code Workflow script, rendered at full
  fidelity into `~/.claude/workflows/<name>.js`.

## Example

`subagents/dotfiles-example.md` is a minimal subagent that proves this half
of the render pipeline end-to-end.
