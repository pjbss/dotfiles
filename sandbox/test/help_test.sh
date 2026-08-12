#!/bin/bash
# help_test.sh
#
# Plain-shell unit tests for sandbox/lib/help.sh (--help/-h text
# extraction for pj-* commands, issue 007; one-line command-summary
# extraction for pj-help, issue 008). No test framework dependency, same
# minimal assert style as task_test.sh.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"

. "$SANDBOX_DIR/lib/help.sh"

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

# --- a well-formed header comment, with a shebang ---

fixture_wellformed="$(mktemp)"
cat > "$fixture_wellformed" <<-'EOF'
	#!/bin/sh
	# pj-example
	#
	# Does an example thing.
	#
	# Usage: pj-example <arg>

	set -eu
	echo "not part of the header"
	EOF

wellformed_help="$(sandbox_script_help "$fixture_wellformed")"
assert_eq "pj-example

Does an example thing.

Usage: pj-example <arg>" "$wellformed_help" \
	"sandbox_script_help extracts a well-formed header comment, stripping shebang and comment markers"

case "$wellformed_help" in
*"not part of the header"*)
	echo "FAIL: sandbox_script_help stops at the first non-comment line"
	failures=$((failures + 1))
	;;
*)
	echo "PASS: sandbox_script_help stops at the first non-comment line"
	;;
esac

rm -f "$fixture_wellformed"

# --- a header comment with no shebang at all ---

fixture_no_shebang="$(mktemp)"
cat > "$fixture_no_shebang" <<-'EOF'
	# pj-no-shebang
	#
	# Usage: pj-no-shebang
	set -eu
	EOF

no_shebang_help="$(sandbox_script_help "$fixture_no_shebang")"
assert_eq "pj-no-shebang

Usage: pj-no-shebang" "$no_shebang_help" \
	"sandbox_script_help works when line 1 is a comment rather than a shebang"

rm -f "$fixture_no_shebang"

# --- missing/empty header comment (graceful output, not a crash) ---

fixture_no_header="$(mktemp)"
cat > "$fixture_no_header" <<-'EOF'
	#!/bin/sh
	set -eu
	echo "no header here"
	EOF

no_header_help="$(sandbox_script_help "$fixture_no_header")"
assert_eq "" "$no_header_help" \
	"sandbox_script_help prints nothing (not a crash) for a script with no header comment"

rm -f "$fixture_no_header"

fixture_empty="$(mktemp)"

empty_file_help="$(sandbox_script_help "$fixture_empty")"
assert_eq "" "$empty_file_help" \
	"sandbox_script_help prints nothing (not a crash) for a completely empty file"

rm -f "$fixture_empty"

# --- sandbox_help_summary (issue 008) ---

summary_from_bare_title="$(sandbox_help_summary "pj-example

Does an example thing.

Usage: pj-example <arg>")"
assert_eq "$(printf 'pj-example\tDoes an example thing.')" "$summary_from_bare_title" \
	"sandbox_help_summary pairs a bare command name with the first non-blank description line"

summary_from_title_with_args="$(sandbox_help_summary "pj-sbx-ssh <task-name>

Connects into a running sandbox from a terminal.")"
assert_eq "$(printf 'pj-sbx-ssh\tConnects into a running sandbox from a terminal.')" "$summary_from_title_with_args" \
	"sandbox_help_summary collapses a title line's trailing usage args down to just the command name"

assert_eq "" "$(sandbox_help_summary "")" \
	"sandbox_help_summary prints nothing (not a crash) for an empty header"

# --- sandbox_comment_block_above (issue 008) ---

fixture_zsh_module="$(mktemp)"
cat > "$fixture_zsh_module" <<-'EOF'
	#!/bin/sh
	# some-module.zsh
	#
	# Module-level header, not the function's own doc comment.

	# pj-example-fn <arg>
	#
	# Does an example thing via a zsh function.
	pj-example-fn() {
		echo "body"
	}
	EOF

block_above="$(sandbox_comment_block_above "$fixture_zsh_module" "pj-example-fn() {")"
assert_eq "pj-example-fn <arg>

Does an example thing via a zsh function." "$block_above" \
	"sandbox_comment_block_above extracts only the comment block immediately preceding the matched function line"

no_match="$(sandbox_comment_block_above "$fixture_zsh_module" "no-such-function() {")"
assert_eq "" "$no_match" \
	"sandbox_comment_block_above prints nothing (not a crash) when the pattern never matches"

rm -f "$fixture_zsh_module"

echo "$failures failure(s)"
[ "$failures" -eq 0 ]
