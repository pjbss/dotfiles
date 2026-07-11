## Problem Statement

My dotfiles repo (`pjbss/dotfiles`) is stale and hard to extend:

- My actual shell (`~/.zshrc`) isn't even wired to this repo anymore — it's a standalone oh-my-zsh-generated file, and the repo's own `zsh/` directory is dead code.
- I depend entirely on oh-my-zsh for day-to-day shell features (git aliases, macOS helpers, Python/AWS helpers, common aliases, fzf integration), which means I can't cleanly remove oh-my-zsh without losing functionality I use constantly.
- My prompt shows basic git branch/dirty state but nothing about git worktrees, ahead/behind status, active Python virtualenv, or active AWS profile — information I want at a glance while working.
- There's no place to put aliases, commands, or LLM agent skills that are specific to my employer (WhiskerLabs) without risking them leaking into this public GitHub repo.
- I use Claude Code and GitHub Copilot day to day, but I have no system for managing my personal skills/instructions across both in one place — anything I write today is tool-specific and not reusable.
- The installer itself is destructive and non-idempotent (e.g. it unconditionally `rm`s `~/.zshrc` with no backup), which makes it risky to touch or re-run as the repo grows.

## Solution

Rebuild the dotfiles repo so that:

- It fully replicates, feature-for-feature (based on actual usage), everything I currently rely on from my 6 active oh-my-zsh plugins (`git macos python common-aliases aws fzf`), via a hand-rolled zsh module loader — no oh-my-zsh, no third-party plugin manager.
- Once validated, I can delete `~/.oh-my-zsh` entirely with nothing lost.
- My prompt is extended (not replaced by a new framework) to show git worktree info, ahead/behind counts, active Python venv, and active AWS profile, alongside what it already shows.
- A gitignored `local/` directory inside the repo holds anything company-specific or private — aliases, gitconfig overrides, and even private LLM agent skills — and it's picked up automatically and seamlessly by the same mechanisms that load the public config, with zero risk of it being committed.
- A new agent-agnostic system manages my personal, global (not per-project) LLM configuration: skills are authored once in a tool-neutral format and rendered out to both Claude Code (`~/.claude`) and GitHub Copilot's config via a manual sync command. Claude-only concepts (subagents, Workflow scripts) live in a clearly separated extension layer that Copilot's adapter simply ignores.
- The installer is rewritten to be safe and idempotent (backs up real files before replacing them, no-ops when already correctly linked) and gains OS-detected dependency installation (Homebrew / apt / dnf) to support both macOS and Linux.
- The cutover is a direct swap (old `~/.zshrc` backed up, new one linked), validated by hand, with oh-my-zsh removed manually by me once I'm confident — no toggle/dual-mode complexity.

## User Stories

1. As the maintainer of this dotfiles repo, I want my `~/.zshrc` to actually be a symlink into this repo, so that changes I make here take effect instead of silently doing nothing.
2. As a zsh user without oh-my-zsh, I want a lightweight module loader that sources `zsh/modules/*.zsh` files, so that I retain the "drop a file in, it's active" ergonomics oh-my-zsh gave me.
3. As someone porting off oh-my-zsh, I want my shell history audited so only the git aliases I actually use get ported, so that I don't carry ~140 unused aliases into the new setup.
4. As someone porting off oh-my-zsh, I want the same usage-based audit applied to `common-aliases`, `python`, `aws`, and `macos` plugin features, so parity is meaningful rather than exhaustive.
5. As a macOS+Linux user, I want macOS-specific features (from the old `macos` plugin) to only load when running on Darwin, so the same repo works cleanly on a Linux box.
6. As an fzf user, I want fzf's key bindings and completion sourced directly (e.g. via `fzf --zsh`), so I keep fuzzy history/file search without oh-my-zsh's plugin wrapper.
7. As someone who relies on oh-my-zsh's aws plugin today, I want equivalent AWS CLI completion/profile-switching behavior ported into a dedicated module.
8. As someone who wants to fully decommission oh-my-zsh, I want to validate the new shell in real terminal sessions before deleting `~/.oh-my-zsh` myself, so the removal is a deliberate, low-risk step I control.
9. As someone reviewing my prompt at a glance, I want to see how many git worktrees exist for the current repo, so I know when I'm in a linked worktree situation.
10. As someone reviewing my prompt at a glance, I want to see how many commits I am ahead/behind my upstream branch, so I don't forget to push or pull.
11. As a Python developer, I want my active virtualenv or pyenv version shown in the prompt, so I always know which Python environment is active.
12. As an AWS CLI user, I want my active `$AWS_PROFILE` shown in the prompt, so I don't run commands against the wrong account by mistake.
13. As the author of the prompt logic, I want the new prompt-info logic added to the existing `zsh/prompt/functions.zsh` pattern rather than a new prompt framework, so I don't take on a new dependency (Starship/P10k) for this.
14. As someone with company-specific aliases and commands, I want a `local/` directory inside the repo that's gitignored, so I can keep WhiskerLabs-specific shell config colocated with my personal config without any risk of it being pushed to the public repo.
15. As someone with company-specific aliases, I want `local/zsh/*.zsh` sourced automatically alongside the public `zsh/modules/*.zsh`, so private config loads seamlessly with no extra step.
16. As someone with company-specific git needs, I want a `local/gitconfig.local` style override mechanism, so private git config can layer on top of the public `git/gitconfig.partial`.
17. As a Claude Code and GitHub Copilot user, I want to author my personal skills/instructions once in a neutral format, so I don't duplicate content across tools.
18. As the author of a neutral skill, I want each skill to be its own directory with a `SKILL.md` (frontmatter + body) plus optional supporting files, mirroring Claude Code's native on-disk shape.
19. As a Claude Code user, I want my neutral skills rendered with full fidelity into `~/.claude/skills/`, so nothing is lost for the tool I use most.
20. As a GitHub Copilot user, I want my neutral skills rendered into Copilot's instruction-file format on a best-effort basis, so I get equivalent behavior where Copilot's model supports it.
21. As a Claude Code user with subagent/Workflow needs, I want a clearly separated Claude-only extension layer (e.g. `agents/claude-only/`) for content with no Copilot equivalent, so the neutral core stays honest about what's actually portable.
22. As the maintainer, I want a manual `dotfiles-sync-agents` command that renders neutral skills to both tools, so regeneration is explicit and I always know when generated output changes.
23. As someone with company-specific LLM needs, I want `local/skills/` scanned by `dotfiles-sync-agents` alongside `agents/skills/`, so private/company skills get the same agent-agnostic rendering treatment without ever being committed.
24. As the maintainer, I want `install.sh` to back up any real file before replacing it with a symlink, so re-running the installer is never destructive.
25. As the maintainer, I want `install.sh` to no-op when a symlink already points to the correct target, so repeated runs are boring and safe.
26. As a cross-platform user, I want `install.sh` to detect Homebrew/apt/dnf and install required tools (e.g. `fzf`) using the right package manager for the current OS.
27. As the maintainer, I want the existing per-directory `install.sh` convention (`git/`, `zsh/`, `vim/`, `agents/`, `local/`) preserved rather than replaced with a new framework like GNU Stow or dotbot.
28. As the maintainer, I want a minimal example skill (`dotfiles-help`) included, so the full neutral-format → Claude + Copilot rendering pipeline is proven end-to-end before I author real content.
29. As the maintainer, I want the README updated to reflect the new structure (module loader, prompt additions, `local/` convention, agent sync command), so the repo documents itself.
30. As the maintainer, I want vim config and the existing git aliases left alone except for the general installer-robustness rewrite, so this effort stays scoped to what I actually asked for.

## Implementation Decisions

- **Platform scope**: macOS + Linux. OS-specific behavior (e.g. the ported `macos` plugin module) is guarded by runtime OS detection rather than maintaining separate branches of the repo.
- **Zsh module loading**: hand-rolled loader, no plugin manager (zinit/antidote rejected). `zsh/zshrc` builds `fpath` and sources `zsh/modules/*.zsh`, then `local/zsh/*.zsh` if present, then runs `compinit`.
- **Feature porting methodology**: audit actual shell history usage per plugin (git, common-aliases, python, aws) rather than porting every alias for 1:1 parity. macOS and fzf modules ported based on their actual (non-alias) behavior — OS-specific helpers and `fzf --zsh` integration respectively.
- **No new shell plugins added**: zsh-autosuggestions/zsh-syntax-highlighting explicitly out of scope for this effort (strict parity, not feature expansion).
- **Prompt**: extends the existing `zsh/prompt/functions.zsh` / `zsh/prompt/settings.zsh` pattern — no Starship or Powerlevel10k. New functions: git worktree count/info, git ahead/behind-remote count, active Python venv/pyenv version, active `$AWS_PROFILE`. These compose into the existing `PROMPT`/`RPROMPT` alongside current branch/dirty/host/path/exit-code/time segments.
- **Installer**: rewritten around a shared `install_link(src, dst)` helper — idempotent (no-op if `dst` is already a symlink pointing at `src`), safe (backs up any pre-existing real file at `dst` with a timestamped suffix before linking). Existing per-directory `install.sh` convention (`git/`, `zsh/`, `vim/`, plus new `agents/`, `local/`) is preserved; no adoption of GNU Stow or dotbot.
- **Dependency installation**: `install.sh` detects the available package manager (Homebrew, then apt, then dnf) and installs required external tools (e.g. `fzf`) using OS-appropriate package names, rather than relying solely on a Homebrew-only Brewfile or documentation-only instructions.
- **Cutover sequencing**: direct swap — installer backs up the current `~/.zshrc` and symlinks the new one. No dual-mode/toggle mechanism. Removal of `~/.oh-my-zsh` itself is a manual, user-driven step after validation, not automated by any script in this repo.
- **Private/company config**: a gitignored `local/` directory at the repo root. Structure mirrors the public repo's shape: `local/zsh/*.zsh` (aliases/functions, sourced automatically), `local/gitconfig.local` (git overrides), and `local/skills/*/` (private agent skills, same shape as `agents/skills/*/`). Nothing here is synced to another machine by this repo — it is single-machine/local by design, scoped to prevent it from ever reaching the public repo, not to sync it elsewhere.
- **Agent-agnostic LLM management scope**: global/user-level configuration only (e.g. `~/.claude`), not per-project `.claude/`/`.github/` scaffolding for other repos.
- **Target tools at launch**: Claude Code and GitHub Copilot.
- **Canonical skill format**: tool-neutral schema — one directory per skill under `agents/skills/<skill-name>/`, containing `SKILL.md` (YAML frontmatter: `name`, `description`, optional `tags`; markdown body as the instruction content) plus optional supporting files. This mirrors Claude Code's native on-disk skill shape.
- **Claude-only extension layer**: content with no Copilot equivalent (subagents, multi-step Workflow scripts) lives under a separate, clearly labeled path (e.g. `agents/claude-only/`) and is rendered only into the Claude adapter's output; the Copilot adapter skips it entirely rather than attempting a lossy translation.
- **Rendering mechanism**: a manual command, `bin/dotfiles-sync-agents` (zsh), scans `agents/skills/*/SKILL.md` and `local/skills/*/SKILL.md`, and renders: (a) Claude output into `~/.claude/skills/` at or near full fidelity, and (b) Copilot output into Copilot's instruction-file format on a best-effort basis (body content extracted/adapted; frontmatter fields with no Copilot equivalent dropped). No auto-run hook (no zsh-startup check, no git hook) — sync is always an explicit, user-initiated step.
- **Tooling language**: the render script and other new tooling logic are written in zsh/POSIX shell, consistent with the rest of the repo — no Python or Node.js dependency introduced.
- **Initial seed content**: exactly one minimal example skill, `dotfiles-help`, whose purpose is to prove the neutral-format → Claude + Copilot rendering pipeline works end-to-end. No other skill content is authored as part of this PRD.
- **Copilot's actual current mechanism for personal/global custom instructions** is not yet finalized in this PRD — it needs to be verified against Copilot's current supported feature set at implementation time (see Further Notes).

## Testing Decisions

- No automated tests are being added as part of this effort — not for the prompt-info functions, not for the `install_link` installer core, and not for the `dotfiles-sync-agents` render pipeline.
- This was a deliberate, explicit decision (confirmed at both the general and per-module level) to keep the effort scoped to a personal dotfiles repo, where the maintenance burden of a test framework (e.g. bats-core) was judged not to be worth it.
- All verification for this effort is manual: opening new shell sessions to confirm behavior, and running `dotfiles-sync-agents` by hand to confirm rendered output looks correct in `~/.claude/skills/` and Copilot's instruction-file location.
- If automated testing is revisited in the future, the strongest candidates (in priority order) would be: `install_link` (simple, high-consequence, easy to test against a scratch directory), the prompt-info functions (real edge cases: detached HEAD, no upstream, multiple worktrees), and the `dotfiles-sync-agents` renderer (most complex new logic, testable via fixture skill directories without touching real `~/.claude`).

## Out of Scope

- Any zsh plugin manager (zinit, antidote, etc.) — explicitly rejected in favor of a hand-rolled loader.
- Any new prompt framework (Starship, Powerlevel10k, Pure) — explicitly rejected in favor of extending the existing custom prompt code.
- Any new "nice to have" shell plugins beyond current parity (zsh-autosuggestions, zsh-syntax-highlighting) — explicitly deferred.
- Per-project agent config scaffolding/templating (stamping `.claude/`/`.github/` into other repos) — this PRD covers global/user-level config only.
- Any LLM tool beyond Claude Code and GitHub Copilot (Cursor, Windsurf, Continue, etc.) — may be added later as additional adapters if the neutral-core approach holds up, but not part of this effort.
- GNU Stow, dotbot, or any other third-party dotfiles/symlink-management framework.
- Automated testing infrastructure of any kind (bats-core, shunit2, CI).
- Automatic/triggered rendering of agent skills (zsh-startup hook, git hook) — sync is manual only.
- Changes to `vim/` configuration.
- Changes to the existing `git/gitconfig.partial` alias set, beyond the general installer-robustness rewrite that applies to all per-directory `install.sh` scripts.
- Automating the actual removal of `~/.oh-my-zsh` — that remains a manual step taken by the user after validation.
- Syncing the private `local/` directory across machines (e.g. via a private git repo) — it is single-machine and gitignored only, by explicit choice.

## Further Notes

- GitHub Copilot's exact current mechanism for personal/global custom instructions (vs. repository-level `.github/copilot-instructions.md`) needs to be verified at implementation time — the product surface here has been in flux and the right target (VS Code user settings field vs. a dropped-in file) should be confirmed against Copilot's current docs/behavior before the Copilot adapter is finalized, rather than assumed from prior knowledge.
- The repo currently has `git/install.sh` logic that has apparently never been run on this machine (no `~/.gitconfig.dotfiles.backup` exists, and none of its aliases appear in the live `~/.gitconfig`). The installer-robustness rewrite will make it safe to run, but whether/when to actually run it is a separate decision from this PRD.
- The live `~/.zshrc` today is not connected to this repo at all (it's a standalone oh-my-zsh-generated file); the direct-swap cutover step is what establishes that connection for the first time in practice, not merely "reconnects" an existing link.
