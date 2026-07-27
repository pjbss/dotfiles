#!/bin/sh
# sandbox.zsh
#
# Short aliases/functions wrapping the sandbox lifecycle commands
# (bin/pj-sandbox-*, issues 003/006/007) so a sandbox can be spawned,
# listed, connected to, and torn down without typing the full
# `pj-sandbox-*` command names.

alias pj-sbx-spawn='pj-sandbox-spawn'
alias pj-sbx-list='pj-sandbox-list'
alias pj-sbx-teardown='pj-sandbox-teardown'

# pj-sbx-ssh <task-name>
#
# Connects into a running sandbox from a terminal. There's no
# `pj-sandbox-ssh` binary to delegate to -- issue 005 already wires a
# `Host <instance-name>` SSH config entry at spawn time, keyed by the same
# slug spawn/teardown derive from the free-text task name
# (sandbox_instance_name), so this resolves that same slug and hands off to
# the system `ssh` client directly.
pj-sbx-ssh() {
	. "$DOTFILES_HOME/sandbox/lib/task.sh"
	ssh "$(sandbox_instance_name "$1")"
}
