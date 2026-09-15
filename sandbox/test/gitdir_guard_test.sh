#!/bin/bash
# gitdir_guard_test.sh
#
# Tests for sandbox/lib/gitdir_guard.sh, the host-side integrity check over the
# one directory a sandbox VM can write to but shouldn't: the spawning repo's
# real git directory, mounted read-write so git works inside /workspace.
#
# Uses a real throwaway git repo under a tmpdir -- the manifest covers
# `worktrees/*/config.worktree`, which only exists once `git worktree add` has
# actually run. Never touches the real dotfiles repo or $HOME.
#
# The two assertions that matter most are the last pair: a normal commit (the
# work a sandbox exists to do) must verify clean, while a planted hook -- the
# actual host code-execution path -- must not.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"
DOTFILES_HOME="$(cd -P "$SANDBOX_DIR/.." && pwd)"

. "$DOTFILES_HOME/test/assert.sh"
. "$SANDBOX_DIR/lib/gitdir_guard.sh"

fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

repo_root="$fixture_root/repo"
mkdir -p "$repo_root"
git -C "$repo_root" init -q
git -C "$repo_root" -c user.email=test@example.com -c user.name=test commit -q --allow-empty -m init

gitdir="$repo_root/.git"
manifest="$fixture_root/manifest"

# verify_result GITDIR MANIFEST -> $out, $rc
verify_result() {
	if out="$(sandbox_gitdir_verify "$1" "$2" 2>&1)"; then
		rc=0
	else
		rc=$?
	fi
}

# --- manifest contents ---

manifest_output="$(sandbox_gitdir_manifest "$gitdir")"
assert_contains "$manifest_output" "  config" "the manifest covers the git config file"
assert_contains "$manifest_output" "hooks/" "the manifest covers the hooks directory"
assert_not_contains "$manifest_output" "objects/" "the manifest deliberately ignores the object store"
assert_not_contains "$manifest_output" "refs/" "the manifest deliberately ignores refs"

# --- a missing manifest is never treated as 'unchanged' ---

verify_result "$gitdir" "$fixture_root/never-recorded"
assert_exit_code 1 "$rc" "verifying against a manifest that was never recorded fails"
assert_contains "$out" "cannot verify" "a missing manifest says the sandbox cannot be verified"

# --- a recorded, untouched gitdir verifies clean ---

sandbox_gitdir_manifest_write "$gitdir" "$manifest"
verify_result "$gitdir" "$manifest"
assert_exit_code 0 "$rc" "an untouched git directory verifies clean"
assert_eq "" "$out" "a clean verification prints nothing"

# --- ordinary sandbox work must not trip the guard ---

git -C "$repo_root" -c user.email=test@example.com -c user.name=test commit -q --allow-empty -m "work done in the sandbox"
git -C "$repo_root" branch -q a-new-branch

verify_result "$gitdir" "$manifest"
assert_exit_code 0 "$rc" "committing and branching -- the work a sandbox exists to do -- verifies clean"

worktree_path="$fixture_root/a-worktree"
git -C "$repo_root" worktree add -q "$worktree_path" a-new-branch
verify_result "$gitdir" "$manifest"
assert_exit_code 0 "$rc" "adding a worktree verifies clean"

# --- the actual attack: a hook planted from inside the VM ---

printf '#!/bin/sh\necho pwned\n' > "$gitdir/hooks/post-commit"
chmod +x "$gitdir/hooks/post-commit"

verify_result "$gitdir" "$manifest"
assert_exit_code 1 "$rc" "a hook planted in the git directory fails verification"
assert_contains "$out" "APPEARED: hooks/post-commit" "the planted hook is named in the report"

rm -f "$gitdir/hooks/post-commit"
verify_result "$gitdir" "$manifest"
assert_exit_code 0 "$rc" "removing the planted hook restores a clean verification"

# --- config tampering (core.hooksPath, filter.*.clean, ext:: remotes) ---

git -C "$repo_root" config core.hooksPath /tmp/evil-hooks
verify_result "$gitdir" "$manifest"
assert_exit_code 1 "$rc" "a modified git config fails verification"
assert_contains "$out" "MODIFIED: config" "a modified config is reported as modified"

git -C "$repo_root" config --unset core.hooksPath
verify_result "$gitdir" "$manifest"
assert_exit_code 0 "$rc" "reverting the config change restores a clean verification"

# --- deleting a covered file is a change too ---

sample_hook="$(find "$gitdir/hooks" -type f -name '*.sample' | head -1)"
if [ -n "$sample_hook" ]; then
	mv "$sample_hook" "$fixture_root/stashed-sample"
	verify_result "$gitdir" "$manifest"
	assert_exit_code 1 "$rc" "deleting a covered hook file fails verification"
	assert_contains "$out" "REMOVED:" "a deleted hook file is reported as removed"
	mv "$fixture_root/stashed-sample" "$sample_hook"
fi

# --- per-worktree config overrides are covered too ---

worktree_gitdir="$(git -C "$worktree_path" rev-parse --git-dir)"
git -C "$worktree_path" config --worktree --unset-all nonexistent.key 2>/dev/null || true
printf '[filter "evil"]\n\tclean = touch /tmp/pwned\n' > "$worktree_gitdir/config.worktree"

sandbox_gitdir_manifest_write "$gitdir" "$fixture_root/manifest-with-worktree-config"
printf '[filter "evil"]\n\tclean = touch /tmp/pwned-differently\n' > "$worktree_gitdir/config.worktree"

verify_result "$gitdir" "$fixture_root/manifest-with-worktree-config"
assert_exit_code 1 "$rc" "a modified per-worktree config fails verification"
assert_contains "$out" "config.worktree" "the modified per-worktree config is named"

git -C "$repo_root" worktree remove --force "$worktree_path" 2>/dev/null || rm -rf "$worktree_path"

# --- a repo path containing a space ----------------------------------------
#
# Regression test for a false all-clear. Batching the hashing into one process
# means feeding it a list of paths, and with a newline-separated list xargs
# splits on whitespace: every hook path under a directory with a space in its
# name failed to hash, the manifest quietly contained only `config`, and
# verification then reported clean with a hook sitting right there. A check
# that says "clean" when it hasn't looked is worse than no check.

spaced_root="$fixture_root/dir with spaces/repo"
mkdir -p "$spaced_root"
git -C "$spaced_root" init -q
git -C "$spaced_root" -c user.email=test@example.com -c user.name=test commit -q --allow-empty -m init
spaced_gitdir="$spaced_root/.git"
spaced_manifest="$fixture_root/spaced-manifest"

spaced_output="$(sandbox_gitdir_manifest "$spaced_gitdir" 2>/dev/null)"
assert_contains "$spaced_output" "hooks/pre-commit.sample" "hooks under a path containing a space are actually hashed"

hook_lines="$(printf '%s\n' "$spaced_output" | grep -c '^[0-9a-f]\{64\}  hooks/' || true)"
assert_ok "every hook under a spaced path produced a real hash line" test "$hook_lines" -gt 5

sandbox_gitdir_manifest_write "$spaced_gitdir" "$spaced_manifest"
verify_result "$spaced_gitdir" "$spaced_manifest"
assert_exit_code 0 "$rc" "an untouched repo under a spaced path verifies clean"

printf '#!/bin/sh\necho pwned\n' > "$spaced_gitdir/hooks/post-commit"
verify_result "$spaced_gitdir" "$spaced_manifest"
assert_exit_code 1 "$rc" "a hook planted under a spaced path is still detected -- no false all-clear"
assert_contains "$out" "APPEARED: hooks/post-commit" "the planted hook is named even under a spaced path"

assert_report
