#!/bin/sh
# sandbox.zsh
#
# Short aliases/functions wrapping the sandbox lifecycle commands
# (bin/dotfiles-sandbox-*, issues 003/006/007) so a sandbox can be spawned,
# listed, connected to, and torn down without typing the full
# `dotfiles-sandbox-*` command names.

alias sbx-spawn='dotfiles-sandbox-spawn'
alias sbx-list='dotfiles-sandbox-list'
alias sbx-teardown='dotfiles-sandbox-teardown'

# sbx-ssh <task-name>
#
# Connects into a running sandbox from a terminal. There's no
# `dotfiles-sandbox-ssh` binary to delegate to -- issue 005 already wires a
# `Host <instance-name>` SSH config entry at spawn time, keyed by the same
# slug spawn/teardown derive from the free-text task name
# (sandbox_instance_name), so this resolves that same slug and hands off to
# the system `ssh` client directly.
sbx-ssh() {
	. "$DOTFILES_HOME/sandbox/lib/task.sh"
	ssh "$(sandbox_instance_name "$1")"
}
