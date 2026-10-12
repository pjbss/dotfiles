#!/bin/bash
# git_bundle_test.sh
#
# Tests for how `pj-sandbox spawn` gets the task branch into the VM: a host
# branch, a git bundle of it, and a clone on the guest's own disk. Real `git`
# runs in a temp host repo. A stub `limactl` records every call and runs the
# guest steps (`copy`, `shell`) against a temp "guest" root, with every
# absolute guest path re-rooted under it.

set -euo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PJ_SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"
. "$TEST_DIR/../../test/assert.sh"
. "$TEST_DIR/stub_proxy.sh"

CLI="$PJ_SANDBOX_DIR/bin/pj-sandbox"

fixture="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "$fixture"' EXIT

unset PJ_SANDBOX_STATE_DIR PJ_SANDBOX_SSH_INCLUDE_FILE PJ_SANDBOX_SSH_CONFIG_FILE \
	PJ_SANDBOX_PORT_MIN PJ_SANDBOX_PORT_MAX PJ_SANDBOX_INSTANCE_PREFIX \
	XDG_STATE_HOME XDG_CONFIG_HOME GIT_CONFIG_GLOBAL GIT_DIR GIT_WORK_TREE
export HOME="$fixture/home"
export STUB_DIR="$fixture/stub"
export GUEST_ROOT="$fixture/guest"
STATE_DIR="$HOME/.local/state/pj-sandbox"
mkdir -p "$HOME/.ssh" "$fixture/bin" "$STUB_DIR" "$GUEST_ROOT/tmp" "$GUEST_ROOT/home"
git config --global user.name tester
git config --global user.email tester@example.com
git config --global init.defaultBranch main

cat > "$fixture/bin/limactl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/calls"
# Re-roots an absolute guest path under GUEST_ROOT.
guest() { case "$1" in /*) printf '%s%s\n' "$GUEST_ROOT" "$1" ;; *) printf '%s\n' "$1" ;; esac; }
case "$1" in
	start)
		for last in "$@"; do :; done
		cp "$last" "$STUB_DIR/rendered.yaml"
		;;
	ls)
		for name in "$@"; do :; done
		printf 'Host lima-%s\n  Hostname 127.0.0.1\n  Port 61022\n' "$name" > "$STUB_DIR/$name.ssh.config"
		echo "$STUB_DIR/$name.ssh.config"
		;;
	copy)
		cp "$2" "$(guest "${3#*:}")"
		;;
	shell)
		shift
		[ "$1" = --workdir ] && shift 2
		shift # instance
		args=()
		for arg in "$@"; do args+=("$(guest "$arg")"); done
		cat > "$STUB_DIR/guest-script.sh"
		(cd "$GUEST_ROOT" && HOME="$GUEST_ROOT/home" "${args[@]}" < "$STUB_DIR/guest-script.sh")
		;;
	*)
		echo "unexpected limactl call: $*" >&2
		exit 3
		;;
esac
STUB
chmod +x "$fixture/bin/limactl"
# The guest bootstrap (bootstrap_test.sh covers it) goes over ssh, which only
# needs to drain the archive and script here. The fixture repo stands in for
# the dotfiles, so the real checkout is never archived.
cat > "$fixture/bin/ssh" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_DIR/ssh-calls"
cat > /dev/null
STUB
chmod +x "$fixture/bin/ssh"
export PJ_SANDBOX_DOTFILES_HOME="$fixture/repo"
# spawn starts the task's proxy; a stub stands in for mitmdump.
pj_test_stub_proxy "$fixture/bin"
export PJ_SANDBOX_PROXY_SETTLE=0
export PATH="$fixture/bin:$PATH"

repo="$fixture/repo"
git init -q "$repo"
git -C "$repo" commit -q --allow-empty -m first
git -C "$repo" commit -q --allow-empty -m second
git_common_dir="$(cd "$repo" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"

reset_guest() {
	rm -rf "$GUEST_ROOT" "$STUB_DIR"/*
	mkdir -p "$GUEST_ROOT/tmp" "$GUEST_ROOT/home"
}

spawn() {
	(cd "$repo" && "$CLI" spawn "$@")
}

# --- a fresh task branch, from HEAD ---

if out="$(spawn feature-a --base none 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "spawn exits 0 (output: $out)"

host_commit="$(git -C "$repo" rev-parse refs/heads/feature-a)"
assert_eq "$(git -C "$repo" rev-parse HEAD)" "$host_commit" "a new task branch starts from HEAD"
ws="$GUEST_ROOT/workspace"
assert_eq "feature-a" "$(git -C "$ws" symbolic-ref --short HEAD)" "the guest clone is on branch <task>"
assert_eq "$host_commit" "$(git -C "$ws" rev-parse HEAD)" "the guest clone is at the host branch's commit"
assert_eq "" "$(git -C "$ws" remote)" "the guest clone has no remote left"
assert_ok "the copied bundle is removed from the guest" test -z "$(ls "$GUEST_ROOT/tmp")"

guest_cfg="$GUEST_ROOT/home/.gitconfig"
assert_eq "never" "$(git config --file "$guest_cfg" protocol.ext.allow)" "the guest's global git config sets protocol.ext.allow=never"
hooks="$(git config --file "$guest_cfg" core.hooksPath)"
assert_contains "$hooks" "$GUEST_ROOT/home/" "the guest's core.hooksPath is under the guest's own home"
assert_ok "the guest's core.hooksPath is an empty directory" test -d "$hooks" -a -z "$(ls -A "$hooks" 2>/dev/null)"

meta="$STATE_DIR/feature-a/meta"
assert_eq "$repo" "$(sed -n 's/^repo=//p' "$meta")" "the record holds the host repo"
assert_eq "feature-a" "$(sed -n 's/^branch=//p' "$meta")" "the record holds the branch"
assert_eq "" "$(ls "$STATE_DIR/feature-a" | grep "\.bundle$" || true)" "the host bundle doesn't outlive the clone"

# --- the generated guest script ---

script="$(cat "$STUB_DIR/guest-script.sh")"
assert_contains "$script" "git config --global core.hooksPath" "the guest script sets core.hooksPath globally"
assert_contains "$script" "git config --global protocol.ext.allow never" "the guest script sets protocol.ext.allow=never globally"

# --- no host git dir path reaches the guest side ---

assert_not_contains "$(cat "$STUB_DIR/rendered.yaml")" "$git_common_dir" "the rendered Lima config names no path under the git dir"
assert_not_contains "$(cat "$STUB_DIR/calls")" "$git_common_dir" "no limactl call names a path under the git dir"
assert_not_contains "$(cat "$STUB_DIR/calls")" "$repo" "no limactl call names a path in the host repo"
assert_contains "$(cat "$STUB_DIR/calls")" "--workdir /" "the guest script runs with a guest working directory"

# --- an existing branch is reused, not moved ---

git -C "$repo" branch existing HEAD~1
reset_guest
spawn existing --base none --from HEAD >/dev/null 2>&1
assert_eq "$(git -C "$repo" rev-parse HEAD~1)" "$(git -C "$repo" rev-parse refs/heads/existing)" "an existing task branch is left where it was"
assert_eq "$(git -C "$repo" rev-parse HEAD~1)" "$(git -C "$GUEST_ROOT/workspace" rev-parse HEAD)" "the guest gets the existing branch's commit"

# --- --from picks the start of a new branch ---

reset_guest
spawn from-ref --base none --from HEAD~1 >/dev/null 2>&1
assert_eq "$(git -C "$repo" rev-parse HEAD~1)" "$(git -C "$repo" rev-parse refs/heads/from-ref)" "--from sets where a new branch starts"
assert_eq "from-ref" "$(git -C "$GUEST_ROOT/workspace" symbolic-ref --short HEAD)" "the guest is on the --from task's branch"

# --- resuming from refs/sandbox/<task>/<task> ---

git -C "$repo" commit-tree -p HEAD -m "work from a previous sandbox" "HEAD^{tree}" > "$fixture/resumed"
resumed="$(cat "$fixture/resumed")"
git -C "$repo" update-ref refs/sandbox/resumed/resumed "$resumed"
reset_guest
spawn resumed --base none >/dev/null 2>&1
assert_eq "$resumed" "$(git -C "$repo" rev-parse refs/heads/resumed)" "a new branch resumes from refs/sandbox/<task>/<task>"
assert_eq "$resumed" "$(git -C "$GUEST_ROOT/workspace" rev-parse HEAD)" "the guest gets the resumed commit"

# --- refusals, none of which may reach limactl ---

: > "$STUB_DIR/calls"
if out="$(cd "$fixture" && "$CLI" spawn outside --base none 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "spawn outside a git repo exits 1"
assert_contains "$out" "git repo" "spawn outside a git repo says so"

if out="$(spawn 'bad name' --base none 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "a task name that isn't a valid branch name exits 1"
assert_contains "$out" "branch name" "an invalid branch name is named as such"

if out="$(spawn bad-from --base none --from no-such-ref 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "an unresolvable --from exits 1"
assert_not_ok "an unresolvable --from creates no branch" git -C "$repo" rev-parse --verify --quiet refs/heads/bad-from

if out="$(spawn no-arg --base none --from 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "--from without a value exits 1"

assert_eq "" "$(cat "$STUB_DIR/calls")" "no refused spawn calls limactl"

assert_report
