#!/bin/bash
# pj_sbx_verify_test.sh
#
# Integration tests for bin/pj-sbx-verify, and for the same integrity check as
# it gates bin/pj-sbx-teardown. The unit-level behavior of the manifest itself
# lives in gitdir_guard_test.sh; what's covered here is the part a person
# actually relies on: that a tampered git directory produces a non-zero exit
# and a message naming the file, and that teardown refuses to dismantle the
# sandbox before you've seen it.
#
# Uses a real throwaway git repo plus a tmpdir sandbox root, with a stub
# `limactl` on PATH so no real VM is ever consulted. $HOME is never touched.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"
DOTFILES_HOME="$(cd -P "$SANDBOX_DIR/.." && pwd)"

. "$DOTFILES_HOME/test/assert.sh"

VERIFY="$DOTFILES_HOME/bin/pj-sbx-verify"
TEARDOWN="$DOTFILES_HOME/bin/pj-sbx-teardown"

fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

# A stub limactl that reports every instance as unknown, so teardown takes its
# "already gone, skip VM teardown" path instead of touching real Lima state.
stub_bin="$fixture_root/stub-bin"
mkdir -p "$stub_bin"
printf '#!/bin/sh\nexit 1\n' > "$stub_bin/limactl"
chmod +x "$stub_bin/limactl"

repo_root="$fixture_root/myrepo"
mkdir -p "$repo_root"
git -C "$repo_root" init -q
git -C "$repo_root" -c user.email=test@example.com -c user.name=test commit -q --allow-empty -m init
gitdir="$repo_root/.git"

sandbox_root="$fixture_root/sandboxes"
mkdir -p "$sandbox_root/myrepo/lima-configs"
manifest="$sandbox_root/myrepo/lima-configs/some-task.gitdir-manifest"
vm_config="$sandbox_root/myrepo/lima-configs/some-task.yaml"

ssh_include="$fixture_root/pj-sandbox-config"
: > "$ssh_include"

# run_in_repo COMMAND ARGS...
run_in_repo() {
	if out="$(cd "$repo_root" && PATH="$stub_bin:$PATH" \
		SANDBOX_WORKTREE_ROOT="$sandbox_root" \
		SANDBOX_SSH_INCLUDE_FILE="$ssh_include" \
		NO_COLOR=1 "$@" 2>&1)"; then
		rc=0
	else
		rc=$?
	fi
}

# --- argument handling ---

run_in_repo "$VERIFY" --help
assert_exit_code 0 "$rc" "pj-sbx-verify --help exits 0"
assert_contains "$out" "Usage: pj-sbx-verify" "pj-sbx-verify --help prints its header comment as usage"

run_in_repo "$VERIFY"
assert_exit_code 1 "$rc" "pj-sbx-verify with no task name exits 1"
assert_contains "$out" "Usage: pj-sbx-verify" "pj-sbx-verify with no task name prints usage"

# --- a sandbox with no recorded manifest cannot be verified ---

run_in_repo "$VERIFY" some-task
assert_exit_code 1 "$rc" "verifying a sandbox with no recorded manifest exits 1"
assert_contains "$out" "cannot verify" "an unrecorded sandbox is reported as unverifiable, not as clean"

# --- record, then verify clean ---

. "$SANDBOX_DIR/lib/gitdir_guard.sh"
sandbox_gitdir_manifest_write "$gitdir" "$manifest"

run_in_repo "$VERIFY" some-task
assert_exit_code 0 "$rc" "an untouched sandbox verifies clean"
assert_contains "$out" "is clean" "a clean verification says so"

# --- the task name is slugged the same way spawn/teardown slug it ---

run_in_repo "$VERIFY" "Some Task"
assert_exit_code 0 "$rc" "a free-text task name resolves to the same slug spawn used"

# --- ordinary sandbox work stays clean ---

git -C "$repo_root" -c user.email=test@example.com -c user.name=test commit -q --allow-empty -m "agent did some work"
run_in_repo "$VERIFY" some-task
assert_exit_code 0 "$rc" "a commit made inside the sandbox does not trip the check"

# --- a planted hook is caught and named ---

printf '#!/bin/sh\necho pwned\n' > "$gitdir/hooks/post-checkout"
chmod +x "$gitdir/hooks/post-checkout"

run_in_repo "$VERIFY" some-task
assert_exit_code 1 "$rc" "a hook planted in the git directory fails verification"
assert_contains "$out" "hooks/post-checkout" "the failing report names the planted hook"
assert_contains "$out" "FAILED INTEGRITY CHECK" "the failing report is unmistakable"

# --- teardown refuses while the tampering is unexplained ---

: > "$vm_config"

run_in_repo "$TEARDOWN" some-task
assert_exit_code 1 "$rc" "teardown refuses when the integrity check fails"
assert_contains "$out" "REFUSING TO TEAR DOWN" "teardown says why it refused"
assert_contains "$out" "hooks/post-checkout" "teardown names the file that changed"
assert_ok "teardown left the render artifact in place so the sandbox can still be inspected" test -e "$vm_config"
assert_ok "teardown left the manifest in place" test -e "$manifest"

# --- --force gets past it, deliberately ---

run_in_repo "$TEARDOWN" some-task --force
assert_exit_code 0 "$rc" "teardown --force proceeds despite a failed integrity check"
assert_contains "$out" "FAILED" "teardown --force still reports the failure rather than hiding it"
assert_not_ok "teardown --force removed the render artifact" test -e "$vm_config"
assert_not_ok "teardown --force removed the manifest along with the sandbox" test -e "$manifest"

# --- a clean sandbox tears down without needing --force ---

rm -f "$gitdir/hooks/post-checkout"
: > "$vm_config"
sandbox_gitdir_manifest_write "$gitdir" "$manifest"

run_in_repo "$TEARDOWN" some-task
assert_exit_code 0 "$rc" "a clean sandbox tears down with no --force needed"
assert_contains "$out" "integrity check passed" "a clean teardown reports the check passed"
assert_not_ok "a clean teardown removes the render artifact" test -e "$vm_config"

assert_report
