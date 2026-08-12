#!/bin/bash
# base_template_test.sh
#
# Plain-shell unit tests for sandbox/lib/base_template.sh (`--base <name>`
# resolution for `pj-sbx-spawn`, issue 003). No test framework dependency,
# same minimal assert style as task_test.sh/list_test.sh.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"

. "$SANDBOX_DIR/lib/base_template.sh"

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

# --- fixture templates dir ---

templates_dir="$(mktemp -d)"
touch "$templates_dir/python3.12" "$templates_dir/none"

# --- valid name resolves ---

assert_eq "$templates_dir/python3.12" "$(sandbox_base_template_path "$templates_dir" python3.12)" \
	"sandbox_base_template_path resolves a valid --base name to its template file path"

assert_eq "$templates_dir/none" "$(sandbox_base_template_path "$templates_dir" none)" \
	"sandbox_base_template_path resolves the 'none' template"

# --- unrecognized name fails with no output ---

if output="$(sandbox_base_template_path "$templates_dir" bogus-name 2>/dev/null)"; then
	echo "FAIL: sandbox_base_template_path fails for an unrecognized name"
	failures=$((failures + 1))
elif [ -n "$output" ]; then
	echo "FAIL: sandbox_base_template_path prints nothing for an unrecognized name (got '$output')"
	failures=$((failures + 1))
else
	echo "PASS: sandbox_base_template_path fails with no output for an unrecognized name"
fi

# --- comma-separated/multi-value name is rejected the same way ---

if sandbox_base_template_path "$templates_dir" "python3.12,node20" >/dev/null 2>&1; then
	echo "FAIL: sandbox_base_template_path rejects a comma-separated multi-value name"
	failures=$((failures + 1))
else
	echo "PASS: sandbox_base_template_path rejects a comma-separated multi-value name"
fi

rm -rf "$templates_dir"

# --- sandbox_base_template_list (issue 004) ---

list_templates_dir="$(mktemp -d)"
touch "$list_templates_dir/python3.12" "$list_templates_dir/python3.14" "$list_templates_dir/none"

assert_eq "none
python3.12
python3.14" "$(sandbox_base_template_list "$list_templates_dir")" \
	"sandbox_base_template_list prints every template name in the directory, one per line"

# Dropping in a new file should appear with no other code change -- the
# whole point of deriving the list from the directory rather than a
# hardcoded array.
touch "$list_templates_dir/node20"

assert_eq "node20
none
python3.12
python3.14" "$(sandbox_base_template_list "$list_templates_dir")" \
	"sandbox_base_template_list picks up a newly-added template file with no code change"

rm -rf "$list_templates_dir"

# --- the real template set (issue 003) ---

real_templates_dir="$SANDBOX_DIR/templates"

for template_name in python3.12 python3.14 none; do
	if [ -f "$real_templates_dir/$template_name" ]; then
		echo "PASS: sandbox/templates/$template_name exists"
	else
		echo "FAIL: sandbox/templates/$template_name exists"
		failures=$((failures + 1))
	fi
done

echo "$failures failure(s)"
[ "$failures" -eq 0 ]
