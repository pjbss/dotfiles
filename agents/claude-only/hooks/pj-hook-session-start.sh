#!/bin/sh
# pj-hook-session-start.sh
#
# SessionStart hook. Anything it prints on stdout is added to the session's
# context, so this answers the questions a fresh session in a spawned VM would
# otherwise have to burn several tool calls discovering: am I in a sandbox,
# what does this project use to run its tests, and what's left in the issue
# queue.
#
# Kept deliberately short. It's prepended to every single session, so a long
# preamble here is a standing tax on context that grows more expensive the more
# sessions are run unattended.
#
# Exits 0 always: a SessionStart hook cannot usefully block, and failing to
# describe the repo is never a reason to refuse to start work in it.

set -eu

# The payload carries `cwd`, which is where the session actually is -- not
# necessarily where this script was invoked from.
cwd="$(cat | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("cwd", ""))
except Exception:
    print("")
' 2>/dev/null || true)"

[ -n "$cwd" ] && cd "$cwd" 2>/dev/null || true

if [ -f "${PJ_SANDBOX_MARKER:-/etc/pj-sandbox}" ]; then
	echo "Environment: inside a pj sandbox VM. /workspace is the task's git worktree."
	echo "Commit here; never push (sandboxes hold no push credentials, and the guard hook blocks it)."
	echo "Write only under /workspace."
fi

if [ -f Makefile ] && grep -q '^test:' Makefile 2>/dev/null; then
	echo "Tests: run 'make test'. It is the contract -- hooks and the autonomous issue loop both call it."
fi

if [ -d issues ] && command -v pj-issues >/dev/null 2>&1; then
	pj-issues status 2>/dev/null || true
fi

exit 0
