#!/bin/sh
# pj-hook-stop-tests.sh
#
# Stop hook. Refuses to let a session finish while `make test` is red: exit 2
# prevents the stop and hands the failure output back to the model, so it keeps
# working instead of reporting done over a broken suite.
#
# This is the gate that makes an unattended run trustworthy. Everything else in
# the loop is about *what* gets built; this is the one thing standing between
# "the agent said it finished" and "the tests actually pass".
#
# Opt-in via PJ_STOP_TESTS=1, which bin/pj-run-issues sets for its own child
# processes. It must not be on by default for interactive sessions: holding a
# person's session hostage over a test that was already failing when they sat
# down -- or one unrelated to what they just asked about -- is how a safety gate
# earns itself a permanent `disableAllHooks`.
#
# The suite is the one in PJ_TEST_DIR when pj-run-issues set it, and otherwise
# the one in the session's own working directory. Those differ in a monorepo,
# where the agent works from the project root but the Makefile belongs to a
# subproject -- and without PJ_TEST_DIR the hook would find no Makefile there
# and skip, quietly leaving an unattended run with no gate at all.
#
# A project with no `make test` target is silently skipped rather than treated
# as passing or failing, since this hook is synced to every project.

set -eu

[ "${PJ_STOP_TESTS:-}" = "1" ] || exit 0

cwd="$(cat | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("cwd", ""))
except Exception:
    print("")
' 2>/dev/null || true)"

gate_dir="${PJ_TEST_DIR:-$cwd}"

# Skipping beats falling back to whatever directory this hook happens to have
# been started in: a `make test` run against the wrong project would gate the
# session on a suite that never sees the code it wrote.
[ -z "$gate_dir" ] || cd "$gate_dir" 2>/dev/null || exit 0

[ -f Makefile ] || exit 0
grep -q '^test:' Makefile 2>/dev/null || exit 0

# Guards against a Stop hook that re-runs the suite on the model's own
# post-failure stop, over and over. One retry is the useful amount: it gives
# the model a chance to fix what it broke, without letting a genuinely
# unfixable failure spin.
attempt_marker="${TMPDIR:-/tmp}/pj-stop-tests-$(printf '%s' "$gate_dir" | tr -c 'A-Za-z0-9' '-')"

if output="$(make test 2>&1)"; then
	rm -f "$attempt_marker"
	exit 0
fi

if [ -f "$attempt_marker" ]; then
	rm -f "$attempt_marker"
	echo "pj-hook-stop-tests: 'make test' is still failing after a retry -- letting the session stop so this doesn't loop. The suite is RED; do not treat this work as finished." >&2
	exit 0
fi

: > "$attempt_marker"

{
	echo "pj-hook-stop-tests: 'make test' is failing -- not finishing yet."
	echo
	printf '%s\n' "$output" | tail -40
	echo
	echo "Fix the failures above, then stop. If a failure is pre-existing and unrelated to this work, say so explicitly rather than leaving it unmentioned."
} >&2

exit 2
