# cmd_gc.sh
#
# pj-sandbox gc [--dry-run]
#
# Cleans up after sandboxes that crashed or were torn down by hand:
#   - pjsb- Lima instances that no state record names are deleted
#   - records whose instance Lima no longer has are deleted once their meta
#     is older than PJ_SANDBOX_GC_GRACE_MINUTES (default 60), and the egress
#     proxy each one names is stopped first
#   - pjsb- Host entries in the include file that no remaining record names
#     are removed
# Everything is decided from one `limactl list --json` call, and gc refuses
# to run without it: with no live list every record would look orphaned.
# Instances without the pjsb- prefix are never seen, let alone touched.
# --dry-run prints what would go and changes nothing.

. "$PJ_SANDBOX_HOME/lib/namespace.sh"
. "$PJ_SANDBOX_HOME/lib/state.sh"
. "$PJ_SANDBOX_HOME/lib/lima.sh"
. "$PJ_SANDBOX_HOME/lib/ssh_config.sh"
. "$PJ_SANDBOX_HOME/lib/proxy.sh"

PJ_SANDBOX_GC_GRACE_MINUTES="${PJ_SANDBOX_GC_GRACE_MINUTES:-60}"

# _pj_sandbox_gc_has LIST NAME
#
# True if NAME is one of LIST's newline-separated words.
_pj_sandbox_gc_has() {
	printf '%s\n' "$1" | grep -qxF "$2"
}

cmd_gc() {
	dry_run=no
	for arg in "$@"; do
		case "$arg" in
			--dry-run) dry_run=yes ;;
			*)
				echo "Usage: pj-sandbox gc [--dry-run]" >&2
				return 1
				;;
		esac
	done
	case "$PJ_SANDBOX_GC_GRACE_MINUTES" in
		"" | *[!0-9]*)
			echo "pj-sandbox: gc: PJ_SANDBOX_GC_GRACE_MINUTES must be a whole number of minutes, got '$PJ_SANDBOX_GC_GRACE_MINUTES'" >&2
			return 1
			;;
	esac

	if ! live="$(pj_sandbox_lima_statuses)"; then
		echo "pj-sandbox: gc: 'limactl list --json' failed; nothing was cleaned up" >&2
		return 1
	fi
	live="$(printf '%s\n' "$live" | awk 'NF { print $1 }')"

	recorded=""
	kept=""
	stale=""
	for task in $(pj_sandbox_state_tasks); do
		instance="$(pj_sandbox_state_get "$task" instance)"
		recorded="$recorded$instance
"
		if ! _pj_sandbox_gc_has "$live" "$instance" &&
			{ [ "$PJ_SANDBOX_GC_GRACE_MINUTES" -eq 0 ] ||
				[ -n "$(find "$PJ_SANDBOX_STATE_DIR/$task/meta" -mmin "+$PJ_SANDBOX_GC_GRACE_MINUTES")" ]; }; then
			stale="$stale$task
"
		else
			kept="$kept$instance
"
		fi
	done

	if [ "$dry_run" = yes ]; then
		verb="would delete"
	else
		verb="deleted"
	fi

	for instance in $live; do
		_pj_sandbox_gc_has "$recorded" "$instance" && continue
		if [ "$dry_run" = no ] && ! limactl delete --force "$instance"; then
			echo "pj-sandbox: gc: 'limactl delete' failed for $instance" >&2
			return 1
		fi
		echo "$verb instance $instance"
	done

	for task in $stale; do
		if [ "$dry_run" = no ]; then
			pj_sandbox_proxy_stop "$task" || return 1
			rm -rf "${PJ_SANDBOX_STATE_DIR:?}/$task" || return 1
		fi
		echo "$verb state $task"
	done

	for host in $(pj_sandbox_ssh_hosts "$PJ_SANDBOX_SSH_INCLUDE_FILE"); do
		case "$host" in
			"$PJ_SANDBOX_INSTANCE_PREFIX"*) ;;
			*) continue ;;
		esac
		_pj_sandbox_gc_has "$kept" "$host" && continue
		if [ "$dry_run" = no ]; then
			pj_sandbox_ssh_remove_entry "$PJ_SANDBOX_SSH_INCLUDE_FILE" "$host" || return 1
		fi
		echo "$verb ssh entry $host"
	done
}
