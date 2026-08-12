#!/bin/bash
# pj_sbx_list_test.sh
#
# Plain-shell tests for bin/pj-sbx-list's `--help`/`-h` (issue 007): must
# print the script's own header comment as usage and exit 0 without
# performing its normal listing (no `sandbox_list_entries` output, no "no
# sandboxes found"), regardless of whether any sandboxes exist under
# SANDBOX_WORKTREE_ROOT.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"
DOTFILES_HOME="$(cd -P "$SANDBOX_DIR/.." && pwd)"
LIST="$DOTFILES_HOME/bin/pj-sbx-list"

failures=0

sandbox_worktree_root="$(mktemp -d)"

run_list() {
	if list_output="$(SANDBOX_WORKTREE_ROOT="$sandbox_worktree_root" "$LIST" "$@" 2>&1)"; then
		list_rc=0
	else
		list_rc=$?
	fi
}

for help_flag in --help -h; do
	run_list "$help_flag"

	if [ "$list_rc" -eq 0 ]; then
		echo "PASS: pj-sbx-list $help_flag exits 0"
	else
		echo "FAIL: pj-sbx-list $help_flag exits 0 (got exit $list_rc, output: $list_output)"
		failures=$((failures + 1))
	fi

	case "$list_output" in
	*"pj-sbx-list"*"Usage: pj-sbx-list"*) echo "PASS: pj-sbx-list $help_flag prints its header comment as usage" ;;
	*) echo "FAIL: pj-sbx-list $help_flag prints its header comment as usage (got: $list_output)"; failures=$((failures + 1)) ;;
	esac

	case "$list_output" in
	*"no sandboxes found"*) echo "FAIL: pj-sbx-list $help_flag does not perform its normal listing"; failures=$((failures + 1)) ;;
	*) echo "PASS: pj-sbx-list $help_flag does not perform its normal listing" ;;
	esac
done

rm -rf "$sandbox_worktree_root"

echo "$failures failure(s)"
[ "$failures" -eq 0 ]
