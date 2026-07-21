# agents/

Tool-neutral LLM agent skills, authored once and rendered out to each
supported tool by `bin/dotfiles-sync-agents`.

## Skill format

Each skill is a directory under `agents/skills/<skill-name>/` containing:

- `SKILL.md` (required) — YAML frontmatter followed by a markdown body:
  - `name` (required) — the skill's identifier.
  - `description` (required) — when/why to use this skill.
  - `tags` (optional) — a list of free-form tags.
  - The markdown body is the instruction content shown to the model.
- Any other files in the directory (optional) — supporting material
  (scripts, references, etc.) referenced from `SKILL.md`.

This mirrors Claude Code's native on-disk skill shape, so the Claude
adapter renders it at full fidelity with a straight copy. It's also nearly
identical to GitHub Copilot CLI's personal-skill format (`name` and
`description` map directly), except Copilot has no `tags` equivalent.

## Rendering

`install.sh` runs `dotfiles-sync-agents` automatically at the end of an
install/update, so every skill is rendered into each supported tool's format
without an extra step. It's also on `PATH` (via `zsh/zshrc`) to re-run by
hand any time a skill is added or changed between installs.

- **Claude Code**: `~/.claude/skills/<skill-name>/`, full-fidelity copy
  (frontmatter, body, and any supporting files unchanged).
- **GitHub Copilot CLI**: `~/.copilot/skills/<skill-name>/` (or
  `$COPILOT_HOME/skills` if `COPILOT_HOME` is set), per Copilot CLI's
  documented personal-skills format. Supporting files are copied as-is;
  the `tags` frontmatter line is dropped from `SKILL.md` since Copilot has
  no equivalent field. This targets the Copilot CLI specifically, not
  VS Code's Copilot Chat extension -- VS Code's personal-instructions
  mechanism is currently undocumented/inconsistent in practice (see
  `issues/done/019-copilot-skill-sync.md` resolution notes) and out of
  scope.

Skills under a gitignored `local/skills/<skill-name>/SKILL.md` (private/
company skills, same format as above, per the repo-root `local/`
convention -- see `.gitignore`) are scanned and rendered the same way, into
both destinations above. A `local/skills/` skill with the same name as an
`agents/skills/` one wins, since it's scanned second.

## Claude-only extension layer

`agents/claude-only/` holds content with no Copilot equivalent (subagents,
Workflow scripts). It's rendered into Claude's output only -- see
`agents/claude-only/README.md` for its layout. The neutral `agents/skills/`
core above is unaffected by its presence, and any future Copilot adapter
must skip it entirely rather than attempt a lossy translation.

## Example

`agents/skills/dotfiles-help/` is a minimal skill that proves the
render pipeline end-to-end and explains this repo's structure.
`agents/claude-only/subagents/dotfiles-example.md` does the same for the
Claude-only layer.
