# assert.sh
#
# Shared assertion helpers for this repo's plain-shell test files. There's no
# test framework here on purpose (bats isn't installed or declared anywhere),
# just these few helpers -- previously copy-pasted verbatim into every
# `*_test.sh`. Meant to be sourced, not executed:
#
#     TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#     . "$TEST_DIR/../../test/assert.sh"
#
# Output format is deliberately identical to the copies it replaces (`PASS: ` /
# `FAIL: ... (expected 'x', got 'y')`), so migrating a test file changes nothing
# a reader or `make test` can see.
#
# Sourcing initializes `failures` to 0. Every assertion below increments it
# rather than exiting, so one run reports every failure instead of stopping at
# the first -- which matters most for the integration-style tests, where a bail
# partway through can leave a fixture behind. End a test file with
# `assert_report`, whose exit status is the file's exit status.

failures=0

# assert_eq EXPECTED ACTUAL MESSAGE
assert_eq() {
	if [ "$1" != "$2" ]; then
		echo "FAIL: $3 (expected '$1', got '$2')"
		failures=$((failures + 1))
	else
		echo "PASS: $3"
	fi
}

# assert_contains HAYSTACK NEEDLE MESSAGE
#
# Literal substring match (no globbing or regex), for asserting against
# captured command output without pinning its exact wording.
assert_contains() {
	case "$1" in
		*"$2"*)
			echo "PASS: $3"
			;;
		*)
			echo "FAIL: $3 (expected to find '$2' in '$1')"
			failures=$((failures + 1))
			;;
	esac
}

# assert_not_contains HAYSTACK NEEDLE MESSAGE
assert_not_contains() {
	case "$1" in
		*"$2"*)
			echo "FAIL: $3 (expected not to find '$2' in '$1')"
			failures=$((failures + 1))
			;;
		*)
			echo "PASS: $3"
			;;
	esac
}

# assert_exit_code EXPECTED ACTUAL MESSAGE
#
# Separate from assert_eq only so the failure message names what it's
# comparing; capture ACTUAL at the call site, since `set -e` would otherwise
# kill the test on the first non-zero command:
#
#     if out="$(some_command 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code() {
	if [ "$1" != "$2" ]; then
		echo "FAIL: $3 (expected exit code $1, got $2)"
		failures=$((failures + 1))
	else
		echo "PASS: $3"
	fi
}

# assert_ok MESSAGE COMMAND [ARG...]
#
# Passes if COMMAND exits 0. Runs it with output discarded -- for the
# "does this predicate hold" checks that would otherwise need a hand-rolled
# if/else around a `failures` increment.
assert_ok() {
	message="$1"
	shift

	if "$@" >/dev/null 2>&1; then
		echo "PASS: $message"
	else
		echo "FAIL: $message (command failed: $*)"
		failures=$((failures + 1))
	fi
}

# assert_not_ok MESSAGE COMMAND [ARG...]
assert_not_ok() {
	message="$1"
	shift

	if "$@" >/dev/null 2>&1; then
		echo "FAIL: $message (command unexpectedly succeeded: $*)"
		failures=$((failures + 1))
	else
		echo "PASS: $message"
	fi
}

# assert_report
#
# Prints the trailing count every test file in this repo ends with, and returns
# the file's exit status. Use as the last line: `assert_report`.
assert_report() {
	echo "$failures failure(s)"
	[ "$failures" -eq 0 ]
}
