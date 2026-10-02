#!/bin/bash
# isolation_test.sh
#
# pj-sandbox/ stays inert until it's promoted: nothing installs it, nothing
# already on PATH reaches into it, and it never borrows code from the old
# sandbox/lib (anything reused is copied, so the two change independently).

set -euo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PJ_SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"
DOTFILES_HOME="$(cd -P "$PJ_SANDBOX_DIR/.." && pwd)"
. "$DOTFILES_HOME/test/assert.sh"

# The root installer sources every module's install.sh, including inside
# sandbox guests, so one here would install this tree everywhere.
if [ -e "$PJ_SANDBOX_DIR/install.sh" ]; then
	echo "FAIL: pj-sandbox/ has no install.sh for the root installer to source"
	failures=$((failures + 1))
else
	echo "PASS: pj-sandbox/ has no install.sh for the root installer to source"
fi

# Top-level bin/ is on PATH and zsh/ is sourced into every shell.
refs="$(grep -rlF 'pj-sandbox/' "$DOTFILES_HOME/bin" "$DOTFILES_HOME/zsh" || true)"
assert_eq "" "$refs" "nothing under top-level bin/ or zsh/ references pj-sandbox/"

# A `.`/`source` line naming sandbox/lib -- but not pj-sandbox/lib, whose path
# ends in the same characters.
sources="$(grep -rnE '^[[:space:]]*(\.|source)[[:space:]].*(^|[^-[:alnum:]])sandbox/lib' "$PJ_SANDBOX_DIR" || true)"
assert_eq "" "$sources" "no file under pj-sandbox/ sources anything from sandbox/lib"

# Nor by climbing out of pj-sandbox/ into the old module through a relative path.
climbs="$(grep -rnE '^[[:space:]]*(\.|source)[[:space:]].*\.\./(\.\./)*sandbox/' "$PJ_SANDBOX_DIR" || true)"
assert_eq "" "$climbs" "no file under pj-sandbox/ sources the old sandbox/ through a relative path"

assert_report
