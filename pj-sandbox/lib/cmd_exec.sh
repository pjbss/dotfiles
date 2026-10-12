# cmd_exec.sh
#
# pj-sandbox exec <task> -- <cmd> [args...]
#
# Runs <cmd> in the guest's /workspace with every argument arriving exactly as
# given, and exits with its status. No tty is requested, so it suits scripts.

. "$PJ_SANDBOX_HOME/lib/namespace.sh"
. "$PJ_SANDBOX_HOME/lib/state.sh"
. "$PJ_SANDBOX_HOME/lib/lima.sh"
. "$PJ_SANDBOX_HOME/lib/remote.sh"

cmd_exec() {
	if [ "$#" -lt 3 ] || [ -z "$1" ] || [ "$2" != -- ]; then
		echo "Usage: pj-sandbox exec <task> -- <cmd> [args...]" >&2
		return 1
	fi
	task="$1"
	shift 2

	instance="$(pj_sandbox_running_instance exec "$task")" || return 1
	ssh "$instance" "cd /workspace && $(pj_sandbox_quote_args "$@")"
}
