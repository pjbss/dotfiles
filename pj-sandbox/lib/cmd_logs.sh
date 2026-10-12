# cmd_logs.sh
#
# pj-sandbox logs <task> [--denied] [--follow] [--json]
#
# Shows TASK's proxy decisions from <state dir>/<task>/egress.log as a table:
# time, decision, method, host, path and rule, with `injected: <profile>`
# where a token was swapped in. --denied keeps only refused requests (policy
# denials and placeholder leaks), --follow keeps printing as the log grows,
# and --json prints the matching log lines unchanged instead of the table.
# proxy/egress_log.py does the reading.

. "$PJ_SANDBOX_HOME/lib/namespace.sh"
. "$PJ_SANDBOX_HOME/lib/state.sh"

_pj_sandbox_logs_usage() {
	echo "Usage: pj-sandbox logs <task> [--denied] [--follow] [--json]" >&2
}

cmd_logs() {
	task=""
	flags=""
	for arg in "$@"; do
		case "$arg" in
			--denied | --follow | --json) flags="$flags $arg" ;;
			-*)
				echo "pj-sandbox: logs: unknown option '$arg'" >&2
				_pj_sandbox_logs_usage
				return 1
				;;
			*)
				if [ -n "$task" ]; then
					_pj_sandbox_logs_usage
					return 1
				fi
				task="$arg"
				;;
		esac
	done
	if [ -z "$task" ]; then
		_pj_sandbox_logs_usage
		return 1
	fi

	if ! pj_sandbox_state_exists "$task"; then
		echo "pj-sandbox: logs: no sandbox task '$task' (see 'pj-sandbox list')" >&2
		return 1
	fi
	log="$PJ_SANDBOX_STATE_DIR/$task/egress.log"
	if [ ! -f "$log" ]; then
		echo "pj-sandbox: logs: no egress log for task '$task' yet ($log); nothing has gone through its proxy" >&2
		return 1
	fi

	# exec, so stopping a --follow stops the reader too.
	# shellcheck disable=SC2086
	exec python3 "$PJ_SANDBOX_HOME/proxy/egress_log.py" show "$log" $flags
}
