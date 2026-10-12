#!/bin/bash
# base_template_test.sh
#
# Tests for pj-sandbox/lib/base_template.sh: --base names resolve against the
# real pj-sandbox/templates/ and a local overrides dir, a local name wins a
# collision, the listing merges both, and a template's `files` manifest turns
# into Lima `mode: data` provision items.

set -euo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PJ_SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"
. "$TEST_DIR/../../test/assert.sh"

TEMPLATES="$PJ_SANDBOX_DIR/templates"

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
LOCAL="$fixture/local"

# bt FUNCTION [ARGS...]
#
# Runs one library function under POSIX sh.
bt() {
	sh -c '. "$1/lib/base_template.sh"; shift; "$@"' sh "$PJ_SANDBOX_DIR" "$@"
}

# --- built-in names resolve, with no local dir at all ---

for name in none python3.12 python3.14; do
	if out="$(bt pj_sandbox_base_template_path "$TEMPLATES" "$LOCAL" "$name")"; then rc=0; else rc=$?; fi
	assert_exit_code 0 "$rc" "'$name' resolves"
	assert_eq "$TEMPLATES/$name" "$out" "'$name' resolves to the built-in template"
done
assert_contains "$(cat "$TEMPLATES/python3.12")" "python3.12-venv" "the python3.12 template installs python3.12"

for name in bogus "python3.12,python3.14" ""; do
	if out="$(bt pj_sandbox_base_template_path "$TEMPLATES" "$LOCAL" "$name")"; then rc=0; else rc=$?; fi
	assert_exit_code 1 "$rc" "'$name' doesn't resolve"
	assert_eq "" "$out" "'$name' prints no path"
done

# --- a local template overrides a built-in one ---

mkdir -p "$LOCAL"
printf -- '- mode: system\n  script: echo local\n' > "$LOCAL/python3.12"
mkdir "$LOCAL/webtools"
assert_eq "$LOCAL/python3.12" "$(bt pj_sandbox_base_template_path "$TEMPLATES" "$LOCAL" python3.12)" "a local template wins a name collision"
assert_eq "$LOCAL/webtools" "$(bt pj_sandbox_base_template_path "$TEMPLATES" "$LOCAL" webtools)" "a local-only directory template resolves"
assert_eq "$TEMPLATES/none" "$(bt pj_sandbox_base_template_path "$TEMPLATES" "$LOCAL" none)" "built-ins without a local twin still resolve"

# --- the merged listing ---

assert_eq "$(printf '%s\n' none 'python3.12 (local)' python3.14 'webtools (local)')" \
	"$(bt pj_sandbox_base_template_list "$TEMPLATES" "$LOCAL")" \
	"the listing merges both dirs one per line, sorted, local names tagged and not doubled"
assert_eq "$(printf '%s\n' none python3.12 python3.14)" \
	"$(bt pj_sandbox_base_template_list "$TEMPLATES" "$fixture/missing")" \
	"a missing local dir contributes no names"
block="$(bt pj_sandbox_base_template_names_block "$TEMPLATES" "$LOCAL")"
assert_eq "Available --base names:" "$(printf '%s\n' "$block" | head -1)" "the names block has a header"
assert_contains "$block" "$(printf '  none\n  python3.12 (local)')" "the names block indents each name"

# --- provision, mounts and files paths ---

assert_eq "$TEMPLATES/python3.12" "$(bt pj_sandbox_base_template_provision_path "$TEMPLATES/python3.12")" "a flat template is its own provision fragment"
assert_eq "" "$(bt pj_sandbox_base_template_provision_path "$LOCAL/webtools")" "a directory template without provision.yaml provisions nothing"
assert_eq "" "$(bt pj_sandbox_base_template_mounts_path "$LOCAL/webtools")" "a directory template without mounts.yaml has no mounts"
assert_eq "" "$(bt pj_sandbox_base_template_files_path "$LOCAL/webtools")" "a directory template without files has no manifest"
touch "$LOCAL/webtools/provision.yaml" "$LOCAL/webtools/mounts.yaml" "$LOCAL/webtools/files"
assert_eq "$LOCAL/webtools/provision.yaml" "$(bt pj_sandbox_base_template_provision_path "$LOCAL/webtools")" "a directory template's provision.yaml is its fragment"
assert_eq "$LOCAL/webtools/mounts.yaml" "$(bt pj_sandbox_base_template_mounts_path "$LOCAL/webtools")" "a directory template's mounts.yaml is found"
assert_eq "$LOCAL/webtools/files" "$(bt pj_sandbox_base_template_files_path "$LOCAL/webtools")" "a directory template's files manifest is found"
assert_eq "" "$(bt pj_sandbox_base_template_mounts_path "$TEMPLATES/python3.12")" "a flat template never has mounts"

# --- files are copied in as mode: data provision items ---

mkdir -p "$fixture/home"
printf 'line one\n  indented\n' > "$fixture/home/token.txt"
printf 'abs\n' > "$fixture/abs.txt"
printf '~/token.txt:/home/u/.token\n\n%s:/etc/abs\n' "$fixture/abs.txt" > "$fixture/manifest"
out="$(HOME="$fixture/home" bt pj_sandbox_base_template_files_provision_yaml "$fixture/manifest")"
assert_eq "$(printf '%s\n' \
	'- mode: data' '  path: "/home/u/.token"' '  owner: "{{.User}}:{{.User}}"' '  permissions: "0600"' '  content: |' '    line one' '      indented' \
	'- mode: data' '  path: "/etc/abs"' '  owner: "{{.User}}:{{.User}}"' '  permissions: "0600"' '  content: |' '    abs')" \
	"$out" "each manifest line becomes a mode: data item holding the host file's content, ~/ expanded"
assert_eq "" "$(bt pj_sandbox_base_template_files_provision_yaml "")" "no manifest provisions nothing"

printf '%s:/etc/gone\n' "$fixture/gone.txt" > "$fixture/bad-manifest"
if bt pj_sandbox_base_template_files_provision_yaml "$fixture/bad-manifest" >/dev/null 2>&1; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "a manifest naming a missing host file fails"

assert_report
