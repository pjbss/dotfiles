# remote.sh
#
# Reaching a running task's guest over ssh, for exec, run and attach. Meant to
# be sourced after namespace.sh, state.sh and lima.sh, not executed.

# pj_sandbox_shell_quote VALUE
#
# Prints VALUE as one single-quoted shell word that evaluates back to VALUE
# exactly, an embedded ' written as '\''. ssh joins its command into a single
# string for the remote shell to re-split (see commit a3e036d), so every
# argument bound for the guest goes through this. Ported from
# sandbox_shell_quote in sandbox/lib/task.sh, but done with parameter
# expansion instead of sed in a command substitution, so a value ending in
# newlines keeps them.
pj_sandbox_shell_quote() {
	_pjsq_rest="$1"
	_pjsq_out=""
	while :; do
		case "$_pjsq_rest" in
			*\'*)
				_pjsq_out="$_pjsq_out${_pjsq_rest%%\'*}'\\''"
				_pjsq_rest="${_pjsq_rest#*\'}"
				;;
			*)
				_pjsq_out="$_pjsq_out$_pjsq_rest"
				break
				;;
		esac
	done
	printf "'%s'" "$_pjsq_out"
}

# pj_sandbox_quote_args ARG...
#
# Prints every ARG through pj_sandbox_shell_quote, space-separated.
pj_sandbox_quote_args() {
	_pjqa_sep=""
	for _pjqa_arg in "$@"; do
		printf '%s' "$_pjqa_sep"
		pj_sandbox_shell_quote "$_pjqa_arg"
		_pjqa_sep=" "
	done
}

# pj_sandbox_running_instance SUBCOMMAND TASK
#
# Prints TASK's instance name, which is also its ssh Host entry. Fails, with
# the reason on stderr, if TASK has no state record or Lima doesn't report
# its VM as Running -- so the caller never reaches ssh for either.
pj_sandbox_running_instance() {
	if ! pj_sandbox_state_exists "$2"; then
		echo "pj-sandbox: $1: no sandbox task '$2' (see 'pj-sandbox list')" >&2
		return 1
	fi
	_pjri_instance="$(pj_sandbox_state_get "$2" instance)"
	if [ -z "$_pjri_instance" ]; then
		echo "pj-sandbox: $1: the record for '$2' lacks its instance" >&2
		return 1
	fi

	pj_sandbox_load_live
	_pjri_status="$(pj_sandbox_task_status "$2")"
	if [ "$_pjri_status" != Running ]; then
		echo "pj-sandbox: $1: '$2' isn't running (status: $_pjri_status)" >&2
		return 1
	fi
	printf '%s\n' "$_pjri_instance"
}
