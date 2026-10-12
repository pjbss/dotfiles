# cmd_rm.sh
#
# pj-sandbox rm <task> [--fetch]
#
# Tears a task down: with --fetch, runs `pj-sandbox fetch` first and stops if
# that fails. Then it stops the task's proxy, deletes its pjsb- Lima VM, drops
# its Host block from the include file, and removes its state dir. The host
# branch and refs/sandbox/<task>/* are left alone, so no work is lost.

. "$PJ_SANDBOX_HOME/lib/namespace.sh"
. "$PJ_SANDBOX_HOME/lib/state.sh"
. "$PJ_SANDBOX_HOME/lib/lima.sh"
. "$PJ_SANDBOX_HOME/lib/ssh_config.sh"
. "$PJ_SANDBOX_HOME/lib/cmd_fetch.sh"

# pj_sandbox_proxy_stop TASK
#
# Stops TASK's egress proxy. There's no proxy yet (issue 023), so a no-op.
pj_sandbox_proxy_stop() {
	:
}

cmd_rm() {
	task=""
	fetch=no
	for arg in "$@"; do
		case "$arg" in
			--fetch) fetch=yes ;;
			-*)
				echo "pj-sandbox: rm: unknown option '$arg'" >&2
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
		echo "Usage: pj-sandbox rm <task> [--fetch]" >&2
		return 1
	fi

	if ! pj_sandbox_state_exists "$task"; then
		echo "pj-sandbox: rm: no sandbox task '$task' (see 'pj-sandbox list')" >&2
		return 1
	fi
	instance="$(pj_sandbox_state_get "$task" instance)"
	case "$instance" in
		"$PJ_SANDBOX_INSTANCE_PREFIX"?*) ;;
		*)
			echo "pj-sandbox: rm: the record for '$task' names instance '$instance', which isn't a $PJ_SANDBOX_INSTANCE_PREFIX instance; not touching it" >&2
			return 1
			;;
	esac

	if [ "$fetch" = yes ]; then
		cmd_fetch "$task" || {
			echo "pj-sandbox: rm: fetch failed, so '$task' was not removed" >&2
			return 1
		}
	fi

	if ! live="$(pj_sandbox_lima_statuses)"; then
		echo "pj-sandbox: rm: 'limactl list --json' failed, so '$task' was not removed" >&2
		return 1
	fi

	pj_sandbox_proxy_stop "$task" || return 1
	if printf '%s\n' "$live" | awk -v n="$instance" '$1 == n { found = 1 } END { exit !found }'; then
		if ! limactl delete --force "$instance"; then
			echo "pj-sandbox: rm: 'limactl delete' failed for $instance" >&2
			return 1
		fi
	fi
	pj_sandbox_ssh_remove_entry "$PJ_SANDBOX_SSH_INCLUDE_FILE" "$instance" || return 1
	rm -rf "${PJ_SANDBOX_STATE_DIR:?}/$task" || return 1

	echo "pj-sandbox: removed '$task' ($instance); its branch and refs/sandbox/$task/* are kept"
}
