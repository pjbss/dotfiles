# cmd_allowlist.sh
#
# pj-sandbox allowlist suggest <task> [--write <path>]
#
# Turns TASK's egress.log, typically from an `observe`-mode run, into
# allowlist entries: every host it contacted that the task's merged
# policy/allowlist doesn't already cover, once each and sorted, with its
# request count as a comment. IP literals are never suggested. --write
# appends the entries to PATH instead of printing them; spawn merges a
# repo's <git common dir>/pj-sandbox/allowlist and a directory template's
# allowlist, so either is the place to keep them. proxy/egress_log.py does
# the reading.

. "$PJ_SANDBOX_HOME/lib/namespace.sh"
. "$PJ_SANDBOX_HOME/lib/state.sh"

_pj_sandbox_allowlist_usage() {
	echo "Usage: pj-sandbox allowlist suggest <task> [--write <path>]" >&2
}

cmd_allowlist() {
	if [ "${1:-}" != suggest ]; then
		_pj_sandbox_allowlist_usage
		return 1
	fi
	shift

	task=""
	write=""
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--write)
				if [ "$#" -lt 2 ] || [ -z "$2" ]; then
					echo "pj-sandbox: allowlist: --write needs a path" >&2
					_pj_sandbox_allowlist_usage
					return 1
				fi
				write="$2"
				shift
				;;
			-*)
				echo "pj-sandbox: allowlist: unknown option '$1'" >&2
				_pj_sandbox_allowlist_usage
				return 1
				;;
			*)
				if [ -n "$task" ]; then
					_pj_sandbox_allowlist_usage
					return 1
				fi
				task="$1"
				;;
		esac
		shift
	done
	if [ -z "$task" ]; then
		_pj_sandbox_allowlist_usage
		return 1
	fi

	if ! pj_sandbox_state_exists "$task"; then
		echo "pj-sandbox: allowlist: no sandbox task '$task' (see 'pj-sandbox list')" >&2
		return 1
	fi
	log="$PJ_SANDBOX_STATE_DIR/$task/egress.log"
	if [ ! -f "$log" ]; then
		echo "pj-sandbox: allowlist: no egress log for task '$task' yet ($log); spawn it in observe mode and use it first" >&2
		return 1
	fi

	suggested="$(python3 "$PJ_SANDBOX_HOME/proxy/egress_log.py" suggest "$log" "$PJ_SANDBOX_STATE_DIR/$task/policy")" || return 1
	if [ -z "$write" ]; then
		printf '%s\n' "$suggested"
		return 0
	fi
	mkdir -p "$(dirname "$write")" && printf '%s\n' "$suggested" >> "$write" || {
		echo "pj-sandbox: allowlist: couldn't write '$write'" >&2
		return 1
	}
	echo "pj-sandbox: appended $(printf '%s\n' "$suggested" | grep -vc '^#') suggested host(s) to $write"
}
