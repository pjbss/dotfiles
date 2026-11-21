#!/bin/bash
# gate_test.sh
#
# Unit tests for agents/lib/gate.sh -- deciding what command gates a project
# (an explicit command, an executable .pj/test, `make test`, or the one
# `make -C <dir> test` below the root) and the Makefile discovery behind it.
# pj-run-issues, pj-affected-tests and pj-stack-verify all source it, so the
# three can't disagree about what the gate is. Every case runs in a throwaway
# directory; nothing here reads a real project.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
DOTFILES_HOME="$(cd -P "$TEST_DIR/../.." && pwd)"

. "$DOTFILES_HOME/test/assert.sh"
. "$DOTFILES_HOME/agents/lib/gate.sh"

fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

# suite DIR -- a Makefile with a test target in DIR.
suite() {
	mkdir -p "$1"
	printf 'test:\n\t@true\n' > "$1/Makefile"
}

# resolve_in DIR [EXPLICIT] -- runs pj_gate_resolve from DIR in a subshell,
# setting $rc, $cmd (the resolved command) and $err (the refusal message).
resolve_in() {
	if out="$(cd "$1" && { pj_gate_resolve "${2:-}" && printf 'CMD:%s' "$pj_gate_cmd"; } ||
		{ printf 'ERR:%s' "$pj_gate_error"; exit 1; })"; then
		rc=0
	else
		rc=$?
	fi
	cmd="$(printf '%s' "$out" | sed -n 's/^CMD://p')"
	err="${out#ERR:}"
}

# --- shell_word ---

assert_eq "backend" "$(pj_gate_shell_word backend)" "a plain word stays bare"
assert_eq "'my app'" "$(pj_gate_shell_word "my app")" "a word with a space is single-quoted"
assert_eq "'it'\\''s'" "$(pj_gate_shell_word "it's")" "an embedded quote is closed, escaped and reopened"
assert_eq "''" "$(pj_gate_shell_word "")" "an empty word is an explicit empty string"

# --- has_test_target / is_pruned ---

suite "$fixture_root/withtest"
mkdir -p "$fixture_root/notest"
printf 'build:\n\t@true\n' > "$fixture_root/notest/Makefile"
assert_ok "a Makefile with test: has a test target" pj_gate_has_test_target "$fixture_root/withtest"
assert_not_ok "a Makefile without test: doesn't" pj_gate_has_test_target "$fixture_root/notest"
assert_not_ok "a directory with no Makefile doesn't" pj_gate_has_test_target "$fixture_root"
assert_ok "node_modules is pruned" pj_gate_is_pruned "app/node_modules/x"
assert_ok ".venv is pruned at the top" pj_gate_is_pruned ".venv"
assert_not_ok "an ordinary path isn't pruned" pj_gate_is_pruned "services/api"
assert_not_ok "a name merely containing a pruned one isn't pruned" pj_gate_is_pruned "my_build_tools"

# --- find_suites ---

tree="$fixture_root/tree"
suite "$tree/services/api"
suite "$tree/web"
suite "$tree/node_modules/dep"
suite "$tree/a/b/c/d/deep"
mkdir -p "$tree/docs"
printf 'html:\n\t@true\n' > "$tree/docs/Makefile"
assert_eq "a/b/c/d/deep services/api web" "$(cd "$tree" && pj_gate_find_suites | tr '\n' ' ' | sed 's/ $//')" \
	"find_suites lists every suite, sorted, skipping pruned and test-less Makefiles"
assert_eq "services/api web" "$(cd "$tree" && pj_gate_find_suites 4 | tr '\n' ' ' | sed 's/ $//')" \
	"find_suites honors a depth limit"

# Under sh with errexit -- how pj-affected-tests calls it -- a test-less
# Makefile sorting last must not turn into a failed command substitution.
# bash clears -e inside $(...), so this one has to run under sh to mean
# anything.
lastless="$fixture_root/lastless"
suite "$lastless/api"
mkdir -p "$lastless/zdocs"
printf 'html:\n\t@true\n' > "$lastless/zdocs/Makefile"
assert_ok "find_suites succeeds under sh -eu when the last Makefile has no test target" \
	sh -c 'set -eu; . "$1"; cd "$2"; found="$(pj_gate_find_suites)"; [ "$found" = api ]' _ \
	"$DOTFILES_HOME/agents/lib/gate.sh" "$lastless"

# The scripts that use the lib don't keep copies of their own.
for script in bin/pj-run-issues bin/pj-affected-tests bin/pj-stack-verify; do
	assert_eq "" "$(grep -n -E '^(has_test_target|is_pruned|shell_word|every_suite)\(\)|^PRUNED=' "$DOTFILES_HOME/$script" || true)" \
		"$script defines no gate helper of its own"
done

# --- resolve ---

proj="$fixture_root/explicit"
mkdir -p "$proj"
resolve_in "$proj" "make lint test"
assert_exit_code 0 "$rc" "an explicit command always resolves"
assert_eq "make lint test" "$cmd" "an explicit command is used as given"

proj="$fixture_root/pjtest"
suite "$proj"
mkdir -p "$proj/.pj"
printf '#!/bin/sh\nexit 0\n' > "$proj/.pj/test"
chmod +x "$proj/.pj/test"
resolve_in "$proj"
assert_eq "./.pj/test" "$cmd" "an executable .pj/test wins over make test"

chmod -x "$proj/.pj/test"
resolve_in "$proj"
assert_exit_code 1 "$rc" "a non-executable .pj/test is refused, not skipped"
assert_contains "$err" "chmod +x" "the refusal says to make it executable"

proj="$fixture_root/root-make"
suite "$proj"
suite "$proj/backend"
resolve_in "$proj"
assert_eq "make test" "$cmd" "a root test target resolves to make test"

proj="$fixture_root/one-below"
suite "$proj/backend"
resolve_in "$proj"
assert_eq "make -C backend test" "$cmd" "a single suite below the root resolves to make -C"

proj="$fixture_root/spaced"
suite "$proj/my app"
resolve_in "$proj"
assert_eq "make -C 'my app' test" "$cmd" "a directory with a space is quoted for sh -c"

proj="$fixture_root/none"
mkdir -p "$proj"
resolve_in "$proj"
assert_exit_code 1 "$rc" "no gate at all is refused"
assert_contains "$err" "executable .pj/test" "the refusal names .pj/test as a way to supply one"
assert_contains "$err" "--test-cmd" "and --test-cmd"

proj="$fixture_root/several"
suite "$proj/api"
suite "$proj/web"
resolve_in "$proj"
assert_exit_code 1 "$rc" "several suites below the root are refused as ambiguous"
assert_contains "$err" "commit an executable .pj/test" "the refusal says how to choose"
assert_contains "$err" "  api" "and lists the candidates"
assert_contains "$err" "  web" "all of them"

assert_report
