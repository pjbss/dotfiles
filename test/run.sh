#!/bin/sh
# run.sh
#
# Runs every `*_test.sh` in this repo and reports one summary. Until now there
# was no entrypoint at all -- 14 test files with no runner, no Makefile, no CI,
# so "run the tests" meant knowing the list by heart. Automated gates (the
# Claude Code Stop hook, the autonomous issue loop) need exactly one command to
# call, which is what `make test` wraps.
#
# Test files are discovered, never enumerated, so a new one is picked up by
# dropping it in any of the three test directories -- the same drop-in
# convention as zsh/modules/ and sandbox/templates/. The `|| true` on the find
# matters: not every one of those directories exists in every checkout, and a
# find over a missing directory exits non-zero, which under `set -e` would
# silently truncate the discovery mid-list rather than fail loudly.
#
# Every file is run even after one fails, so a single invocation reports the
# whole picture rather than stopping at the first red file. Each is run as a
# subprocess (not sourced), so one test's fixtures, shadowed `limactl`/`ssh`
# functions, and `set -e` can't leak into the next.
#
# Usage: test/run.sh [--help|-h] [PATTERN]
#
# PATTERN, if given, is a literal substring filter on the test file path, for
# iterating on one area without running everything (e.g. `test/run.sh ssh`).

set -eu

SOURCE="$0"
while [ -h "$SOURCE" ]; do SOURCE="$(readlink "$SOURCE")"; done
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
DOTFILES_HOME="$(cd -P "$TEST_DIR/.." && pwd)"

pattern=""
for arg in "$@"; do
	case "$arg" in
		--help | -h)
			sed -n '2,/^$/p' "$SOURCE" | sed 's/^# \{0,1\}//'
			exit 0
			;;
		*)
			pattern="$arg"
			;;
	esac
done

cd "$DOTFILES_HOME"

test_files="$(find sandbox/test zsh/modules/test agents/test -type f -name '*_test.sh' 2>/dev/null || true)"
test_files="$(printf '%s\n' "$test_files" | sed 's|^\./||' | sort)"

if [ -n "$pattern" ]; then
	test_files="$(printf '%s\n' "$test_files" | grep -F "$pattern" || true)"
fi

if [ -z "$test_files" ]; then
	echo "test/run.sh: no test files found${pattern:+ matching '$pattern'}" >&2
	exit 1
fi

total=0
failed=0
failed_files=""

for test_file in $test_files; do
	total=$((total + 1))
	printf '\n=== %s ===\n' "$test_file"

	if bash "$test_file"; then
		:
	else
		failed=$((failed + 1))
		failed_files="$failed_files $test_file"
	fi
done

printf '\n=== summary ===\n'
echo "$total test file(s), $failed failed"

if [ "$failed" -ne 0 ]; then
	for test_file in $failed_files; do
		echo "  FAILED: $test_file"
	done
	exit 1
fi
