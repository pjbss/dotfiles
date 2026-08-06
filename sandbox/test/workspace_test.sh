#!/bin/bash
# workspace_test.sh
#
# Plain-shell unit tests for sandbox/lib/workspace.sh (VS Code workspace
# file detection/copy-through for `pj-sandbox-spawn`, issue 001). No test
# framework dependency, same minimal assert style as task_test.sh/
# devcontainer_test.sh.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"

. "$SANDBOX_DIR/lib/workspace.sh"

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
repo_name="$(basename "$fixture_repo")"

# --- sandbox_workspace_source_path: no workspace file ---

if sandbox_workspace_source_path "$fixture_repo" >/dev/null; then
	echo "FAIL: sandbox_workspace_source_path fails when no .code-workspace file exists"
	failures=$((failures + 1))
else
	echo "PASS: sandbox_workspace_source_path fails when no .code-workspace file exists"
fi

# --- sandbox_workspace_source_path: workspace file present ---

echo '{"folders":[{"path":"."}]}' > "$fixture_repo/$repo_name.code-workspace"

assert_eq "$fixture_repo/$repo_name.code-workspace" "$(sandbox_workspace_source_path "$fixture_repo")" \
	"sandbox_workspace_source_path finds an existing <repo_name>.code-workspace file"

# --- sandbox_workspace_write: copies content verbatim ---

fixture_worktree="$(mktemp -d)"
source_path="$fixture_repo/$repo_name.code-workspace"

written_path="$(sandbox_workspace_write "$source_path" "$fixture_repo" "$fixture_worktree")"

assert_eq "$fixture_worktree/$repo_name.code-workspace" "$written_path" \
	"sandbox_workspace_write prints the path it wrote"

assert_eq "$(cat "$source_path")" "$(cat "$fixture_worktree/$repo_name.code-workspace")" \
	"sandbox_workspace_write copies the source file's content verbatim"

# --- sandbox_workspace_write: rewrites an absolute folders[].path under repo_root ---

fixture_repo2="$(mktemp -d)"
repo_name2="$(basename "$fixture_repo2")"
fixture_worktree2="$(mktemp -d)"
source_path2="$fixture_repo2/$repo_name2.code-workspace"

printf '{"folders":[{"path":"%s"}]}' "$fixture_repo2" > "$source_path2"

sandbox_workspace_write "$source_path2" "$fixture_repo2" "$fixture_worktree2" >/dev/null
rewritten_path_value="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["folders"][0]["path"])' "$fixture_worktree2/$repo_name2.code-workspace")"

assert_eq "$fixture_worktree2" "$rewritten_path_value" \
	"sandbox_workspace_write rewrites an absolute folders[].path equal to repo_root to worktree_path"

rm -rf "$fixture_repo2" "$fixture_worktree2"

# --- sandbox_workspace_write: rewrites an absolute folders[].path under a repo_root subdir ---

fixture_repo3="$(mktemp -d)"
repo_name3="$(basename "$fixture_repo3")"
fixture_worktree3="$(mktemp -d)"
source_path3="$fixture_repo3/$repo_name3.code-workspace"

printf '{"folders":[{"path":"%s/subdir"}]}' "$fixture_repo3" > "$source_path3"

sandbox_workspace_write "$source_path3" "$fixture_repo3" "$fixture_worktree3" >/dev/null
rewritten_path_value3="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["folders"][0]["path"])' "$fixture_worktree3/$repo_name3.code-workspace")"

assert_eq "$fixture_worktree3/subdir" "$rewritten_path_value3" \
	"sandbox_workspace_write rewrites an absolute folders[].path under a repo_root subdirectory to worktree_path"

rm -rf "$fixture_repo3" "$fixture_worktree3"

# --- sandbox_workspace_write: mixed folders + other top-level keys ---

fixture_repo4="$(mktemp -d)"
repo_name4="$(basename "$fixture_repo4")"
fixture_worktree4="$(mktemp -d)"
unrelated_dir="$(mktemp -d)"
source_path4="$fixture_repo4/$repo_name4.code-workspace"

python3 -c '
import json, sys
repo_root, unrelated_dir, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
data = {
    "folders": [
        {"path": repo_root},
        {"path": "../sibling"},
        {"path": unrelated_dir},
    ],
    "settings": {"foo": "bar"},
}
json.dump(data, open(out_path, "w"))
' "$fixture_repo4" "$unrelated_dir" "$source_path4"

sandbox_workspace_write "$source_path4" "$fixture_repo4" "$fixture_worktree4" >/dev/null
dest_path4="$fixture_worktree4/$repo_name4.code-workspace"

assert_eq "$fixture_worktree4" \
	"$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["folders"][0]["path"])' "$dest_path4")" \
	"sandbox_workspace_write rewrites the repo_root folders[].path entry in a mixed-entry file"

assert_eq "../sibling" \
	"$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["folders"][1]["path"])' "$dest_path4")" \
	"sandbox_workspace_write leaves a relative folders[].path entry unchanged"

assert_eq "$unrelated_dir" \
	"$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["folders"][2]["path"])' "$dest_path4")" \
	"sandbox_workspace_write leaves an absolute folders[].path entry outside repo_root unchanged"

assert_eq "bar" \
	"$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["settings"]["foo"])' "$dest_path4")" \
	"sandbox_workspace_write preserves other top-level keys (settings) unmodified"

rm -rf "$fixture_repo4" "$fixture_worktree4" "$unrelated_dir"

echo "$failures failure(s)"
[ "$failures" -eq 0 ]
