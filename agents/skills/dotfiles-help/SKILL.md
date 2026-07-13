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
- `bin/dotfiles-sync-agents` — manual command that renders
  `agents/skills/*/SKILL.md` into `~/.claude/skills/` (Claude Code) and
  `~/.copilot/skills/` (GitHub Copilot CLI). Re-run it any time a skill
  changes.

## Adding a new skill

1. Create `agents/skills/<skill-name>/SKILL.md` with `name` and
   `description` frontmatter and a markdown body.
2. Run `dotfiles-sync-agents` to render it into `~/.claude/skills/` and
   `~/.copilot/skills/`.
3. Start a new Claude Code or Copilot CLI session (or otherwise reload
   skills) to pick it up.

## Adding a new shell module

Drop a `.zsh` file in `zsh/modules/`. It's sourced automatically the next
time a shell starts — no changes to `zsh/zshrc` required.
