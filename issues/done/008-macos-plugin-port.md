## Parent PRD

`issues/prd.md`

## What to build

Audit actual (non-alias) usage of the oh-my-zsh `macos` plugin's helper functions and port the used subset into a new `zsh/modules/macos.zsh` module, guarded so it only loads on Darwin (per PRD Implementation Decisions: "macOS and fzf modules ported based on their actual (non-alish) behavior — OS-specific helpers..."; and User story 5: macOS-specific features only load when running on Darwin, so the same repo works cleanly on a Linux box). Loaded automatically by the loader from `issues/003-zsh-module-loader.md`, but no-ops (or isn't sourced at all) on non-Darwin systems.

## Acceptance criteria

- [ ] Actual usage of the `macos` plugin's helper functions has been reviewed
- [ ] `zsh/modules/macos.zsh` contains only the used subset of helpers, manually confirmed equivalent to the oh-my-zsh `macos` plugin
- [ ] The module is guarded by a runtime OS check so it is a no-op (or unsourced) when `$OSTYPE`/`uname` indicates non-Darwin
- [ ] Manually verified: sourcing the module on macOS activates the helpers; simulating a non-Darwin `$OSTYPE` (or testing in a Linux container) confirms the module is skipped without error

## Blocked by

- Blocked by `issues/003-zsh-module-loader.md`

## User stories addressed

- User story 4
- User story 5
