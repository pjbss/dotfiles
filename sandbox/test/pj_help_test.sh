#!/bin/bash
# pj_help_test.sh
#
# Plain-shell tests for bin/pj-help (issue 008): indexes every
# `pj-`-prefixed sandbox command with a one-line description derived from
# its own header/doc comment, scoped strictly to the `pj-` namespace, and
# picks up a newly-added `pj-`-prefixed bin/ command with no code change.
# Runs the real script as a subprocess, same convention as
# pj_sbx_spawn_test.sh.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"
DOTFILES_HOME="$(cd -P "$SANDBOX_DIR/.." && pwd)"
PJ_HELP="$DOTFILES_HOME/bin/pj-help"

failures=0

if help_output="$("$PJ_HELP" 2>&1)"; then
	help_rc=0
else
	help_rc=$?
fi

if [ "$help_rc" -eq 0 ]; then
	echo "PASS: pj-help exits 0"
else
	echo "FAIL: pj-help exits 0 (got exit $help_rc, output: $help_output)"
	failures=$((failures + 1))
fi

# --- one line per real pj-* command, each with a non-empty description ---

for expected_name in pj-sbx-spawn pj-sbx-list pj-sbx-teardown pj-sbx-ssh pj-help; do
	line="$(echo "$help_output" | awk -v n="$expected_name" '$1 == n')"
	if [ -n "$line" ]; then
		echo "PASS: pj-help lists '$expected_name'"
	else
		echo "FAIL: pj-help lists '$expected_name' (got: $help_output)"
		failures=$((failures + 1))
	fi

	description="$(echo "$line" | awk -v n="$expected_name" '$1 == n { $1 = ""; print }' | sed -E 's/^ +//')"
	if [ -n "$description" ]; then
		echo "PASS: pj-help gives '$expected_name' a non-empty description"
	else
		echo "FAIL: pj-help gives '$expected_name' a non-empty description (got: $help_output)"
		failures=$((failures + 1))
	fi
done

# --- no non-pj- alias ever appears ---

for non_pj_name in l la 'reload!' 'time!'; do
	if echo "$help_output" | awk -v n="$non_pj_name" '$1 == n' | grep -q .; then
		echo "FAIL: pj-help does not list non-pj- alias '$non_pj_name' (got: $help_output)"
		failures=$((failures + 1))
	else
		echo "PASS: pj-help does not list non-pj- alias '$non_pj_name'"
	fi
done

# --- adding a new pj--prefixed bin/ command with its own header comment
# is picked up with no change to pj-help itself ---

real_bin_dir="$DOTFILES_HOME/bin"
fixture_command_name="pj-__pj_help_test_fixture_command__"
fixture_command_path="$real_bin_dir/$fixture_command_name"
trap 'rm -f "$fixture_command_path"' EXIT

cat > "$fixture_command_path" <<-'EOF'
	#!/bin/sh
	# pj-__pj_help_test_fixture_command__
	#
	# A throwaway fixture command for pj_help_test.sh.

	echo "fixture command ran"
	EOF
chmod +x "$fixture_command_path"

if fixture_help_output="$("$PJ_HELP" 2>&1)"; then
	fixture_help_rc=0
else
	fixture_help_rc=$?
fi

fixture_line="$(echo "$fixture_help_output" | awk -v n="$fixture_command_name" '$1 == n')"
case "$fixture_line" in
*"A throwaway fixture command for pj_help_test.sh."*)
	echo "PASS: pj-help discovers a newly-added pj--prefixed bin/ command with no code change" ;;
*)
	echo "FAIL: pj-help discovers a newly-added pj--prefixed bin/ command with no code change (got: $fixture_help_output)"
	failures=$((failures + 1)) ;;
esac

rm -f "$fixture_command_path"
trap - EXIT

echo "$failures failure(s)"
[ "$failures" -eq 0 ]
