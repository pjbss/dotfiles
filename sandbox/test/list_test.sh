#!/bin/bash
# list_test.sh
#
# Plain-shell unit tests for sandbox/lib/list.sh (sandbox discovery/status
# correlation for `pj-sandbox-list`). No test framework dependency,
# same minimal assert style as task_test.sh.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"

. "$SANDBOX_DIR/lib/list.sh"

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

fixture_root="$(mktemp -d)"

# --- empty state ---

empty_output="$(sandbox_list_entries "$fixture_root")"
assert_eq "" "$empty_output" "sandbox_list_entries prints nothing when no sandboxes are known"

# --- one sandbox, running ---

mkdir -p "$fixture_root/myrepo/lima-configs" "$fixture_root/myrepo/worktrees/fix-thing"
touch "$fixture_root/myrepo/lima-configs/fix-thing.yaml"

limactl() {
	echo '{"name":"fix-thing","status":"Running","sshLocalPort":60022}'
}

one_output="$(sandbox_list_entries "$fixture_root")"
assert_eq "$(printf 'fix-thing\t%s/myrepo/worktrees/fix-thing\tRunning' "$fixture_root")" "$one_output" \
	"sandbox_list_entries reports task name, worktree path, and live status for a running sandbox"

unset -f limactl

# --- one sandbox, not reported by limactl at all ---

limactl() {
	echo ""
}

stopped_output="$(sandbox_list_entries "$fixture_root")"
assert_eq "$(printf 'fix-thing\t%s/myrepo/worktrees/fix-thing\tstopped' "$fixture_root")" "$stopped_output" \
	"sandbox_list_entries falls back to 'stopped' when limactl has no record of the instance"

unset -f limactl

# --- two sandboxes, one running, one already torn down/stopped ---

mkdir -p "$fixture_root/myrepo/worktrees/other-task"
touch "$fixture_root/myrepo/lima-configs/other-task.yaml"

limactl() {
	echo '{"name":"fix-thing","status":"Running","sshLocalPort":60022}'
}

two_output="$(sandbox_list_entries "$fixture_root" | sort)"
expected_two="$(printf 'fix-thing\t%s/myrepo/worktrees/fix-thing\tRunning\nother-task\t%s/myrepo/worktrees/other-task\tstopped' \
	"$fixture_root" "$fixture_root" | sort)"
assert_eq "$expected_two" "$two_output" \
	"sandbox_list_entries lists multiple sandboxes independently, each with its own status"

unset -f limactl

# --- a torn-down sandbox whose config artifact is removed disappears entirely ---

rm -f "$fixture_root/myrepo/lima-configs/other-task.yaml"

limactl() {
	echo '{"name":"fix-thing","status":"Running","sshLocalPort":60022}'
}

after_removal_output="$(sandbox_list_entries "$fixture_root")"
assert_eq "$(printf 'fix-thing\t%s/myrepo/worktrees/fix-thing\tRunning' "$fixture_root")" "$after_removal_output" \
	"sandbox_list_entries no longer lists a sandbox once its config artifact is removed"

unset -f limactl

rm -rf "$fixture_root"
echo "$failures failure(s)"
[ "$failures" -eq 0 ]
