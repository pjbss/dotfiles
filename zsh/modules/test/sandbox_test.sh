#!/bin/bash
# sandbox_test.sh
#
# Plain-shell tests for zsh/modules/sandbox.zsh, matching the assert style
# already used in sandbox/test/*.sh. sandbox.zsh defines exactly one
# function, pj-sbx-ssh (resolving a free-text task name to the same slug
# spawn/teardown use before invoking `ssh`), so that's what's tested here.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
MODULES_DIR="$(cd -P "$TEST_DIR/.." && pwd)"
export DOTFILES_HOME="$(cd -P "$MODULES_DIR/../.." && pwd)"

. "$MODULES_DIR/sandbox.zsh"

failures=0

assert_eq() {
	expected="$1"
	actual="$2"
	message="$3"

	if [ "$expected" != "$actual" ]; then
		echo "FAIL: $message (expected '$expected', got '$actual')"
		failures=$((failures + 1))
	else
		echo "PASS: $message"
	fi
}

# --- pj-sbx-ssh ---

# Stub `ssh` as a shell function so pj-sbx-ssh's connection attempt is
# captured instead of really dialing out.
SSH_CALL_LOG="$(mktemp)"
ssh() {
	echo "$*" > "$SSH_CALL_LOG"
}

pj-sbx-ssh 'My Task'
assert_eq '-t my-task cd /workspace && exec "$SHELL" -l' "$(cat "$SSH_CALL_LOG")" \
	"pj-sbx-ssh resolves the task name to the same slug spawn/teardown use before invoking ssh, and lands the session in /workspace"

rm -f "$SSH_CALL_LOG"

echo "$failures failure(s)"
[ "$failures" -eq 0 ]
