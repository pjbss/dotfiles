## Parent PRD

`issues/prd.md`

## What to build

Define the canonical tool-neutral skill format and build the first working end of the sync pipeline: `agents/skills/<skill-name>/SKILL.md` (YAML frontmatter: `name`, `description`, optional `tags`; markdown body as instruction content, plus optional supporting files), a `bin/dotfiles-sync-agents` (zsh) command that scans `agents/skills/*/SKILL.md` and renders Claude output at or near full fidelity into `~/.claude/skills/`, and a minimal example skill `dotfiles-help` that proves the pipeline end-to-end. Per PRD Solution and Implementation Decisions ("Canonical skill format", "Rendering mechanism", "Tooling language", "Initial seed content").

This slice covers only the Claude side of rendering — Copilot rendering is `issues/019-copilot-skill-sync.md`, the claude-only extension layer is `issues/018-claude-only-extension-layer.md`, and scanning `local/skills/` is `issues/020-local-skills-sync.md`.

## Acceptance criteria

- [x] `agents/skills/<skill-name>/SKILL.md` format is defined and documented (frontmatter fields, body, optional supporting files)
- [x] `bin/dotfiles-sync-agents` is a zsh script that scans `agents/skills/*/SKILL.md`
- [x] Running `dotfiles-sync-agents` renders each skill into `~/.claude/skills/<skill-name>/` at or near full fidelity (frontmatter + body + supporting files preserved)
- [x] `agents/skills/dotfiles-help/SKILL.md` exists as a minimal example skill
- [x] Manually verified (sandboxed `$HOME`): running `dotfiles-sync-agents` renders `~/.claude/skills/dotfiles-help/` as a byte-identical copy of the source skill directory
- [x] Re-running `dotfiles-sync-agents` after no changes produces the same output (verified via checksum comparison before/after a second run, in the same sandbox)

## Blocked by

None - can start immediately

## User stories addressed

- User story 17
- User story 18
- User story 19
- User story 22
- User story 28

## Implementation notes (AFK pass)

- Format documented in `agents/README.md`; example skill at
  `agents/skills/dotfiles-help/SKILL.md`.
- `bin/dotfiles-sync-agents` does a `rm -rf` + `cp -R` per skill directory
  into `~/.claude/skills/<skill-name>/` — full-fidelity copy, deterministic
  and idempotent by construction (no timestamps/ordering involved).
- Added `PATH=$DOTFILES_HOME/bin:$PATH` to `zsh/zshrc` so
  `dotfiles-sync-agents` is callable as a bare command once `~/.zshrc` is
  linked to this repo (not yet the case until `issues/016-zshrc-cutover.md`
  lands — until then, invoke via `./bin/dotfiles-sync-agents` from the repo
  root, or add the repo's `bin/` to `PATH` manually).
- All verification was done against a sandboxed `$HOME` (per prior
  feedback: never run installer/sync scripts against the real home dir
  during automated testing), not the real `~/.claude/skills/`. One
  criterion remains outside what an unattended pass can confirm: actually
  opening Claude Code and confirming it picks up/invokes the
  `dotfiles-help` skill from the real `~/.claude/skills/` after running
  `dotfiles-sync-agents` for real. That's a quick manual check for the
  maintainer — run `bin/dotfiles-sync-agents` for real, then start a new
  Claude Code session and confirm the skill shows up.
- No automated tests added, per PRD Testing Decisions (deliberately out of
  scope for this whole effort).
