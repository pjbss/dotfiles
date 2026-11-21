# gate.sh
#
# Deciding what command gates a project, and the Makefile discovery behind
# it. pj-run-issues gates every issue on it, pj-stack-verify runs it on every
# stack layer, and pj-affected-tests finds package suites with the same
# discovery -- one copy, so the three can't disagree about what "the suite"
# is. (pj-affected-tests and pj-run-issues each used to carry their own
# has_test_target and pruned list.) Meant to be sourced, not executed; POSIX
# sh. Everything works relative to the current directory, which callers set
# to the project root.

# The directories full of vendored Makefiles nobody means. Discovery never
# looks inside them, so a repo full of dependencies doesn't turn the gate into
# a crawl or into running someone else's suite.
PJ_GATE_PRUNED=".git node_modules venv .venv vendor target build dist"

# pj_gate_shell_word STRING -- STRING as one word for `sh -c`: bare when it is
# only characters no shell treats specially, so the common case reads
# naturally, and single-quoted otherwise, with each embedded ' closed, escaped
# and reopened.
pj_gate_shell_word() {
	case "$1" in
		*[!A-Za-z0-9._/+=:@%-]*|'')
			printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
		*) printf '%s' "$1" ;;
	esac
}

# pj_gate_has_test_target DIR -- true when DIR holds a Makefile declaring a
# `test` target.
pj_gate_has_test_target() {
	[ -f "$1/Makefile" ] && grep -q '^test:' "$1/Makefile"
}

# pj_gate_is_pruned DIR -- true when any path component of DIR is one of
# $PJ_GATE_PRUNED.
pj_gate_is_pruned() {
	for pj_gate_name in $PJ_GATE_PRUNED; do
		case "/$1/" in
			*/"$pj_gate_name"/*) return 0 ;;
		esac
	done
	return 1
}

# pj_gate_find_suites [MAXDEPTH] -- every directory below the current one,
# sorted and without a leading ./, whose Makefile has a test target. Pruned
# directories are never entered. MAXDEPTH limits how deep find looks for the
# Makefile itself.
pj_gate_find_suites() {
	pj_gate_depth="${1:-}"
	set --
	for pj_gate_name in $PJ_GATE_PRUNED; do
		set -- "$@" -o -name "$pj_gate_name"
	done
	shift # the leading -o

	find . ${pj_gate_depth:+-maxdepth "$pj_gate_depth"} \( "$@" \) -prune -o -name Makefile -print 2>/dev/null |
		sed 's|/Makefile$||; s|^\./||' | sort |
		while IFS= read -r pj_gate_dir; do
			# An `if`, not `&&`: the loop is the pipeline's last stage, so a
			# test-less Makefile examined last would otherwise make the whole
			# pipeline fail -- and kill a caller running under `set -e`
			# inside `$(...)`, as sh does.
			if pj_gate_has_test_target "$pj_gate_dir"; then
				printf '%s\n' "$pj_gate_dir"
			fi
		done
}

# pj_gate_resolve [EXPLICIT]
#
# Decides the gate for the project in the current directory, in this order:
# EXPLICIT if given (run as given, since only running it can check it); an
# executable ./.pj/test; `make test` at the root; the one `make -C <dir> test`
# within four levels below it. Sets $pj_gate_cmd and returns 0, or sets
# $pj_gate_error to a message saying what to do and returns 1. Sets globals
# rather than printing, so a caller can report the refusal its own way.
pj_gate_resolve() {
	pj_gate_cmd=""
	pj_gate_error=""

	if [ -n "${1:-}" ]; then
		pj_gate_cmd="$1"
		return 0
	fi

	if [ -e .pj/test ]; then
		# Refused rather than skipped: falling through to `make test` would
		# gate the work on a suite the project deliberately named something
		# else over.
		if [ ! -x .pj/test ]; then
			pj_gate_error=".pj/test exists but isn't executable -- run 'chmod +x .pj/test' (and commit it) so it can gate this work. It is not skipped in favor of 'make test', since that would gate the work on a suite this project didn't choose."
			return 1
		fi
		pj_gate_cmd="./.pj/test"
		return 0
	fi

	if pj_gate_has_test_target .; then
		pj_gate_cmd="make test"
		return 0
	fi

	# Depth-limited, so that on a large monorepo this stays a moment's work
	# and the candidates it reports back are all plausible answers to "which
	# suite gates this?".
	pj_gate_found="$(pj_gate_find_suites 4)"

	if [ -z "$pj_gate_found" ]; then
		pj_gate_error="no .pj/test and no 'make test' target under $PWD, so there is nothing to gate on. Commit an executable .pj/test at the project root to say what the gate is, or pass --test-cmd CMD to name it for this one run."
		return 1
	fi

	if [ "$(printf '%s\n' "$pj_gate_found" | wc -l | tr -d ' ')" -gt 1 ]; then
		pj_gate_error="several 'make test' targets under $PWD -- commit an executable .pj/test at the project root that runs the one that gates this work, or pass --test-cmd to name it for this one run:
$(printf '%s\n' "$pj_gate_found" | sed 's|^|  |')"
		return 1
	fi

	# Quoted, because this string is run by `sh -c` -- by the loop and by the
	# Stop hook, via PJ_TEST_CMD -- and a directory called "my app" would
	# otherwise split into `-C my` and a target named `app`.
	pj_gate_cmd="make -C $(pj_gate_shell_word "$pj_gate_found") test"
	return 0
}
