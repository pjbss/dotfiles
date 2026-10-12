# cmd_list.sh
#
# pj-sandbox list [--json]
#
# Every task with a state record, with its live status merged in from Lima.
# Tasks come only from the state dir: a pjsb- VM with no record isn't listed
# (that's gc's business), and a recorded VM Lima doesn't know shows "missing".

. "$PJ_SANDBOX_HOME/lib/namespace.sh"
. "$PJ_SANDBOX_HOME/lib/state.sh"
. "$PJ_SANDBOX_HOME/lib/lima.sh"

cmd_list() {
	json=no
	for arg in "$@"; do
		case "$arg" in
			--json) json=yes ;;
			*)
				echo "pj-sandbox: list: unknown argument '$arg' (usage: pj-sandbox list [--json])" >&2
				return 1
				;;
		esac
	done

	pj_sandbox_load_live

	if [ "$json" = yes ]; then
		sep=""
		printf '['
		for task in $(pj_sandbox_state_tasks); do
			printf '%s%s' "$sep" "$(pj_sandbox_state_json "$task" "$(pj_sandbox_task_status "$task")")"
			sep=","
		done
		printf ']\n'
		return
	fi

	row='%-24s %-9s %-28s %-24s %s\n'
	# shellcheck disable=SC2059
	printf "$row" TASK STATUS INSTANCE BRANCH SSH_PORT
	for task in $(pj_sandbox_state_tasks); do
		# shellcheck disable=SC2059
		printf "$row" "$task" "$(pj_sandbox_task_status "$task")" \
			"$(pj_sandbox_state_get "$task" instance)" \
			"$(pj_sandbox_state_get "$task" branch)" \
			"$(pj_sandbox_state_get "$task" ssh_port)"
	done
}
