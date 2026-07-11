## Parent PRD

`issues/prd.md`

## What to build

Audit actual usage of the oh-my-zsh `aws` plugin (completion, profile-switching helpers) and port the equivalent behavior into a new `zsh/modules/aws.zsh` module (loaded automatically by the loader from `issues/003-zsh-module-loader.md`). Per PRD Solution and Implementation Decisions ("Feature porting methodology"): parity should be meaningful (what's actually used) rather than exhaustive.

Note: the prompt-facing part of AWS support (showing the active `$AWS_PROFILE` in the prompt) is a separate slice — `issues/013-prompt-aws-profile.md`. This slice is scoped to the plugin's shell aliases/functions/completion only.

## Acceptance criteria

- [ ] Actual usage of the `aws` plugin's completion and profile-switching features has been reviewed
- [ ] `zsh/modules/aws.zsh` contains equivalent AWS CLI completion/profile-switching behavior, sourced automatically by the module loader
- [ ] Ported behavior is manually confirmed to work equivalently to the oh-my-zsh `aws` plugin (e.g. completing AWS CLI subcommands, switching profiles)
- [ ] Unused features from the plugin are explicitly left out

## Blocked by

- Blocked by `issues/003-zsh-module-loader.md`

## User stories addressed

- User story 4
- User story 7
