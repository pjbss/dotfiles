## Parent PRD

`issues/prd.md`

## What to build

Extend `dotfiles-sync-agents` (from `issues/017-neutral-skill-format-and-claude-sync.md`) to also render neutral skills into GitHub Copilot's instruction-file format on a best-effort basis (body content extracted/adapted; frontmatter fields with no Copilot equivalent dropped), proven against the `dotfiles-help` example skill. Per PRD Solution and Implementation Decisions ("Rendering mechanism") and Further Notes.

This requires a human research/decision step first: **Copilot's exact current mechanism for personal/global custom instructions is not yet finalized** (per PRD Further Notes — the product surface here has been in flux; needs verification against Copilot's current docs/behavior to confirm the right target, e.g. a VS Code user-settings field vs. a dropped-in file, rather than assuming from prior knowledge). That's why this slice is HITL rather than AFK.

## Acceptance criteria

- [x] Human decision made and documented: what is Copilot's actual current mechanism for personal/global custom instructions, and where does `dotfiles-sync-agents` need to write output for Copilot to pick it up
- [x] `dotfiles-sync-agents` renders each `agents/skills/*/SKILL.md` into that confirmed Copilot format/location on a best-effort basis
- [x] Frontmatter fields with no Copilot equivalent are dropped cleanly (no errors, no garbage output)
- [x] Manually verified (sandboxed `$HOME`): running `dotfiles-sync-agents` produces Copilot-readable output for the `dotfiles-help` example skill

## Blocked by

- Blocked by `issues/017-neutral-skill-format-and-claude-sync.md`

## User stories addressed

- User story 20

## Resolution notes

**Human decision (research + explicit maintainer call):** target GitHub Copilot **CLI**
(`github/copilot-cli`), not VS Code's Copilot Chat extension.

Research found that VS Code's own mechanism for personal/global Copilot instructions is
currently unsettled: its docs cite `~/.copilot/instructions`, but multiple open, unresolved
GitHub issues (microsoft/vscode-copilot-release#12853, microsoft/vscode#305642) confirm that
path doesn't actually work — the only thing that does is dropping `*.instructions.md` files
into the VS Code user profile's `prompts` folder (e.g. `~/Library/Application Support/Code/
User/prompts/` on macOS), an undocumented, profile-specific, non-Settings-Sync'd location
that could change without notice. Given that instability, the maintainer chose Copilot CLI
instead of VS Code as the target.

Copilot CLI's mechanism, by contrast, is officially documented and stable:
- Personal skills live at `~/.copilot/skills/<skill-name>/SKILL.md` (or `$COPILOT_HOME/skills`
  if `COPILOT_HOME` is set) — see docs.github.com/en/copilot/how-tos/copilot-cli/
  customize-copilot/add-skills.
- Required frontmatter: `name`, `description` — both map directly from the neutral format.
  Optional: `license`, `allowed-tools` (no neutral-format equivalent, so never emitted).
  The neutral format's `tags` field has no Copilot equivalent, so it's dropped.
- Supporting files alongside `SKILL.md` are auto-discovered by Copilot CLI, same as the
  neutral format, so they're copied as-is.

This makes the format nearly identical to Claude's (`name`/`description`/body carry over
unchanged; only `tags` is stripped), so `dotfiles-sync-agents` renders both adapters from the
same scan loop:
- Added `sync_copilot_skill()` to `bin/dotfiles-sync-agents`: full-directory copy identical to
  `sync_claude_skill()`, then `grep -v '^tags:'` rewrites just `SKILL.md` to drop the
  unsupported field.
- Renamed the shared scan loop `sync_claude_skills_dir` -> `sync_skills_dir`; it now calls both
  `sync_claude_skill` and `sync_copilot_skill` per skill directory, for both `agents/skills/`
  and `local/skills/`.
- `agents/claude-only/` is untouched by this change — the Copilot loop never scans that
  directory, so it's skipped by construction, not by an explicit exclusion check.
- Docs updated: `agents/README.md`, `agents/claude-only/README.md`, and the `dotfiles-help`
  example skill's own body all now describe the Copilot CLI target.

**Verified in a sandboxed `$HOME`** (never the real one, per standing feedback): ran
`dotfiles-sync-agents`, confirmed `~/.copilot/skills/dotfiles-help/SKILL.md` renders with
`name`/`description`/body intact and `tags:` removed, confirmed a second run is
checksum-identical (idempotent), confirmed `COPILOT_HOME` override redirects the Copilot
output correctly, and confirmed a `local/skills/` test skill renders through both adapters
identically (test fixture removed afterward, `git status` on `local/` clean).

**Not yet verified:** opening a real Copilot CLI session and confirming it actually picks up
`~/.copilot/skills/dotfiles-help/` after running `dotfiles-sync-agents` for real — that's a
quick manual check for the maintainer, same caveat as issues 017/018/020's Claude-side
verification.
