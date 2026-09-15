#!/bin/bash
# pj_issues_test.sh
#
# Integration tests for the bin/pj-issues command: argument handling, exit
# codes, and output shape. The parsing rules themselves are covered by
# issues_test.sh against agents/lib/issues.sh directly -- what matters here is
# the contract the autonomous loop depends on, above all `next` exiting
# non-zero (rather than printing nothing and exiting 0) when the queue is
# drained, since that's the loop's only termination signal.
#
# Every invocation points $PJ_ISSUES_DIR at a tmpdir, so no real issue tree is
# read and $HOME is never touched.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
DOTFILES_HOME="$(cd -P "$TEST_DIR/../.." && pwd)"

. "$DOTFILES_HOME/test/assert.sh"

PJ_ISSUES="$DOTFILES_HOME/bin/pj-issues"

fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

write_issue() {
	mkdir -p "$1"
	cat > "$1/$2" <<-EOF
		## Parent PRD

		\`issues/prd.md\`

		## What to build

		Thing.

		## Acceptance criteria

		${4:-- [ ] It works}

		## Blocked by

		$3

		## User stories addressed

		- User story 1
	EOF
}

# run_pj_issues DIR ARGS...
#
# Runs the command with color disabled and stderr folded into stdout, leaving
# the output in $out and the exit code in $rc. Captured this way because
# `set -e` would otherwise abort the test file on the first non-zero exit --
# and several of these assertions are specifically about non-zero exits.
run_pj_issues() {
	local dir="$1"
	shift

	if out="$(NO_COLOR=1 PJ_ISSUES_DIR="$dir" "$PJ_ISSUES" "$@" 2>&1)"; then
		rc=0
	else
		rc=$?
	fi
}

# --- help works without an issues directory ---

run_pj_issues "$fixture_root/nonexistent" --help
assert_exit_code 0 "$rc" "--help succeeds even when the issues directory doesn't exist"
assert_contains "$out" "Usage: pj-issues" "--help prints usage read from the script's own header comment"

# --- a missing issues directory is a clear error, not a crash ---

run_pj_issues "$fixture_root/nonexistent" list
assert_exit_code 1 "$rc" "a missing issues directory exits 1"
assert_contains "$out" "no issues directory" "a missing issues directory says so"
assert_contains "$out" "pj-write-prd" "a missing issues directory points at the skill that creates one"

# --- unknown subcommand ---

tree="$fixture_root/tree"
write_issue "$tree" "001-alpha.md" "None - can start immediately"
write_issue "$tree" "002-beta.md" "- Blocked by \`issues/001-alpha.md\`"

run_pj_issues "$tree" frobnicate
assert_exit_code 1 "$rc" "an unknown subcommand exits 1"
assert_contains "$out" "unknown command 'frobnicate'" "an unknown subcommand names what wasn't understood"

# --- next ---

run_pj_issues "$tree" next
assert_exit_code 0 "$rc" "next exits 0 when an issue is ready"
assert_eq "$tree/001-alpha.md" "$out" "next prints the full path of the ready issue"

# --- list ---

run_pj_issues "$tree" list
assert_exit_code 0 "$rc" "list exits 0"
assert_contains "$out" "ready    001-alpha.md" "list marks an unblocked issue ready"
assert_contains "$out" "blocked  002-beta.md (on 001)" "list names the issue number a blocked issue is waiting on"

# --- default subcommand is list ---

run_pj_issues "$tree"
assert_exit_code 0 "$rc" "running with no subcommand exits 0"
assert_contains "$out" "001-alpha.md" "running with no subcommand defaults to list"

# --- graph ---

run_pj_issues "$tree" graph
assert_contains "$out" "graph TD" "graph emits a Mermaid graph header"
assert_contains "$out" "001 --> 002" "graph draws an edge from blocker to blocked issue"

# --- validate on a clean tree ---

run_pj_issues "$tree" validate
assert_exit_code 0 "$rc" "validate exits 0 on a well-formed tree"
assert_contains "$out" "issues: ok" "validate says so on a clean tree"

# --- validate on a broken tree ---

broken="$fixture_root/broken"
write_issue "$broken" "001-dangling.md" "- Blocked by \`issues/077-ghost.md\`"

run_pj_issues "$broken" validate
assert_exit_code 1 "$rc" "validate exits 1 when a blocker points at a nonexistent issue"
assert_contains "$out" "077-ghost.md" "validate names the missing blocker"

# --- the drained-queue signal the loop relies on ---

drained="$fixture_root/drained"
write_issue "$drained/done" "001-alpha.md" "None - can start immediately" "- [x] It works"

run_pj_issues "$drained" next
assert_exit_code 1 "$rc" "next exits 1 once every issue is done -- the loop's termination signal"
assert_eq "" "$out" "next prints nothing when the queue is drained"

run_pj_issues "$drained" status
assert_exit_code 0 "$rc" "status still exits 0 on a drained queue"
assert_contains "$out" "0 ready" "status reports an empty ready queue"
assert_contains "$out" "1 done" "status counts completed issues"
assert_not_contains "$out" "next up" "status omits the next-up line when nothing is ready"

assert_report
