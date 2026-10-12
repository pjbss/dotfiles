# cmd_run.sh
#
# pj-sandbox run <task> [--test-cmd <cmd>] [loop args...]
#
# Runs the autonomous issue loop, pj-run-issues, in the guest's /workspace the
# way bin/pj-sbx-run does, and exits with its status. Every argument after the
# task goes to pj-run-issues as given -- `--test-cmd 'make -C backend test'`
# arrives as two arguments, not five -- so see `pj-run-issues --help`.

. "$PJ_SANDBOX_HOME/lib/namespace.sh"
. "$PJ_SANDBOX_HOME/lib/state.sh"
. "$PJ_SANDBOX_HOME/lib/lima.sh"
. "$PJ_SANDBOX_HOME/lib/remote.sh"

cmd_run() {
	if [ "$#" -lt 1 ] || [ -z "$1" ]; then
		echo "Usage: pj-sandbox run <task> [--test-cmd <cmd>] [loop args...]" >&2
		return 1
	fi
	task="$1"
	shift

	instance="$(pj_sandbox_running_instance run "$task")" || return 1
	remote="cd /workspace && pj-run-issues"
	[ "$#" -eq 0 ] || remote="$remote $(pj_sandbox_quote_args "$@")"
	ssh -t "$instance" "$remote"
}
