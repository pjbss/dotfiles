## Parent PRD

`issues/prd.md`

## What to build

Extend `dotfiles-sync-agents` (from `issues/017-neutral-skill-format-and-claude-sync.md`) to also scan `local/skills/*/SKILL.md` — same neutral format and directory shape as `agents/skills/*/`, but gitignored under the repo-root `local/` convention (`issues/014-local-zsh-directory.md` establishes the `local/` gitignore) — so private/company skills get the same rendering treatment (Claude, and Copilot once `issues/019-copilot-skill-sync.md` lands) without ever being committed. Per PRD Solution and Implementation Decisions ("Private/company config").

## Acceptance criteria

- [x] `dotfiles-sync-agents` scans `local/skills/*/SKILL.md` in addition to `agents/skills/*/SKILL.md`
- [x] Skills found under `local/skills/` are rendered identically to public skills (Claude output at minimum; Copilot output if that slice has landed)
- [x] Manually verified: adding a test skill under `local/skills/test-skill/SKILL.md` and running `dotfiles-sync-agents` produces rendered output in `~/.claude/skills/test-skill/`
- [x] Manually verified: `git status` shows nothing under `local/skills/` (confirming it's covered by the existing `local/` gitignore entry)

## Blocked by

- Blocked by `issues/017-neutral-skill-format-and-claude-sync.md`

## User stories addressed

- User story 23

## Implementation notes (AFK pass)

- `bin/dotfiles-sync-agents`: extracted the existing per-skill-dir scan loop
  into a `sync_claude_skills_dir()` helper, then called it a second time
  against a new `LOCAL_SKILLS_SRC_DIR="$DOTFILES_HOME/local/skills"`. Both
  `agents/skills/` and `local/skills/` render through the same
  `sync_claude_skill()` full-fidelity copy, so behavior is identical.
- `local/skills/` is scanned *after* `agents/skills/`, so a local skill
  sharing a name with a public one wins (overwrites it in
  `~/.claude/skills/`). Not a required acceptance criterion, just the
  natural consequence of scan order -- documented in the script header and
  `agents/README.md`.
- `agents/README.md` updated to describe the `local/skills/` scan path and
  the name-collision precedence, replacing the stale note that said this
  wasn't supported yet.
- No Copilot-side rendering exists yet (blocked on `issues/019-copilot-skill-sync.md`,
  which is HITL), so "Copilot output if that slice has landed" is not
  applicable this round.
- Verified in a sandboxed `$HOME` (never the real one, per standing
  feedback): created `local/skills/test-skill/SKILL.md`, ran
  `dotfiles-sync-agents`, confirmed byte-identical output at
  `~/.claude/skills/test-skill/` via `diff -r`, confirmed the existing
  `agents/skills/dotfiles-help` public skill still renders correctly
  alongside it, and confirmed `git status --porcelain` shows nothing under
  `local/skills/` (covered by the repo-root `/local/` gitignore entry from
  issue 014). Test fixtures removed after verification.
- Not yet verified: opening real Claude Code and confirming it picks up a
  real private skill placed under `local/skills/` after running
  `dotfiles-sync-agents` for real -- same manual-check caveat as issues
  017/018.
