#!/bin/bash
# cli_test.sh
#
# Tests for the pj-sandbox/bin/pj-sandbox dispatcher: help output, unknown and
# not-yet-implemented subcommands, and loading a subcommand from
# lib/cmd_<sub>.sh.

set -euo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PJ_SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"
. "$TEST_DIR/../../test/assert.sh"

CLI="$PJ_SANDBOX_DIR/bin/pj-sandbox"

# --- help ---

for flag in --help -h help; do
	if out="$("$CLI" "$flag" 2>&1)"; then rc=0; else rc=$?; fi
	assert_exit_code 0 "$rc" "pj-sandbox $flag exits 0"
	for sub in spawn exec run attach list status logs allowlist fetch verify rm gc; do
		assert_contains "$out" "  $sub" "pj-sandbox $flag lists '$sub'"
	done
done

# --- no subcommand ---

if out="$("$CLI" 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "pj-sandbox with no subcommand exits 1"
assert_contains "$out" "Usage:" "pj-sandbox with no subcommand prints usage"

# --- unknown subcommand ---

if out="$("$CLI" frobnicate 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "an unknown subcommand exits 1"
assert_contains "$out" "unknown subcommand 'frobnicate'" "an unknown subcommand is named in the error"

# --- planned but unimplemented subcommand ---

# Run against a copy whose lib/ has no cmd_*.sh, so this keeps proving the
# not-implemented path after real subcommands land in the tree.
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/lib"
cp "$CLI" "$fixture/bin/pj-sandbox"

if out="$("$fixture/bin/pj-sandbox" spawn 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 2 "$rc" "a planned subcommand with no lib/cmd_<sub>.sh exits 2"
assert_contains "$out" "not implemented yet" "a planned subcommand with no lib/cmd_<sub>.sh says it's not implemented yet"

# --- implemented subcommand ---

cat > "$fixture/lib/cmd_status.sh" <<'CMD'
cmd_status() {
	echo "status called with: $*"
	return 7
}
CMD

if out="$("$fixture/bin/pj-sandbox" status one 'two words' 2>&1)"; then rc=0; else rc=$?; fi
assert_eq "status called with: one two words" "$out" "an implemented subcommand is loaded from lib/cmd_<sub>.sh and gets its arguments"
assert_exit_code 7 "$rc" "an implemented subcommand's exit status is the CLI's"

# Reached through a symlink, the way it will be once promoted onto PATH.
ln -s "$fixture/bin/pj-sandbox" "$fixture/link"
if out="$("$fixture/link" status 2>&1)"; then rc=0; else rc=$?; fi
assert_eq "status called with: " "$out" "the dispatcher finds lib/ when invoked through a symlink"

assert_report
