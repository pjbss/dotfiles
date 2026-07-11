## Parent PRD

`issues/prd.md`

## What to build

Audit actual usage of the oh-my-zsh `aws` plugin (completion, profile-switching helpers) and port the equivalent behavior into a new `zsh/modules/aws.zsh` module (loaded automatically by the loader from `issues/003-zsh-module-loader.md`). Per PRD Solution and Implementation Decisions ("Feature porting methodology"): parity should be meaningful (what's actually used) rather than exhaustive.

Note: the prompt-facing part of AWS support (showing the active `$AWS_PROFILE` in the prompt) is a separate slice — `issues/013-prompt-aws-profile.md`. This slice is scoped to the plugin's shell aliases/functions/completion only.

## Acceptance criteria

- [x] Actual usage of the `aws` plugin's completion and profile-switching features has been reviewed
- [x] `zsh/modules/aws.zsh` contains equivalent AWS CLI completion/profile-switching behavior, sourced automatically by the module loader
- [x] Ported behavior is manually confirmed to work equivalently to the oh-my-zsh `aws` plugin (e.g. completing AWS CLI subcommands, switching profiles)
- [x] Unused features from the plugin are explicitly left out

## Resolution notes

Audited `~/.zsh_history` (7,757 commands) against the plugin's profile-switching
helpers (`asp`, `acp`, `asr`, `agp`, `agr`, `aws_change_access_key`) — none were
used. This user sets `$AWS_PROFILE` inline per-command (e.g. `AWS_PROFILE=wl-dev
aws sso login`, used 176+ times across 6 profiles) rather than the plugin's
profile-switching shortcuts, so those were left out per the usage-based porting
methodology.

AWS CLI completion (a non-alias behavior, used every time `aws` is
tab-completed) was ported: aws-cli v2's own `aws_completer` binary is wired up
via zsh's `bashcompinit` shim, matching the plugin's own preferred code path
for aws-cli v2 users. The plugin's aws-cli v1 completion fallback chain
(Homebrew/Ubuntu/NixOS/RPM `aws_zsh_completer.sh` lookup) was left out since
this user is on aws-cli v2.

Porting the completion call surfaced an ordering bug: the module loader
(`zsh/zshrc`) ran `compinit` *after* sourcing `zsh/modules/*.zsh`, so
`aws.zsh`'s `complete -C aws_completer aws` call failed at shell startup with
`command not found: compdef` (bashcompinit's `complete` depends on `compdef`,
which `compinit` defines). Fixed by moving the `compinit` call to run
immediately after `fpath` is built and before the modules loop — verified this
doesn't regress anything else, since fpath is already fully assembled by that
point and no other module currently depends on completion.

Manually verified: sourcing `zsh/zshrc` in a fresh interactive zsh produces no
new errors, `_comps[aws]` is populated, and invoking `aws_completer` directly
(simulating `aws s3<TAB>`) returns real subcommand completions (`s3`,
`s3control`, `s3api`, ...).

## Blocked by

- Blocked by `issues/003-zsh-module-loader.md`

## User stories addressed

- User story 4
- User story 7
