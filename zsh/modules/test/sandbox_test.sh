#!/bin/bash
# sandbox_test.sh
#
# Plain-shell tests for zsh/modules/sandbox.zsh, matching the assert style
# already used in sandbox/test/*.sh. Most of sandbox.zsh is one-line alias
# delegation (spawn/list/teardown -> bin/pj-sandbox-*); pj-sbx-ssh is the
# one alias with real logic (resolving a free-text task name to the same
# slug spawn/teardown use before invoking `ssh`), so that's what's actually
# worth unit-testing here.

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

# --- alias delegation ---

assert_eq "alias pj-sbx-spawn='pj-sandbox-spawn'" "$(alias pj-sbx-spawn)" \
	"pj-sbx-spawn delegates to pj-sandbox-spawn"

assert_eq "alias pj-sbx-list='pj-sandbox-list'" "$(alias pj-sbx-list)" \
	"pj-sbx-list delegates to pj-sandbox-list"

assert_eq "alias pj-sbx-teardown='pj-sandbox-teardown'" "$(alias pj-sbx-teardown)" \
	"pj-sbx-teardown delegates to pj-sandbox-teardown"

# --- pj-sbx-ssh ---

# Stub `ssh` as a shell function so pj-sbx-ssh's connection attempt is
# captured instead of really dialing out.
SSH_CALL_LOG="$(mktemp)"
ssh() {
	echo "$*" > "$SSH_CALL_LOG"
}

pj-sbx-ssh 'My Task'
assert_eq "my-task" "$(cat "$SSH_CALL_LOG")" \
	"pj-sbx-ssh resolves the task name to the same slug spawn/teardown use before invoking ssh"

rm -f "$SSH_CALL_LOG"

echo "$failures failure(s)"
[ "$failures" -eq 0 ]
