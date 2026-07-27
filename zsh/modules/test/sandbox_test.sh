#!/bin/bash
# sandbox_test.sh
#
# Plain-shell tests for zsh/modules/sandbox.zsh, matching the assert style
# already used in sandbox/test/*.sh. Most of sandbox.zsh is one-line alias
# delegation (spawn/list/teardown -> bin/dotfiles-sandbox-*); sbx-ssh is the
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

assert_eq "alias sbx-spawn='dotfiles-sandbox-spawn'" "$(alias sbx-spawn)" \
	"sbx-spawn delegates to dotfiles-sandbox-spawn"

assert_eq "alias sbx-list='dotfiles-sandbox-list'" "$(alias sbx-list)" \
	"sbx-list delegates to dotfiles-sandbox-list"

assert_eq "alias sbx-teardown='dotfiles-sandbox-teardown'" "$(alias sbx-teardown)" \
	"sbx-teardown delegates to dotfiles-sandbox-teardown"

# --- sbx-ssh ---

# Stub `ssh` as a shell function so sbx-ssh's connection attempt is
# captured instead of really dialing out.
SSH_CALL_LOG="$(mktemp)"
ssh() {
	echo "$*" > "$SSH_CALL_LOG"
}

sbx-ssh 'My Task'
assert_eq "my-task" "$(cat "$SSH_CALL_LOG")" \
	"sbx-ssh resolves the task name to the same slug spawn/teardown use before invoking ssh"

rm -f "$SSH_CALL_LOG"

echo "$failures failure(s)"
[ "$failures" -eq 0 ]
