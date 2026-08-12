#!/bin/bash
# pj_sbx_teardown_test.sh
#
# Plain-shell tests for bin/pj-sbx-teardown's `--help`/`-h` (issue 007):
# must print the script's own header comment as usage and exit 0 without
# performing any teardown -- no `limactl stop`/`delete` attempted, and no
# existing render artifact removed. Also confirms `--help` short-circuits
# before the "must be run from inside a git repository" check, since a
# real teardown always needs one but `--help` never should.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"
DOTFILES_HOME="$(cd -P "$SANDBOX_DIR/.." && pwd)"
TEARDOWN="$DOTFILES_HOME/bin/pj-sbx-teardown"

failures=0

# A plain tmpdir, deliberately NOT a git repository -- a real teardown
# would fail fast here; --help must never reach that check at all.
non_repo_dir="$(mktemp -d)"

sandbox_worktree_root="$(mktemp -d)"
mkdir -p "$sandbox_worktree_root/myrepo/lima-configs"
fixture_config="$sandbox_worktree_root/myrepo/lima-configs/fixture-task.yaml"
touch "$fixture_config"

run_teardown() {
	if teardown_output="$(cd "$non_repo_dir" && SANDBOX_WORKTREE_ROOT="$sandbox_worktree_root" "$TEARDOWN" "$@" 2>&1)"; then
		teardown_rc=0
	else
		teardown_rc=$?
	fi
}

for help_flag in --help -h; do
	run_teardown "$help_flag"

	if [ "$teardown_rc" -eq 0 ]; then
		echo "PASS: pj-sbx-teardown $help_flag exits 0 (even outside a git repository)"
	else
		echo "FAIL: pj-sbx-teardown $help_flag exits 0 (got exit $teardown_rc, output: $teardown_output)"
		failures=$((failures + 1))
	fi

	case "$teardown_output" in
	*"pj-sbx-teardown"*"Usage: pj-sbx-teardown"*) echo "PASS: pj-sbx-teardown $help_flag prints its header comment as usage" ;;
	*) echo "FAIL: pj-sbx-teardown $help_flag prints its header comment as usage (got: $teardown_output)"; failures=$((failures + 1)) ;;
	esac

	if [ -e "$fixture_config" ]; then
		echo "PASS: pj-sbx-teardown $help_flag leaves an existing render artifact untouched"
	else
		echo "FAIL: pj-sbx-teardown $help_flag leaves an existing render artifact untouched"
		failures=$((failures + 1))
	fi
done

# fixture-task --help: --help must win even with a task-name argument
# present.
run_teardown fixture-task --help
if [ "$teardown_rc" -eq 0 ]; then
	echo "PASS: pj-sbx-teardown <task-name> --help exits 0"
else
	echo "FAIL: pj-sbx-teardown <task-name> --help exits 0 (got exit $teardown_rc, output: $teardown_output)"
	failures=$((failures + 1))
fi

if [ -e "$fixture_config" ]; then
	echo "PASS: pj-sbx-teardown <task-name> --help leaves an existing render artifact untouched"
else
	echo "FAIL: pj-sbx-teardown <task-name> --help leaves an existing render artifact untouched"
	failures=$((failures + 1))
fi

rm -rf "$non_repo_dir" "$sandbox_worktree_root"

echo "$failures failure(s)"
[ "$failures" -eq 0 ]
