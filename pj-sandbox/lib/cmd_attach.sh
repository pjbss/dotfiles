# cmd_attach.sh
#
# pj-sandbox attach <task>
#
# Opens an interactive login shell in the guest's /workspace, over the same
# ssh Host entry VS Code Remote-SSH uses.

. "$PJ_SANDBOX_HOME/lib/namespace.sh"
. "$PJ_SANDBOX_HOME/lib/state.sh"
. "$PJ_SANDBOX_HOME/lib/lima.sh"
. "$PJ_SANDBOX_HOME/lib/remote.sh"

cmd_attach() {
	if [ "$#" -ne 1 ] || [ -z "$1" ]; then
		echo "Usage: pj-sandbox attach <task>" >&2
		return 1
	fi

	instance="$(pj_sandbox_running_instance attach "$1")" || return 1
	# $SHELL is the guest's, expanded there.
	# shellcheck disable=SC2016
	ssh -t "$instance" 'cd /workspace && exec "${SHELL:-/bin/sh}" -l'
}
