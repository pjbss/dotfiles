# workspace.sh
#
# VS Code workspace file detection/copy-through for `pj-sbx-spawn`
# (issue 001): if the source repo has a `<repo_name>.code-workspace` file
# at its root -- the conventional name VS Code's own "Save Workspace As"
# defaults to -- copy it into the newly spawned worktree so opening VS
# Code against the sandboxed task works without hand-recreating the file.
# Meant to be sourced, not executed directly.

# sandbox_workspace_source_path REPO_ROOT
#
# Prints REPO_ROOT/<repo_name>.code-workspace (repo_name being
# `basename REPO_ROOT`) and returns 0 if that file exists. Prints nothing
# and returns 1 if it doesn't -- so callers can branch on presence.
sandbox_workspace_source_path() {
	repo_root="$1"
	repo_name="$(basename "$repo_root")"
	candidate="$repo_root/$repo_name.code-workspace"

	if [ -f "$candidate" ]; then
		echo "$candidate"
		return 0
	fi

	return 1
}

# sandbox_workspace_write SOURCE_PATH REPO_ROOT WORKTREE_PATH
#
# Writes SOURCE_PATH's content to WORKTREE_PATH/$(basename SOURCE_PATH),
# overwriting any file already there (e.g. one `git worktree add` placed
# if the source was tracked), and prints the path written.
#
# Before writing, rewrites any `folders[].path` entry that's an absolute
# path equal to REPO_ROOT or a subdirectory of it to the equivalent path
# under WORKTREE_PATH (issue 002). Relative `folders[].path` entries,
# absolute entries outside REPO_ROOT, and every other top-level key
# (settings/launch/tasks/etc.) are left alone. If no entry needed
# rewriting, the file is written byte-for-byte unchanged -- the JSON is
# only re-serialized (via `python3 -c`, consistent with this repo's other
# JSON handling) when a path actually changes.
sandbox_workspace_write() {
	source_path="$1"
	repo_root="$2"
	worktree_path="$3"
	dest_path="$worktree_path/$(basename "$source_path")"

	python3 -c '
import json, os, sys

source_path, repo_root, worktree_path = sys.argv[1], sys.argv[2], sys.argv[3]

with open(source_path) as f:
    raw = f.read()

data = json.loads(raw)
changed = False

for folder in data.get("folders", []):
    path = folder.get("path")
    if path is None or not os.path.isabs(path):
        continue
    if path != repo_root and not path.startswith(repo_root + os.sep):
        continue
    folder["path"] = worktree_path + path[len(repo_root):]
    changed = True

sys.stdout.write(json.dumps(data, indent=2) + "\n" if changed else raw)
' "$source_path" "$repo_root" "$worktree_path" > "$dest_path"

	echo "$dest_path"
}
