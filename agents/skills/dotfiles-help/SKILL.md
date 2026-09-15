---
name: dotfiles-help
description: Explains what this dotfiles repo is, how it's laid out (zsh modules, prompt, local/ overrides, agent skill sync), and how to add to it. Use when asked about this dotfiles repo's structure or conventions.
tags: [dotfiles, meta]
---

# Dotfiles Help

This repo (`pjbss/dotfiles`) is a personal dotfiles setup with a hand-rolled
zsh module loader (no oh-my-zsh, no plugin manager) and an agent-agnostic
system for syncing LLM skills to Claude Code and GitHub Copilot.

## Layout

- `zsh/modules/*.zsh` — public shell modules, sourced automatically by
  `zsh/zshrc`. Drop a new `.zsh` file in here and it's active on the next
  shell start, no extra wiring needed.
- `zsh/prompt/` — prompt segment functions (`functions.zsh`) and the
  `PROMPT`/`RPROMPT` assembly (`settings.zsh`).
- `local/zsh/*.zsh` — gitignored, machine/company-specific shell config,
  sourced after the public modules.
- `local/gitconfig.local` — gitignored git config overrides layered on top
  of `git/gitconfig.partial`.
- `agents/skills/<skill-name>/SKILL.md` — tool-neutral LLM skills (YAML
  frontmatter: `name`, `description`, optional `tags`; markdown body as the
  instruction content; optional supporting files alongside `SKILL.md`).
- `local/skills/<skill-name>/SKILL.md` — same shape, for private/company
  skills that should never be committed.
- `agents/claude-only/` — content with no Copilot equivalent, rendered into
  Claude Code's output only: `subagents/<name>.md` → `~/.claude/agents/`, and
  `workflows/<name>.js` → `~/.claude/workflows/`.
- `bin/dotfiles-sync-agents` — the render engine. It scans `agents/skills/`
  and then `local/skills/` (scanned second, so a private skill of the same
  name wins) into `~/.claude/skills/` and `~/.copilot/skills/` — the Copilot
  copy drops the `tags:` line, which that format has no field for — and
  renders `agents/claude-only/` into Claude's output. It runs automatically at
  the end of `install.sh`, including inside a spawned sandbox VM; re-run it by
  hand (or `make sync`) any time a skill changes without a full install.
- `Makefile` — `make test` runs every `*_test.sh`, `make lint` syntax-checks
  every shell source. `make test` is what the agent hooks and the autonomous
  issue loop call, so it's the contract any project this tooling drives needs.
- `bin/pj-*` — the sandbox commands (`pj-sbx-spawn`, `pj-sbx-list`,
  `pj-sbx-teardown`, `pj-sbx-ssh`, `pj-sbx-verify`), the issue-tree query tool
  (`pj-issues`), and the autonomous loop (`pj-run-issues`, dispatched into a
  sandbox by `pj-sbx-run`). `pj-help` indexes them all from their own header
  comments, so a new `bin/pj-*` script with a doc comment appears there with no
  wiring.
- `agents/claude-only/hooks/` + `agents/claude-only/settings.json` — Claude Code
  hooks, rendered to `~/.claude/hooks/` with the `hooks` key merged into
  `~/.claude/settings.json`. They inject repo context at session start, block
  writes that reach outside the sandbox, syntax-check edited shell files, and
  (when `PJ_STOP_TESTS=1`) refuse to let a session finish with a red suite.

## Adding a new skill

1. Create `agents/skills/<skill-name>/SKILL.md` with `name` and
   `description` frontmatter and a markdown body.
2. Run `dotfiles-sync-agents` (or `make sync`) to render it into
   `~/.claude/skills/` and `~/.copilot/skills/`. A full `./install.sh` does
   this too, as its last step.
3. Start a new Claude Code or Copilot CLI session (or otherwise reload
   skills) to pick it up.

## Adding a new shell module

Drop a `.zsh` file in `zsh/modules/`. It's sourced automatically the next
time a shell starts — no changes to `zsh/zshrc` required.

## Adding a new test

Drop a `*_test.sh` file in `sandbox/test/`, `zsh/modules/test/`, or
`agents/test/`. `test/run.sh` discovers it — nothing to register. Source
`test/assert.sh` for `assert_eq`/`assert_contains`/`assert_ok` and end the
file with `assert_report`, whose exit status is the file's exit status.
