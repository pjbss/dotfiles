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
adapter renders it at full fidelity with a straight copy.

## Rendering

Run `dotfiles-sync-agents` (added to `PATH` by `zsh/zshrc`) to render every
skill under `agents/skills/*/SKILL.md` into `~/.claude/skills/`. This is
always a manual, explicit step -- nothing in this repo triggers it
automatically. Re-run it any time a skill is added or changed.

Skills under a gitignored `local/skills/` (private/company skills) and
rendering into GitHub Copilot's format are not yet supported by this
script -- see `issues/020-local-skills-sync.md` and
`issues/019-copilot-skill-sync.md`.

## Example

`agents/skills/dotfiles-help/` is a minimal skill that proves the
render pipeline end-to-end and explains this repo's structure.
