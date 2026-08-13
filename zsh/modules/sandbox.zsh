#!/bin/sh
# sandbox.zsh
#
# `pj-sbx-ssh`, the one sandbox lifecycle command with no `bin/pj-sbx-*`
# script counterpart (spawn/list/teardown are the real binaries -- issues
# 002/003/006/007).

# pj-sbx-ssh <task-name>
#
# Connects into a running sandbox from a terminal. There's no
# `bin/pj-sbx-ssh` script to delegate to -- issue 005 already wires a
# `Host <instance-name>` SSH config entry at spawn time, keyed by the same
# slug spawn/teardown derive from the free-text task name
# (sandbox_instance_name), so this resolves that same slug and hands off to
# the system `ssh` client directly. Lands the session in /workspace, the
# guest mount point for the spawned worktree (see sandbox_render_lima_config
# in task.sh), rather than the guest's home directory.
pj-sbx-ssh() {
	. "$DOTFILES_HOME/sandbox/lib/task.sh"
	ssh -t "$(sandbox_instance_name "$1")" 'cd /workspace && exec "$SHELL" -l'
}
