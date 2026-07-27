#!/bin/bash
# worktree_test.sh
#
# Plain-shell unit tests for sandbox/lib/worktree.sh (dotfiles-sandbox-spawn's
# create-vs-resume decision for a task's worktree path, added during issue
# 010's end-to-end validation pass). Uses a real, throwaway git repo under a
# tmpdir -- `git worktree list` needs a real repo, but this never touches the
# actual dotfiles repo or $HOME.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"

. "$SANDBOX_DIR/lib/worktree.sh"

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

repo_root="$(mktemp -d)"
repo_root="$(cd -P "$repo_root" && pwd)"
git -C "$repo_root" init -q
git -C "$repo_root" -c user.email=test@example.com -c user.name=test commit -q --allow-empty -m init

# --- no worktree, no branch yet: create ---

fresh_path="$repo_root-fresh-worktree"
action="$(sandbox_resolve_worktree_action "$repo_root" "$fresh_path" fresh-task)"
assert_eq "create" "$action" \
	"sandbox_resolve_worktree_action says 'create' when neither the worktree path nor the branch exist yet"

# --- an existing, registered worktree (left behind by a prior teardown): resume ---

resumable_path="$repo_root-resumable-worktree"
git -C "$repo_root" worktree add -q -b resumable-task "$resumable_path"

action="$(sandbox_resolve_worktree_action "$repo_root" "$resumable_path" resumable-task)"
assert_eq "resume" "$action" \
	"sandbox_resolve_worktree_action says 'resume' for a path that's already a registered worktree of this repo"

# --- an existing branch but no worktree checked out for it: attach ---

git -C "$repo_root" branch -q attach-task

attach_path="$repo_root-attach-worktree"
action="$(sandbox_resolve_worktree_action "$repo_root" "$attach_path" attach-task)"
assert_eq "attach" "$action" \
	"sandbox_resolve_worktree_action says 'attach' when the branch already exists but has no worktree checked out"

# --- a stray directory that exists but isn't a worktree at all: refuse ---

stray_path="$repo_root-stray"
mkdir -p "$stray_path"

if sandbox_resolve_worktree_action "$repo_root" "$stray_path" stray-task >/dev/null 2>&1; then
	echo "FAIL: sandbox_resolve_worktree_action refuses a path that exists but isn't a registered worktree"
	failures=$((failures + 1))
else
	echo "PASS: sandbox_resolve_worktree_action refuses a path that exists but isn't a registered worktree"
fi

git -C "$repo_root" worktree remove --force "$resumable_path" 2>/dev/null || rm -rf "$resumable_path"
rm -rf "$repo_root" "$stray_path"

echo "$failures failure(s)"
[ "$failures" -eq 0 ]
