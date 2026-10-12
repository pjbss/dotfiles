# lima.sh
#
# Live VM status from Lima, limited to pj-sandbox's own instances. Meant to be
# sourced after namespace.sh and state.sh, not executed.

# pj_sandbox_lima_statuses
#
# Prints "<instance> <status>" for every Lima instance whose name starts with
# PJ_SANDBOX_INSTANCE_PREFIX, from one `limactl list --json` call. Anything
# else Lima knows about (the old sandbox's VMs included) is dropped here, so
# no caller can mistake it for one of ours. Fails if limactl does.
#
# Each JSON object is its own line. The first "name"/"status" on a line is the
# instance's own: later ones belong to nested objects such as config.user.
pj_sandbox_lima_statuses() {
	out="$(limactl list --json 2>/dev/null)" || return 1
	printf '%s\n' "$out" | while IFS= read -r line; do
		name="$(printf '%s\n' "$line" | grep -Eo '"name":"[^"]*"' | head -1 | sed -E 's/.*:"(.*)"/\1/')"
		status="$(printf '%s\n' "$line" | grep -Eo '"status":"[^"]*"' | head -1 | sed -E 's/.*:"(.*)"/\1/')"
		case "$name" in
			"$PJ_SANDBOX_INSTANCE_PREFIX"*) printf '%s %s\n' "$name" "${status:-unknown}" ;;
		esac
	done
}

# pj_sandbox_task_status TASK
#
# Prints TASK's live status: Lima's own word for it (Running, Stopped, ...),
# "missing" when the recorded instance isn't one of pj_sandbox_lima_statuses,
# or "unknown" when Lima couldn't be asked. The caller sets
# PJ_SANDBOX_LIVE (pj_sandbox_lima_statuses' output) and PJ_SANDBOX_LIVE_OK
# (yes/no) once, so listing many tasks costs one limactl call.
pj_sandbox_task_status() {
	if [ "${PJ_SANDBOX_LIVE_OK:-no}" != yes ]; then
		echo unknown
		return
	fi
	instance="$(pj_sandbox_state_get "$1" instance)"
	status="$(printf '%s\n' "$PJ_SANDBOX_LIVE" | awk -v n="$instance" 'n != "" && $1 == n { print $2; exit }')"
	echo "${status:-missing}"
}

# pj_sandbox_load_live
#
# Sets PJ_SANDBOX_LIVE and PJ_SANDBOX_LIVE_OK for pj_sandbox_task_status,
# warning on stderr if Lima couldn't be asked.
pj_sandbox_load_live() {
	if PJ_SANDBOX_LIVE="$(pj_sandbox_lima_statuses)"; then
		PJ_SANDBOX_LIVE_OK=yes
	else
		PJ_SANDBOX_LIVE=""
		PJ_SANDBOX_LIVE_OK=no
		echo "pj-sandbox: warning: 'limactl list --json' failed; live status is unknown" >&2
	fi
}
