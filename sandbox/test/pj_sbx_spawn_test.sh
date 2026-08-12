#!/bin/bash
# pj_sbx_spawn_test.sh
#
# Plain-shell tests for bin/pj-sbx-spawn's `--base <name>` validation
# (issue 003), `--base list` (issue 004), `--ports <list>` validation
# (issue 005), and `--help`/`-h` (issue 007): missing/unrecognized `--base`
# or a non-numeric `--ports` value must all fail fast, before any git
# branch/worktree/VM gets created, and `--base list` must enumerate
# sandbox/templates/ live rather than a hardcoded name set. Actually
# allocating/forwarding ports
# (sandbox_allocate_ports) is covered at the unit level in task_test.sh --
# a successful `--ports` spawn needs a real `limactl start`, which the
# PRD's Testing Decisions deliberately leave untested by automation here
# too. Runs the real script as a subprocess against a real,
# throwaway git repo under a tmpdir -- same real-git-repo approach as
# worktree_test.sh -- rather than exercising the rest of the spawn flow
# (worktree creation, `limactl start`, SSH bootstrap), which the PRD's
# Testing Decisions deliberately leave untested by automation (no real
# Lima VM boots in CI). The `--base list` template-discovery case is the
# one exception that touches the real sandbox/templates/ directory (a
# throwaway fixture file, removed via `trap` even on failure) rather than
# a fixture dir, since that's the actual directory issue 004 requires it
# to enumerate.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"
DOTFILES_HOME="$(cd -P "$SANDBOX_DIR/.." && pwd)"
SPAWN="$DOTFILES_HOME/bin/pj-sbx-spawn"

failures=0

fixture_repo="$(mktemp -d)"
fixture_repo="$(cd -P "$fixture_repo" && pwd)"
git -C "$fixture_repo" init -q
git -C "$fixture_repo" -c user.email=test@example.com -c user.name=test commit -q --allow-empty -m init

# Isolated from the real $HOME even though neither case below should ever
# reach the point where this is read.
sandbox_worktree_root="$(mktemp -d)"

run_spawn() {
	if spawn_output="$(cd "$fixture_repo" && SANDBOX_WORKTREE_ROOT="$sandbox_worktree_root" "$SPAWN" "$@" 2>&1)"; then
		spawn_rc=0
	else
		spawn_rc=$?
	fi
}

assert_no_worktree_created() {
	message="$1"

	worktree_count="$(git -C "$fixture_repo" worktree list | wc -l | tr -d ' ')"
	if [ "$worktree_count" = "1" ]; then
		echo "PASS: $message"
	else
		echo "FAIL: $message (worktree list has $worktree_count entries, expected just the main one)"
		failures=$((failures + 1))
	fi
}

# --- task name omitted entirely ---

run_spawn

if [ "$spawn_rc" -ne 0 ]; then
	echo "PASS: pj-sbx-spawn exits non-zero when the task name is omitted"
else
	echo "FAIL: pj-sbx-spawn exits non-zero when the task name is omitted"
	failures=$((failures + 1))
fi

case "$spawn_output" in
*--ports*) echo "PASS: pj-sbx-spawn's missing-task-name usage mentions --ports" ;;
*) echo "FAIL: pj-sbx-spawn's missing-task-name usage mentions --ports (got: $spawn_output)"; failures=$((failures + 1)) ;;
esac

for expected_name in $(ls -1 "$DOTFILES_HOME/sandbox/templates"); do
	case "$spawn_output" in
	*"$expected_name"*) echo "PASS: pj-sbx-spawn's missing-task-name usage lists --base name '$expected_name'" ;;
	*) echo "FAIL: pj-sbx-spawn's missing-task-name usage lists --base name '$expected_name' (got: $spawn_output)"; failures=$((failures + 1)) ;;
	esac
done

assert_no_worktree_created "pj-sbx-spawn creates no worktree when the task name is omitted"

# --- --base omitted entirely ---

run_spawn missing-base-task

if [ "$spawn_rc" -ne 0 ]; then
	echo "PASS: pj-sbx-spawn exits non-zero when --base is omitted"
else
	echo "FAIL: pj-sbx-spawn exits non-zero when --base is omitted"
	failures=$((failures + 1))
fi

case "$spawn_output" in
*--base*) echo "PASS: pj-sbx-spawn's missing-'--base' error mentions --base" ;;
*) echo "FAIL: pj-sbx-spawn's missing-'--base' error mentions --base (got: $spawn_output)"; failures=$((failures + 1)) ;;
esac

assert_no_worktree_created "pj-sbx-spawn creates no worktree when --base is omitted"

# --- --base given an unrecognized value ---

run_spawn bogus-base-task --base bogus-name

if [ "$spawn_rc" -ne 0 ]; then
	echo "PASS: pj-sbx-spawn exits non-zero for an unrecognized --base value"
else
	echo "FAIL: pj-sbx-spawn exits non-zero for an unrecognized --base value"
	failures=$((failures + 1))
fi

case "$spawn_output" in
*bogus-name*python3.12*|*bogus-name*"none"*) echo "PASS: pj-sbx-spawn's unrecognized-'--base' error lists the valid names" ;;
*) echo "FAIL: pj-sbx-spawn's unrecognized-'--base' error lists the valid names (got: $spawn_output)"; failures=$((failures + 1)) ;;
esac

assert_no_worktree_created "pj-sbx-spawn creates no worktree for an unrecognized --base value"

# --- --base given a comma-separated/multi-value name ---

run_spawn multi-base-task --base python3.12,node20

if [ "$spawn_rc" -ne 0 ]; then
	echo "PASS: pj-sbx-spawn rejects a comma-separated/multi-value --base"
else
	echo "FAIL: pj-sbx-spawn rejects a comma-separated/multi-value --base"
	failures=$((failures + 1))
fi

assert_no_worktree_created "pj-sbx-spawn creates no worktree for a comma-separated/multi-value --base"

# --- --ports given a non-numeric value (issue 005) ---

run_spawn bad-ports-task --base none --ports 8000,not-a-port

if [ "$spawn_rc" -ne 0 ]; then
	echo "PASS: pj-sbx-spawn exits non-zero for a non-numeric --ports value"
else
	echo "FAIL: pj-sbx-spawn exits non-zero for a non-numeric --ports value"
	failures=$((failures + 1))
fi

case "$spawn_output" in
*--ports*) echo "PASS: pj-sbx-spawn's invalid-'--ports' error mentions --ports" ;;
*) echo "FAIL: pj-sbx-spawn's invalid-'--ports' error mentions --ports (got: $spawn_output)"; failures=$((failures + 1)) ;;
esac

assert_no_worktree_created "pj-sbx-spawn creates no worktree for a non-numeric --ports value"

# --- --base list (issue 004) ---

run_spawn --base list

if [ "$spawn_rc" -eq 0 ]; then
	echo "PASS: pj-sbx-spawn --base list exits 0"
else
	echo "FAIL: pj-sbx-spawn --base list exits 0 (got exit $spawn_rc, output: $spawn_output)"
	failures=$((failures + 1))
fi

for expected_name in python3.12 python3.14 none; do
	case "$spawn_output" in
	*"$expected_name"*) echo "PASS: pj-sbx-spawn --base list includes '$expected_name'" ;;
	*) echo "FAIL: pj-sbx-spawn --base list includes '$expected_name' (got: $spawn_output)"; failures=$((failures + 1)) ;;
	esac
done

assert_no_worktree_created "pj-sbx-spawn --base list creates no worktree"

# --base list needs no task name at all -- run_spawn above already covered
# that (its only argument is --base list), but confirm explicitly that
# omitting a task name doesn't fall into the "usage: ..." error path.
case "$spawn_output" in
*usage:*) echo "FAIL: pj-sbx-spawn --base list does not require a task-name argument (got: $spawn_output)"; failures=$((failures + 1)) ;;
*) echo "PASS: pj-sbx-spawn --base list does not require a task-name argument" ;;
esac

# --- --base list picks up a new template file with no code change ---

real_templates_dir="$SANDBOX_DIR/templates"
fixture_template_name="__pj_sbx_spawn_test_fixture_template__"
trap 'rm -f "$real_templates_dir/$fixture_template_name"' EXIT

touch "$real_templates_dir/$fixture_template_name"

run_spawn --base list

case "$spawn_output" in
*"$fixture_template_name"*) echo "PASS: pj-sbx-spawn --base list picks up a newly-added sandbox/templates/ file with no code change" ;;
*) echo "FAIL: pj-sbx-spawn --base list picks up a newly-added sandbox/templates/ file with no code change (got: $spawn_output)"; failures=$((failures + 1)) ;;
esac

rm -f "$real_templates_dir/$fixture_template_name"
trap - EXIT

# --- --help also picks up a new template file with no code change ---

trap 'rm -f "$real_templates_dir/$fixture_template_name"' EXIT

touch "$real_templates_dir/$fixture_template_name"

run_spawn --help

case "$spawn_output" in
*"$fixture_template_name"*) echo "PASS: pj-sbx-spawn --help lists a newly-added sandbox/templates/ file with no code change" ;;
*) echo "FAIL: pj-sbx-spawn --help lists a newly-added sandbox/templates/ file with no code change (got: $spawn_output)"; failures=$((failures + 1)) ;;
esac

rm -f "$real_templates_dir/$fixture_template_name"
trap - EXIT

# --- --help / -h (issue 007) ---

for help_flag in --help -h; do
	run_spawn "$help_flag"

	if [ "$spawn_rc" -eq 0 ]; then
		echo "PASS: pj-sbx-spawn $help_flag exits 0"
	else
		echo "FAIL: pj-sbx-spawn $help_flag exits 0 (got exit $spawn_rc, output: $spawn_output)"
		failures=$((failures + 1))
	fi

	case "$spawn_output" in
	*"pj-sbx-spawn"*"Usage: pj-sbx-spawn"*) echo "PASS: pj-sbx-spawn $help_flag prints its header comment as usage" ;;
	*) echo "FAIL: pj-sbx-spawn $help_flag prints its header comment as usage (got: $spawn_output)"; failures=$((failures + 1)) ;;
	esac

	case "$spawn_output" in
	*"--ports"*) echo "PASS: pj-sbx-spawn $help_flag documents --ports" ;;
	*) echo "FAIL: pj-sbx-spawn $help_flag documents --ports (got: $spawn_output)"; failures=$((failures + 1)) ;;
	esac

	for expected_name in $(ls -1 "$DOTFILES_HOME/sandbox/templates"); do
		case "$spawn_output" in
		*"$expected_name"*) echo "PASS: pj-sbx-spawn $help_flag lists --base name '$expected_name'" ;;
		*) echo "FAIL: pj-sbx-spawn $help_flag lists --base name '$expected_name' (got: $spawn_output)"; failures=$((failures + 1)) ;;
		esac
	done

	assert_no_worktree_created "pj-sbx-spawn $help_flag creates no worktree"
done

# --help must win no matter where it appears among other flags/arguments.
run_spawn --help --base python3.12
if [ "$spawn_rc" -eq 0 ]; then
	echo "PASS: pj-sbx-spawn --help (first, with other flags present) exits 0"
else
	echo "FAIL: pj-sbx-spawn --help (first, with other flags present) exits 0 (got exit $spawn_rc)"
	failures=$((failures + 1))
fi
assert_no_worktree_created "pj-sbx-spawn --help (first, with other flags present) creates no worktree"

run_spawn some-task --base python3.12 --help
if [ "$spawn_rc" -eq 0 ]; then
	echo "PASS: pj-sbx-spawn --help (last, after task name and --base) exits 0"
else
	echo "FAIL: pj-sbx-spawn --help (last, after task name and --base) exits 0 (got exit $spawn_rc)"
	failures=$((failures + 1))
fi
assert_no_worktree_created "pj-sbx-spawn --help (last, after task name and --base) creates no worktree"

rm -rf "$fixture_repo" "$sandbox_worktree_root"

echo "$failures failure(s)"
[ "$failures" -eq 0 ]
