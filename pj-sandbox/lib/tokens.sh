# tokens.sh
#
# The host side of the credential broker: resolves each placeholder's real
# token from the token_source list in a task's policy/inject.json, and hands
# the tokens to the proxy process only, through its environment, as the
# variables proxy/inject.py reads (PJSB_TOKEN_<PLACEHOLDER>). A token is
# never written to the state dir, the policy dir or anywhere in the guest,
# and never put on a command line. Meant to be sourced, not executed;
# PJ_SANDBOX_HOME must name the pj-sandbox directory.
#
# A token source is one of:
#
#   keychain:SERVICE/ACCOUNT  security find-generic-password -s SERVICE -a ACCOUNT -w
#   cmd:COMMAND               COMMAND's stdout, run with sh -c
#   file:PATH                 PATH's contents; a leading ~/ is $HOME
#
# A source that fails or yields nothing doesn't count, and the next is tried.

# _pj_sandbox_token_from SOURCE
#
# Prints SOURCE's token, if it has one. Its own errors are dropped, since
# "not there" is the common case and the caller warns when nothing works.
_pj_sandbox_token_from() {
	case "$1" in
		keychain:?*/?*)
			item="${1#keychain:}"
			security find-generic-password -s "${item%%/*}" -a "${item#*/}" -w 2>/dev/null
			;;
		cmd:?*)
			sh -c "${1#cmd:}" </dev/null 2>/dev/null
			;;
		file:?*)
			path="${1#file:}"
			case "$path" in
				"~/"*) path="$HOME/${path#"~/"}" ;;
			esac
			cat "$path" 2>/dev/null
			;;
		*)
			echo "pj-sandbox: warning: skipping malformed token source '$1'" >&2
			return 1
			;;
	esac
}

# pj_sandbox_token_resolve SOURCE...
#
# Prints the token from the first SOURCE that yields one. If none does it
# prints nothing and warns, but still succeeds: the proxy then leaves that
# placeholder in place, so the agent sees a 401 rather than a sandbox that
# won't start. A subshell, so no token is left in a caller's variables.
pj_sandbox_token_resolve() (
	for source in "$@"; do
		token="$(_pj_sandbox_token_from "$source")" || token=""
		if [ -n "$token" ]; then
			printf '%s\n' "$token"
			exit 0
		fi
	done
	echo "pj-sandbox: warning: no token from any of: $*; its placeholder will be sent as-is" >&2
)

# pj_sandbox_tokens_exec POLICY_DIR CMD [ARG...]
#
# Resolves the token for every placeholder in POLICY_DIR/inject.json (each
# once, however many rules share it) and execs CMD, the proxy, with them in
# its environment. The exports happen in a subshell, so the caller's
# environment never holds a token. A malformed inject.json fails without
# running CMD; a missing one resolves nothing.
pj_sandbox_tokens_exec() (
	policy_dir="$1"
	shift
	pairs="$(python3 "$PJ_SANDBOX_HOME/proxy/inject.py" sources "$policy_dir")" || exit 1
	names="$(printf '%s\n' "$pairs" | cut -f1 | awk 'NF && !seen[$0]++')"
	for name in $names; do
		sources="$(printf '%s\n' "$pairs" | awk -F '\t' -v n="$name" '$1 == n { print $2 }')"
		IFS='
'
		set -f
		# shellcheck disable=SC2086 # split on newlines only, one source per line
		token="$(pj_sandbox_token_resolve $sources)"
		set +f
		unset IFS
		export "$name=$token"
	done
	exec "$@"
)
