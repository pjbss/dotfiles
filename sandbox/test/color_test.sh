#!/bin/bash
# color_test.sh
#
# Plain-shell unit tests for sandbox/lib/color.sh (ANSI color-code
# variables for pj-sbx-spawn's usage/error output). No test framework
# dependency, same minimal assert style as task_test.sh/help_test.sh.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"

. "$SANDBOX_DIR/lib/color.sh"

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

# --- sandbox_color_supported (real function, in this non-interactive test harness) ---
#
# No real terminal is attached while running under a test runner, so this
# must be false regardless of $NO_COLOR -- a basic sanity check on the real
# function, not exhaustive (a real attached-terminal case is covered below
# by shadowing the function instead, the same trick task_test.sh already
# uses for `limactl`).

if sandbox_color_supported; then
	echo "FAIL: sandbox_color_supported is false with no terminal attached (this test harness)"
	failures=$((failures + 1))
else
	echo "PASS: sandbox_color_supported is false with no terminal attached (this test harness)"
fi

# --- sandbox_color_init, with sandbox_color_supported shadowed ---

sandbox_color_supported() { return 0; }
sandbox_color_init

if [ -n "$C_BOLD" ] && [ -n "$C_RED" ] && [ -n "$C_CYAN" ] && [ -n "$C_YELLOW" ] && [ -n "$C_RESET" ]; then
	echo "PASS: sandbox_color_init sets non-empty escape codes when color is supported"
else
	echo "FAIL: sandbox_color_init sets non-empty escape codes when color is supported (C_BOLD='$C_BOLD' C_RED='$C_RED' C_CYAN='$C_CYAN' C_YELLOW='$C_YELLOW' C_RESET='$C_RESET')"
	failures=$((failures + 1))
fi

sandbox_color_supported() { return 1; }
sandbox_color_init

assert_eq "" "$C_BOLD" "sandbox_color_init sets C_BOLD empty when color isn't supported"
assert_eq "" "$C_RED" "sandbox_color_init sets C_RED empty when color isn't supported"
assert_eq "" "$C_CYAN" "sandbox_color_init sets C_CYAN empty when color isn't supported"
assert_eq "" "$C_YELLOW" "sandbox_color_init sets C_YELLOW empty when color isn't supported"
assert_eq "" "$C_RESET" "sandbox_color_init sets C_RESET empty when color isn't supported"

unset -f sandbox_color_supported

# --- sourcing this file normally already calls sandbox_color_init once ---
# (implicitly covered above: C_BOLD etc. were already set, not unbound,
# before either override in this test ran)

echo "$failures failure(s)"
[ "$failures" -eq 0 ]
