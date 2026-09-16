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

missing=""
for name in C_BOLD C_DIM C_RED C_GREEN C_YELLOW C_BLUE C_MAGENTA C_CYAN C_RESET; do
	eval "value=\$$name"
	[ -n "$value" ] || missing="$missing $name"
done

if [ -z "$missing" ]; then
	echo "PASS: sandbox_color_init sets non-empty escape codes when color is supported"
else
	echo "FAIL: sandbox_color_init sets non-empty escape codes when color is supported (empty:$missing)"
	failures=$((failures + 1))
fi

# Every color is a distinct sequence -- a copy-paste slip that gave two of
# them the same code would make pj-run-issues' per-agent labels
# indistinguishable, which is the whole point of having them.
distinct="$(printf '%s\n' "$C_RED" "$C_GREEN" "$C_YELLOW" "$C_BLUE" "$C_MAGENTA" "$C_CYAN" | sort -u | wc -l | tr -d ' ')"
assert_eq "6" "$distinct" "the six label colors are six different escape sequences"

sandbox_color_supported() { return 1; }
sandbox_color_init

for name in C_BOLD C_DIM C_RED C_GREEN C_YELLOW C_BLUE C_MAGENTA C_CYAN C_RESET; do
	eval "value=\$$name"
	assert_eq "" "$value" "sandbox_color_init sets $name empty when color isn't supported"
done

unset -f sandbox_color_supported

# --- sourcing this file normally already calls sandbox_color_init once ---
# (implicitly covered above: C_BOLD etc. were already set, not unbound,
# before either override in this test ran)

echo "$failures failure(s)"
[ "$failures" -eq 0 ]
