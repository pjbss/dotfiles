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

# --- fixture templates dirs (checked-in + local, issue 009) ---

templates_dir="$(mktemp -d)"
local_templates_dir="$(mktemp -d)"
touch "$templates_dir/python3.12" "$templates_dir/none"

# --- valid name resolves from the checked-in dir ---

assert_eq "$templates_dir/python3.12" "$(sandbox_base_template_path "$templates_dir" "$local_templates_dir" python3.12)" \
	"sandbox_base_template_path resolves a valid --base name to its template file path"

assert_eq "$templates_dir/none" "$(sandbox_base_template_path "$templates_dir" "$local_templates_dir" none)" \
	"sandbox_base_template_path resolves the 'none' template"

# --- unrecognized name fails with no output ---

if output="$(sandbox_base_template_path "$templates_dir" "$local_templates_dir" bogus-name 2>/dev/null)"; then
	echo "FAIL: sandbox_base_template_path fails for an unrecognized name"
	failures=$((failures + 1))
elif [ -n "$output" ]; then
	echo "FAIL: sandbox_base_template_path prints nothing for an unrecognized name (got '$output')"
	failures=$((failures + 1))
else
	echo "PASS: sandbox_base_template_path fails with no output for an unrecognized name"
fi

# --- comma-separated/multi-value name is rejected the same way ---

if sandbox_base_template_path "$templates_dir" "$local_templates_dir" "python3.12,node20" >/dev/null 2>&1; then
	echo "FAIL: sandbox_base_template_path rejects a comma-separated multi-value name"
	failures=$((failures + 1))
else
	echo "PASS: sandbox_base_template_path rejects a comma-separated multi-value name"
fi

# --- a local-only name resolves, with no checked-in counterpart ---

touch "$local_templates_dir/webtools"

assert_eq "$local_templates_dir/webtools" "$(sandbox_base_template_path "$templates_dir" "$local_templates_dir" webtools)" \
	"sandbox_base_template_path resolves a local-only --base name"

# --- a name in both dirs resolves to the local one ("local wins") ---

echo "checked-in content" > "$templates_dir/python3.12"
echo "local content" > "$local_templates_dir/python3.12"

assert_eq "$local_templates_dir/python3.12" "$(sandbox_base_template_path "$templates_dir" "$local_templates_dir" python3.12)" \
	"sandbox_base_template_path resolves a name present in both dirs to the local one"

assert_eq "local content" "$(cat "$(sandbox_base_template_path "$templates_dir" "$local_templates_dir" python3.12)")" \
	"the resolved path for a colliding name actually points at the local file's content"

echo "" > "$templates_dir/python3.12"
rm -f "$local_templates_dir/webtools" "$local_templates_dir/python3.12"

# --- a nonexistent local dir doesn't break resolution of a checked-in name ---

missing_local_dir="$(mktemp -u)"

assert_eq "$templates_dir/none" "$(sandbox_base_template_path "$templates_dir" "$missing_local_dir" none)" \
	"sandbox_base_template_path resolves a checked-in name even when the local dir doesn't exist at all"

rm -rf "$templates_dir" "$local_templates_dir"

# --- sandbox_base_template_list (issue 004; merge behavior added issue 009) ---

list_templates_dir="$(mktemp -d)"
list_local_dir="$(mktemp -d)"
touch "$list_templates_dir/python3.12" "$list_templates_dir/python3.14" "$list_templates_dir/none"

assert_eq "none
python3.12
python3.14" "$(sandbox_base_template_list "$list_templates_dir" "$list_local_dir")" \
	"sandbox_base_template_list prints every template name in the checked-in directory, one per line"

# Dropping in a new file should appear with no other code change -- the
# whole point of deriving the list from the directory rather than a
# hardcoded array.
touch "$list_templates_dir/node20"

assert_eq "node20
none
python3.12
python3.14" "$(sandbox_base_template_list "$list_templates_dir" "$list_local_dir")" \
	"sandbox_base_template_list picks up a newly-added template file with no code change"

# --- local-only names are merged in, tagged " (local)" ---

touch "$list_local_dir/webtools"

assert_eq "node20
none
python3.12
python3.14
webtools (local)" "$(sandbox_base_template_list "$list_templates_dir" "$list_local_dir")" \
	"sandbox_base_template_list merges in a local-only name, tagged '(local)', sorted alongside the checked-in names"

# --- a name in both dirs is listed once, tagged as local ---

touch "$list_local_dir/python3.12"

assert_eq "node20
none
python3.12 (local)
python3.14
webtools (local)" "$(sandbox_base_template_list "$list_templates_dir" "$list_local_dir")" \
	"sandbox_base_template_list lists a colliding name once, tagged '(local)' since the local one wins"

# --- a nonexistent local dir doesn't break listing of checked-in names ---

missing_list_local_dir="$(mktemp -u)"

assert_eq "node20
none
python3.12
python3.14" "$(sandbox_base_template_list "$list_templates_dir" "$missing_list_local_dir")" \
	"sandbox_base_template_list lists checked-in names even when the local dir doesn't exist at all"

# --- the "(local)" tag itself is colored when $C_YELLOW/$C_RESET are set ---
#
# list_local_dir has both "webtools" (local-only) and "python3.12" (a
# collision, added above) at this point, so both are tagged.

C_YELLOW="<YELLOW>"
C_RESET="<RESET>"

assert_eq "node20
none
python3.12 <YELLOW>(local)<RESET>
python3.14
webtools <YELLOW>(local)<RESET>" "$(sandbox_base_template_list "$list_templates_dir" "$list_local_dir")" \
	"sandbox_base_template_list wraps the '(local)' tag in \$C_YELLOW/\$C_RESET when set, name itself uncolored"

assert_eq "node20
none
python3.12
python3.14
webtools" "$(sandbox_base_template_list "$list_templates_dir" "$list_local_dir" | awk '{print $1}')" \
	"sandbox_base_template_list still sorts correctly by name with the tag colored (name remains the first whitespace-delimited field)"

unset C_YELLOW C_RESET

rm -rf "$list_templates_dir" "$list_local_dir"

# --- sandbox_base_template_names_block ---
#
# Shared "Available --base names:" header + indented list that --help and
# every --base-related usage/error message in pj-sbx-spawn now print
# together, so the formatting/coloring only needs describing once here.

names_block_dir="$(mktemp -d)"
names_block_local_dir="$(mktemp -d)"
touch "$names_block_dir/python3.12" "$names_block_dir/none"

assert_eq "Available --base names:
  none
  python3.12" "$(sandbox_base_template_names_block "$names_block_dir" "$names_block_local_dir")" \
	"sandbox_base_template_names_block prints a header followed by the indented, sorted name list (plain, no color vars set)"

C_CYAN="<CYAN>"
C_RESET="<RESET>"

assert_eq "<CYAN>Available --base names:<RESET>
  none
  python3.12" "$(sandbox_base_template_names_block "$names_block_dir" "$names_block_local_dir")" \
	"sandbox_base_template_names_block wraps the header in \$C_CYAN/\$C_RESET when set"

unset C_CYAN C_RESET

rm -rf "$names_block_dir" "$names_block_local_dir"

# --- directory-shaped --base templates (issue 010) ---

dir_templates_dir="$(mktemp -d)"
dir_local_dir="$(mktemp -d)"

# --- sandbox_base_template_path resolves a directory the same as a file ---

mkdir "$dir_templates_dir/dirtemplate"

assert_eq "$dir_templates_dir/dirtemplate" "$(sandbox_base_template_path "$dir_templates_dir" "$dir_local_dir" dirtemplate)" \
	"sandbox_base_template_path resolves a directory-shaped --base name"

# --- sandbox_base_template_list includes a directory-shaped name, same as a file ---

assert_eq "dirtemplate" "$(sandbox_base_template_list "$dir_templates_dir" "$dir_local_dir")" \
	"sandbox_base_template_list includes a directory-shaped template name, indistinguishable from a file-shaped one"

# --- sandbox_base_template_provision_path ---

flat_file_template="$(mktemp)"
echo "flat file content" > "$flat_file_template"

assert_eq "$flat_file_template" "$(sandbox_base_template_provision_path "$flat_file_template")" \
	"sandbox_base_template_provision_path returns a flat-file template's own path unchanged"

dir_with_provision="$(mktemp -d)"
echo "dir provisioning content" > "$dir_with_provision/provision.yaml"

assert_eq "$dir_with_provision/provision.yaml" "$(sandbox_base_template_provision_path "$dir_with_provision")" \
	"sandbox_base_template_provision_path returns DIR/provision.yaml for a directory template that has one"

dir_without_provision="$(mktemp -d)"

assert_eq "" "$(sandbox_base_template_provision_path "$dir_without_provision")" \
	"sandbox_base_template_provision_path prints nothing for a directory template with no provision.yaml"

# --- sandbox_base_template_mounts_path ---

assert_eq "" "$(sandbox_base_template_mounts_path "$flat_file_template")" \
	"sandbox_base_template_mounts_path prints nothing for a flat-file template (no mounts capability)"

dir_with_mounts="$(mktemp -d)"
echo "- location: \"/host/extra\"" > "$dir_with_mounts/mounts.yaml"

assert_eq "$dir_with_mounts/mounts.yaml" "$(sandbox_base_template_mounts_path "$dir_with_mounts")" \
	"sandbox_base_template_mounts_path returns DIR/mounts.yaml for a directory template that has one"

dir_without_mounts="$(mktemp -d)"

assert_eq "" "$(sandbox_base_template_mounts_path "$dir_without_mounts")" \
	"sandbox_base_template_mounts_path prints nothing for a directory template with no mounts.yaml"

# --- sandbox_base_template_port_forwards_path (issue 013) ---

assert_eq "" "$(sandbox_base_template_port_forwards_path "$flat_file_template")" \
	"sandbox_base_template_port_forwards_path prints nothing for a flat-file template (no port-forwards capability)"

dir_with_port_forwards="$(mktemp -d)"
echo "- guestPort: 6379" > "$dir_with_port_forwards/port_forwards.yaml"

assert_eq "$dir_with_port_forwards/port_forwards.yaml" "$(sandbox_base_template_port_forwards_path "$dir_with_port_forwards")" \
	"sandbox_base_template_port_forwards_path returns DIR/port_forwards.yaml for a directory template that has one"

dir_without_port_forwards="$(mktemp -d)"

assert_eq "" "$(sandbox_base_template_port_forwards_path "$dir_without_port_forwards")" \
	"sandbox_base_template_port_forwards_path prints nothing for a directory template with no port_forwards.yaml"

rm -rf "$dir_templates_dir" "$dir_local_dir" "$flat_file_template" "$dir_with_provision" "$dir_without_provision" "$dir_with_mounts" "$dir_without_mounts" "$dir_with_port_forwards" "$dir_without_port_forwards"

# --- sandbox_base_template_files_path / sandbox_base_template_files_provision_yaml (issue 012) ---
#
# Lima's `mounts:` only accepts directories (confirmed against a real
# `limactl start` failure spawning issue 011's webtools template), and its
# only per-file provisioning primitive (`mode: data`) reads its source once
# at render time, never live -- so an individual host file can't be
# live-mounted the way mounts.yaml's directories can. `files` is a plain
# HOST_PATH:GUEST_PATH pair list (not raw YAML, unlike mounts.yaml) because
# the content has to be read fresh at render time, not spliced from a
# static fragment.

flat_file_template_files="$(mktemp)"
echo "flat file content" > "$flat_file_template_files"

assert_eq "" "$(sandbox_base_template_files_path "$flat_file_template_files")" \
	"sandbox_base_template_files_path prints nothing for a flat-file template (no files capability)"

dir_with_files="$(mktemp -d)"
echo "irrelevant:irrelevant" > "$dir_with_files/files"

assert_eq "$dir_with_files/files" "$(sandbox_base_template_files_path "$dir_with_files")" \
	"sandbox_base_template_files_path returns DIR/files for a directory template that has one"

dir_without_files="$(mktemp -d)"

assert_eq "" "$(sandbox_base_template_files_path "$dir_without_files")" \
	"sandbox_base_template_files_path prints nothing for a directory template with no files manifest"

# --- sandbox_base_template_files_provision_yaml ---

assert_eq "" "$(sandbox_base_template_files_provision_yaml "")" \
	"sandbox_base_template_files_provision_yaml prints nothing for an empty manifest path"

assert_eq "" "$(sandbox_base_template_files_provision_yaml "$dir_without_files/files")" \
	"sandbox_base_template_files_provision_yaml prints nothing for a nonexistent manifest file"

host_file_one="$(mktemp)"
printf 'line one\nline two\n' > "$host_file_one"

manifest_one_pair="$(mktemp)"
echo "$host_file_one:/guest/path/one" > "$manifest_one_pair"

rendered_one_pair="$(sandbox_base_template_files_provision_yaml "$manifest_one_pair")"

case "$rendered_one_pair" in
*'- mode: data'*'path: "/guest/path/one"'*'content: |'*'    line one'*'    line two'*)
	echo "PASS: sandbox_base_template_files_provision_yaml renders a mode: data entry with the host file's exact content" ;;
*)
	echo "FAIL: sandbox_base_template_files_provision_yaml renders a mode: data entry with the host file's exact content (got: $rendered_one_pair)"
	failures=$((failures + 1)) ;;
esac

# Redirected straight to a file rather than captured into a shell variable
# first -- command substitution ($(...)) unconditionally strips all
# trailing newlines, which would make this specific byte-fidelity check
# fail on an artifact of the test's own capture method, not a real bug.
rendered_one_pair_file="$(mktemp)"
sandbox_base_template_files_provision_yaml "$manifest_one_pair" > "$rendered_one_pair_file"

python3 -c "
import sys, yaml
docs = yaml.safe_load('provision:\n' + open('$rendered_one_pair_file').read())
content = docs['provision'][0]['content']
assert content == 'line one\nline two\n', repr(content)
print('CONTENT MATCHES EXACTLY')
" && echo "PASS: the rendered content parses back to the host file's exact bytes" || { echo "FAIL: the rendered content parses back to the host file's exact bytes"; failures=$((failures + 1)); }

rm -f "$rendered_one_pair_file"

# --- ~/-prefixed HOST_PATH expands against the real home directory ---

home_relative_marker="__pj_base_template_test_home_file__"
home_relative_file="$HOME/$home_relative_marker"
printf 'home dir content\n' > "$home_relative_file"

manifest_home_relative="$(mktemp)"
echo "~/$home_relative_marker:/guest/path/home" > "$manifest_home_relative"

rendered_home_relative="$(sandbox_base_template_files_provision_yaml "$manifest_home_relative")"

case "$rendered_home_relative" in
*'home dir content'*) echo "PASS: sandbox_base_template_files_provision_yaml expands a ~/-prefixed HOST_PATH against \$HOME" ;;
*) echo "FAIL: sandbox_base_template_files_provision_yaml expands a ~/-prefixed HOST_PATH against \$HOME (got: $rendered_home_relative)"; failures=$((failures + 1)) ;;
esac

rm -f "$home_relative_file" "$manifest_home_relative"

# --- multiple pairs each render as their own entry ---

host_file_two="$(mktemp)"
printf 'second file content\n' > "$host_file_two"

manifest_two_pairs="$(mktemp)"
{
	echo "$host_file_one:/guest/path/one"
	echo "$host_file_two:/guest/path/two"
} > "$manifest_two_pairs"

rendered_two_pairs="$(sandbox_base_template_files_provision_yaml "$manifest_two_pairs")"

mode_data_count="$(printf '%s\n' "$rendered_two_pairs" | grep -c '^- mode: data')"
assert_eq "2" "$mode_data_count" \
	"sandbox_base_template_files_provision_yaml renders one mode: data entry per manifest pair"

case "$rendered_two_pairs" in
*'path: "/guest/path/one"'*'path: "/guest/path/two"'*) echo "PASS: sandbox_base_template_files_provision_yaml preserves manifest pair order" ;;
*) echo "FAIL: sandbox_base_template_files_provision_yaml preserves manifest pair order (got: $rendered_two_pairs)"; failures=$((failures + 1)) ;;
esac

rm -f "$flat_file_template_files" "$dir_with_files/files" "$host_file_one" "$host_file_two" "$manifest_one_pair" "$manifest_two_pairs"
rm -rf "$dir_with_files" "$dir_without_files"

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
