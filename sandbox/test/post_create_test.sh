#!/bin/bash
# post_create_test.sh
#
# Plain-shell unit tests for sandbox/lib/post_create.sh (`--post-create`
# path-vs-command resolution for `pj-sbx-spawn`, issue 014). No test
# framework dependency, same minimal assert style as workspace_test.sh/
# base_template_test.sh.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"

. "$SANDBOX_DIR/lib/post_create.sh"

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

fixture_repo="$(mktemp -d)"

# --- existing file relative to repo root is identified as a script ---

script_relative_path="scripts/setup.sh"
mkdir -p "$fixture_repo/scripts"
printf '#!/bin/sh\nnpm ci\n' > "$fixture_repo/$script_relative_path"

if resolved="$(sandbox_post_create_resolve "$script_relative_path" "$fixture_repo")"; then
	echo "PASS: sandbox_post_create_resolve returns 0 (script) for an existing file relative to repo root"
else
	echo "FAIL: sandbox_post_create_resolve returns 0 (script) for an existing file relative to repo root"
	failures=$((failures + 1))
fi

assert_eq "$(cat "$fixture_repo/$script_relative_path")" "$resolved" \
	"sandbox_post_create_resolve prints the script file's exact current content"

# --- content is read fresh at call time, not cached from an earlier read ---

printf '#!/bin/sh\npip install -r requirements.txt\n' > "$fixture_repo/$script_relative_path"

assert_eq "$(cat "$fixture_repo/$script_relative_path")" \
	"$(sandbox_post_create_resolve "$script_relative_path" "$fixture_repo")" \
	"sandbox_post_create_resolve reads the script file's content fresh, reflecting an edit since the prior call"

# --- nonexistent path is treated as a literal command ---

if sandbox_post_create_resolve "no-such-script.sh" "$fixture_repo" >/dev/null; then
	echo "FAIL: sandbox_post_create_resolve returns 1 (command) for a nonexistent path"
	failures=$((failures + 1))
else
	echo "PASS: sandbox_post_create_resolve returns 1 (command) for a nonexistent path"
fi

assert_eq "no-such-script.sh" "$(sandbox_post_create_resolve "no-such-script.sh" "$fixture_repo" || true)" \
	"sandbox_post_create_resolve prints a nonexistent path's value unchanged, as a literal command"

# --- an inline command value (never a path at all) is treated as a command ---

assert_eq "npm ci" "$(sandbox_post_create_resolve "npm ci" "$fixture_repo" || true)" \
	"sandbox_post_create_resolve prints an inline command value unchanged"

# --- resolution is against the given repo root, not the process's cwd ---

other_dir="$(mktemp -d)"
mkdir -p "$other_dir/scripts"
printf 'echo should-not-run-from-cwd\n' > "$other_dir/$script_relative_path"

cd "$other_dir"
assert_eq "$(cat "$fixture_repo/$script_relative_path")" \
	"$(sandbox_post_create_resolve "$script_relative_path" "$fixture_repo")" \
	"sandbox_post_create_resolve resolves against the given repo root, not the process's cwd"

rm -rf "$fixture_repo" "$other_dir"

echo "$failures failure(s)"
[ "$failures" -eq 0 ]
