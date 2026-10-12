# state.sh
#
# The per-task state record, $PJ_SANDBOX_STATE_DIR/<task>/meta: one key=value
# line per field, everything after the first '=' being the value. This file,
# not ~/.ssh/pj-sandbox-next-config or Lima, is what says a task exists.
# Meant to be sourced after namespace.sh, not executed.

# Every key a record may hold, in the order a record is written.
PJ_SANDBOX_STATE_KEYS="task instance repo branch base agents ssh_port ports created fetched egress_mode"

# pj_sandbox_state_valid_task TASK
#
# Task names become directory names, so refuse anything that could escape or
# hide in the state dir.
pj_sandbox_state_valid_task() {
	case "$1" in
		"" | .* | */*)
			echo "pj-sandbox: invalid task name '$1'" >&2
			return 1
			;;
	esac
}

# pj_sandbox_state_write TASK KEY=VALUE...
#
# Replaces TASK's record with exactly the given fields, written in
# PJ_SANDBOX_STATE_KEYS order. The record is written to a hidden temp file
# beside meta and renamed over it, so a reader only ever sees the old record
# or the new one; a write that fails or is interrupted removes its temp file.
pj_sandbox_state_write() {
	task="$1"
	shift
	pj_sandbox_state_valid_task "$task" || return 1

	for arg in "$@"; do
		case "$arg" in
			*=*) ;;
			*)
				echo "pj-sandbox: state field '$arg' is not key=value" >&2
				return 1
				;;
		esac
		case " $PJ_SANDBOX_STATE_KEYS " in
			*" ${arg%%=*} "*) ;;
			*)
				echo "pj-sandbox: unknown state key '${arg%%=*}'" >&2
				return 1
				;;
		esac
		case "$arg" in
			*'
'*)
				echo "pj-sandbox: state value for '${arg%%=*}' contains a newline" >&2
				return 1
				;;
		esac
	done

	dir="$PJ_SANDBOX_STATE_DIR/$task"
	mkdir -p "$dir" || return 1

	# A subshell, so the traps that clean up the temp file never replace the
	# caller's own.
	(
		tmp="$(mktemp "$dir/.meta.XXXXXX")" || exit 1
		trap 'rm -f "$tmp"' EXIT
		trap 'exit 1' HUP INT TERM

		for key in $PJ_SANDBOX_STATE_KEYS; do
			for arg in "$@"; do
				if [ "${arg%%=*}" = "$key" ]; then
					printf '%s\n' "$arg"
				fi
			done
		done > "$tmp" || exit 1

		mv -f "$tmp" "$dir/meta" || exit 1
	) || {
		# Don't leave an empty task dir from a first write that never landed.
		rmdir "$dir" 2>/dev/null
		return 1
	}
}

# pj_sandbox_state_update TASK KEY=VALUE...
#
# Rewrites TASK's record with the given fields set and every other field kept
# as it was. Fails if TASK has no record.
# A subshell, so the IFS and noglob it needs never leak to the caller.
pj_sandbox_state_update() (
	task="$1"
	shift
	pj_sandbox_state_exists "$task" || exit 1

	kept="$(cat "$PJ_SANDBOX_STATE_DIR/$task/meta")" || exit 1
	for arg in "$@"; do
		kept="$(printf '%s\n' "$kept" | awk -v k="${arg%%=*}" 'index($0, k "=") != 1')"
	done
	# Each kept line is one argument, taken literally.
	set -f
	IFS='
'
	# shellcheck disable=SC2086
	set -- $kept "$@"
	IFS=' 	
'
	pj_sandbox_state_write "$task" "$@"
)

# pj_sandbox_state_exists TASK
pj_sandbox_state_exists() {
	pj_sandbox_state_valid_task "$1" 2>/dev/null && [ -f "$PJ_SANDBOX_STATE_DIR/$1/meta" ]
}

# pj_sandbox_state_get TASK KEY
#
# Prints KEY's value (nothing if the record lacks it). Fails if TASK has no
# record.
pj_sandbox_state_get() {
	pj_sandbox_state_exists "$1" || return 1
	awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' \
		"$PJ_SANDBOX_STATE_DIR/$1/meta"
}

# pj_sandbox_state_delete TASK
#
# Removes TASK's record, and its dir once nothing else is in it. Fails if
# TASK has no record.
pj_sandbox_state_delete() {
	pj_sandbox_state_exists "$1" || return 1
	rm -f "$PJ_SANDBOX_STATE_DIR/$1/meta" || return 1
	rmdir "$PJ_SANDBOX_STATE_DIR/$1" 2>/dev/null || true
}

# pj_sandbox_state_tasks
#
# Prints every task that has a record, one per line, sorted.
pj_sandbox_state_tasks() {
	for meta in "$PJ_SANDBOX_STATE_DIR"/*/meta; do
		[ -f "$meta" ] || continue
		basename "$(dirname "$meta")"
	done | sort
}

# pj_sandbox_state_json TASK STATUS
#
# Prints TASK's record as one JSON object of string fields, plus "status".
# Built with awk so no JSON tool is needed: backslash, quote and every other
# control character are escaped.
pj_sandbox_state_json() {
	pj_sandbox_state_exists "$1" || return 1
	{
		cat "$PJ_SANDBOX_STATE_DIR/$1/meta"
		printf 'status=%s\n' "$2"
	} | awk '
		BEGIN {
			for (i = 1; i < 32; i++) ctl[sprintf("%c", i)] = sprintf("\\u%04x", i)
			ctl["\t"] = "\\t"; ctl["\r"] = "\\r"
		}
		function esc(s,    out, c, i) {
			out = ""
			for (i = 1; i <= length(s); i++) {
				c = substr(s, i, 1)
				if (c == "\\") out = out "\\\\"
				else if (c == "\"") out = out "\\\""
				else if (c in ctl) out = out ctl[c]
				else out = out c
			}
			return out
		}
		{
			eq = index($0, "=")
			if (eq == 0) next
			printf "%s\"%s\":\"%s\"", (n++ ? "," : "{"), esc(substr($0, 1, eq - 1)), esc(substr($0, eq + 1))
		}
		END { print (n ? "}" : "{}") }
	'
}
