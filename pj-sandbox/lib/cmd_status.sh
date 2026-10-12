# cmd_status.sh
#
# pj-sandbox status <task> [--json]
#
# One task's state record plus its live status: key=value lines ending in
# status=<live>, or with --json one object holding the same fields.

. "$PJ_SANDBOX_HOME/lib/namespace.sh"
. "$PJ_SANDBOX_HOME/lib/state.sh"
. "$PJ_SANDBOX_HOME/lib/lima.sh"

cmd_status() {
	json=no
	task=""
	for arg in "$@"; do
		case "$arg" in
			--json) json=yes ;;
			-*)
				task=""
				break
				;;
			*)
				if [ -n "$task" ]; then
					task=""
					break
				fi
				task="$arg"
				;;
		esac
	done
	if [ -z "$task" ]; then
		echo "Usage: pj-sandbox status <task> [--json]" >&2
		return 1
	fi

	if ! pj_sandbox_state_exists "$task"; then
		echo "pj-sandbox: status: no sandbox task '$task' (see 'pj-sandbox list')" >&2
		return 1
	fi

	pj_sandbox_load_live
	status="$(pj_sandbox_task_status "$task")"

	if [ "$json" = yes ]; then
		pj_sandbox_state_json "$task" "$status"
	else
		cat "$PJ_SANDBOX_STATE_DIR/$task/meta"
		printf 'status=%s\n' "$status"
	fi
}
