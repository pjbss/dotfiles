#!/bin/bash
# pj_sbx_run_test.sh
#
# Tests for bin/pj-sbx-run, the host-side dispatcher.
#
# Its own logic is small -- verify, ssh, verify again -- but the ordering is the
# entire point, so that's what's asserted here: it must refuse to dispatch to a
# sandbox that already fails its integrity check, and it must re-check
# afterwards *regardless of how the loop exited*, because a run that crashed is
# exactly when you most want to know what it touched.
#
# `ssh` is shadowed by a stub on PATH, so no VM is contacted and the guest side
# can be made to succeed, fail, or tamper on demand.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"
DOTFILES_HOME="$(cd -P "$SANDBOX_DIR/.." && pwd)"

. "$DOTFILES_HOME/test/assert.sh"
. "$SANDBOX_DIR/lib/gitdir_guard.sh"

SBX_RUN="$DOTFILES_HOME/bin/pj-sbx-run"

fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

repo_root="$fixture_root/myrepo"
mkdir -p "$repo_root"
git -C "$repo_root" init -q
git -C "$repo_root" -c user.email=t@e.com -c user.name=t commit -q --allow-empty -m init
gitdir="$repo_root/.git"

sandbox_root="$fixture_root/sandboxes"
mkdir -p "$sandbox_root/myrepo/lima-configs"
manifest="$sandbox_root/myrepo/lima-configs/some-task.gitdir-manifest"

stub_bin="$fixture_root/stub-bin"
mkdir -p "$stub_bin"

# A stub ssh that records the command it was handed, and can be told to fail or
# to tamper with the host git directory the way a misbehaving guest would.
cat > "$stub_bin/ssh" <<STUB
#!/bin/sh
printf '%s\n' "\$*" > "$fixture_root/ssh-invocation"
[ -n "\${STUB_SSH_TAMPER:-}" ] && printf '#!/bin/sh\nexit 0\n' > "$gitdir/hooks/pre-push"
exit "\${STUB_SSH_STATUS:-0}"
STUB
chmod +x "$stub_bin/ssh"

run_sbx_run() {
	if out="$(cd "$repo_root" && PATH="$stub_bin:$PATH" \
		SANDBOX_WORKTREE_ROOT="$sandbox_root" NO_COLOR=1 \
		"$SBX_RUN" "$@" 2>&1)"; then
		rc=0
	else
		rc=$?
	fi
}

# --- argument handling ---

run_sbx_run --help
assert_exit_code 0 "$rc" "pj-sbx-run --help exits 0"
assert_contains "$out" "Usage: pj-sbx-run" "pj-sbx-run --help prints its header comment as usage"

run_sbx_run
assert_exit_code 1 "$rc" "pj-sbx-run with no task name exits 1"

# --- refuses to dispatch to an already-failing sandbox ---

rm -f "$fixture_root/ssh-invocation"
run_sbx_run some-task
assert_exit_code 1 "$rc" "refuses to dispatch when there's no recorded manifest to verify against"
assert_not_ok "nothing was dispatched over ssh" test -f "$fixture_root/ssh-invocation"

sandbox_gitdir_manifest_write "$gitdir" "$manifest"
printf '#!/bin/sh\nexit 0\n' > "$gitdir/hooks/post-commit"

run_sbx_run some-task
assert_exit_code 1 "$rc" "refuses to dispatch to a sandbox that already fails its integrity check"
assert_contains "$out" "refusing to dispatch" "the pre-dispatch refusal says so"
assert_not_ok "still nothing dispatched over ssh" test -f "$fixture_root/ssh-invocation"

rm -f "$gitdir/hooks/post-commit"

# --- the happy path ---

run_sbx_run some-task --max-issues 2
assert_exit_code 0 "$rc" "a clean run exits 0"
invocation="$(cat "$fixture_root/ssh-invocation")"
assert_contains "$invocation" "some-task" "ssh is pointed at the slug spawn wrote a Host entry for"
assert_contains "$invocation" "cd '/workspace'" "the remote command lands in /workspace by default"
assert_contains "$invocation" "pj-run-issues --max-issues 2" "arguments are passed through to pj-run-issues"

# --- --project-dir ---

# pj-run-issues takes the directory it's run from as the project, so a monorepo
# package with its own issues/ is only reachable from the host if this can aim
# the ssh command somewhere other than the worktree root.
run_sbx_run some-task --project-dir app --max-issues 2
assert_exit_code 0 "$rc" "--project-dir runs"
invocation="$(cat "$fixture_root/ssh-invocation")"
assert_contains "$invocation" "cd '/workspace/app'" "a relative --project-dir is resolved under /workspace"
assert_contains "$invocation" "pj-run-issues --max-issues 2" "the remaining arguments still reach pj-run-issues"
assert_not_contains "$invocation" "--project-dir" "--project-dir is consumed here, not passed on to a command that would reject it"

run_sbx_run some-task --project-dir /elsewhere
invocation="$(cat "$fixture_root/ssh-invocation")"
assert_contains "$invocation" "cd '/elsewhere'" "an absolute --project-dir is used as given"

run_sbx_run some-task --project-dir
assert_exit_code 1 "$rc" "--project-dir with no value is refused"
assert_contains "$out" "needs a directory" "the refusal says what --project-dir wants"

# --- the loop's exit status is preserved ---

STUB_SSH_STATUS=3 run_sbx_run some-task
assert_exit_code 3 "$rc" "a failing loop's exit status is passed through rather than swallowed"
assert_contains "$out" "loop exited 3" "the failing status is reported"

# --- the post-run check runs even when the loop failed ---

if out="$(cd "$repo_root" && PATH="$stub_bin:$PATH" \
	SANDBOX_WORKTREE_ROOT="$sandbox_root" NO_COLOR=1 \
	STUB_SSH_STATUS=3 STUB_SSH_TAMPER=1 "$SBX_RUN" some-task 2>&1)"; then rc=0; else rc=$?; fi

assert_exit_code 1 "$rc" "tampering detected after a failed run wins over the loop's own exit status"
assert_contains "$out" "wrote to the host's git directory" "the post-run check reports what happened"
assert_contains "$out" "until you have looked" "the post-run failure warns against running git on the host"
rm -f "$gitdir/hooks/pre-push"

# --- and when the loop succeeded ---

if out="$(cd "$repo_root" && PATH="$stub_bin:$PATH" \
	SANDBOX_WORKTREE_ROOT="$sandbox_root" NO_COLOR=1 \
	STUB_SSH_TAMPER=1 "$SBX_RUN" some-task 2>&1)"; then rc=0; else rc=$?; fi

assert_exit_code 1 "$rc" "tampering during an otherwise successful run still fails the command"
assert_contains "$out" "wrote to the host's git directory" "a successful loop does not exempt the sandbox from the check"

assert_report
