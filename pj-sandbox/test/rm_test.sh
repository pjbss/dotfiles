#!/bin/bash
# rm_test.sh
#
# Tests for `pj-sandbox rm`, run through the real dispatcher. A stub limactl
# first on PATH records each call to a shared calls file and says which
# instances exist; a stub ssh (GIT_SSH_COMMAND) serves a temp "guest" repo
# for `rm --fetch` and records its own call to the same file, so the order of
# fetch and delete is visible.

set -euo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PJ_SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"
. "$TEST_DIR/../../test/assert.sh"

CLI="$PJ_SANDBOX_DIR/bin/pj-sandbox"

fixture="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "$fixture"' EXIT

unset PJ_SANDBOX_STATE_DIR PJ_SANDBOX_SSH_INCLUDE_FILE PJ_SANDBOX_SSH_CONFIG_FILE \
	PJ_SANDBOX_INSTANCE_PREFIX XDG_STATE_HOME XDG_CONFIG_HOME GIT_CONFIG_GLOBAL GIT_DIR GIT_WORK_TREE
export HOME="$fixture/home"
export STUB_DIR="$fixture/stub"
export GUEST_ROOT="$fixture/guest"
export PJ_SANDBOX_DOTFILES_HOME="$fixture/unused"
STATE_DIR="$HOME/.local/state/pj-sandbox"
INCLUDE="$HOME/.ssh/pj-sandbox-next-config"
OLD_CONFIG="$HOME/.ssh/pj-sandbox-config"
mkdir -p "$HOME/.ssh" "$fixture/bin" "$STUB_DIR" "$GUEST_ROOT"
git config --global user.name tester
git config --global user.email tester@example.com
git config --global init.defaultBranch main

# Lima knows the instances listed in $STUB_DIR/instances; delete removes one.
cat > "$fixture/bin/limactl" <<'STUB'
#!/bin/sh
case "$1" in
	list)
		[ "$2" = --json ] || { echo "unexpected limactl call: $*" >&2; exit 3; }
		[ -f "$STUB_DIR/instances" ] || exit 0
		while read -r name; do
			printf '{"name":"%s","status":"Running","config":{"user":{"name":"tester"}}}\n' "$name"
		done < "$STUB_DIR/instances"
		;;
	delete)
		printf 'limactl %s\n' "$*" >> "$STUB_DIR/calls"
		[ "$2" = --force ] || { echo "unexpected limactl call: $*" >&2; exit 3; }
		grep -vxF "$3" "$STUB_DIR/instances" > "$STUB_DIR/instances.new" || true
		mv "$STUB_DIR/instances.new" "$STUB_DIR/instances"
		;;
	*)
		echo "unexpected limactl call: $*" >&2
		exit 3
		;;
esac
STUB

REAL_GIT="$(command -v git)"
export REAL_GIT
cat > "$fixture/ssh-shim" <<'STUB'
#!/bin/sh
# git first probes the ssh variant with -G; only real calls are recorded.
[ "$1" != -G ] || exit 0
printf 'fetch %s\n' "$*" >> "$STUB_DIR/calls"
[ -z "${SSH_FAIL:-}" ] || exit 1
for remote_cmd in "$@"; do :; done
eval "set -- $remote_cmd"
exec "$REAL_GIT" upload-pack "$GUEST_ROOT$2"
STUB
chmod +x "$fixture/bin/limactl" "$fixture/ssh-shim"
export GIT_SSH_COMMAND="$fixture/ssh-shim"
export PATH="$fixture/bin:$PATH"

repo="$fixture/repo"
git init -q "$repo"
git -C "$repo" commit -q --allow-empty -m first
git -C "$repo" branch feature-a
git -C "$repo" branch other
git -C "$repo" update-ref refs/sandbox/feature-a/feature-a HEAD
git -C "$repo" update-ref refs/sandbox/feature-a/extra HEAD
refs_before="$(git -C "$repo" for-each-ref --format='%(objectname) %(refname)')"

ws="$GUEST_ROOT/workspace"
git clone -q --branch feature-a "$repo" "$ws"
git -C "$ws" commit -q --allow-empty -m "guest work"
guest_commit="$(git -C "$ws" rev-parse HEAD)"

# setup: a record, a live instance and a Host block for feature-a and for
# other, plus the old sandbox's include file with a pjsb- lookalike in it.
setup() {
	rm -rf "$STATE_DIR"
	: > "$STUB_DIR/calls"
	for task in feature-a other; do
		mkdir -p "$STATE_DIR/$task"
		printf '%s\n' "task=$task" "instance=pjsb-$task" "repo=$repo" "branch=$task" base=none \
			ssh_port=61022 > "$STATE_DIR/$task/meta"
		touch "$STATE_DIR/$task/proxy.log"
	done
	printf '%s\n' pjsb-feature-a pjsb-other pj-sbx-thing > "$STUB_DIR/instances"
	printf '%s\n' "Host pjsb-feature-a" "  HostName 127.0.0.1" "  Port 61022" "" \
		"Host pjsb-other" "  HostName 127.0.0.1" "  Port 61024" > "$INCLUDE"
	printf '%s\n' "Host pjsb-feature-a" "  HostName 127.0.0.1" > "$OLD_CONFIG"
	cp "$OLD_CONFIG" "$fixture/old-config-before"
}

# --- rm ---

setup
if out="$("$CLI" rm feature-a 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "rm exits 0 (output: $out)"
assert_eq "limactl delete --force pjsb-feature-a" "$(cat "$STUB_DIR/calls")" \
	"rm deletes exactly pjsb-<slug>, and nothing else"
assert_eq "$(printf '%s\n' pjsb-other pj-sbx-thing)" "$(cat "$STUB_DIR/instances")" \
	"every other instance is still there"
assert_not_contains "$(cat "$INCLUDE")" "pjsb-feature-a" "rm removes the task's Host block"
assert_eq "$(printf '%s\n' "Host pjsb-other" "  HostName 127.0.0.1" "  Port 61024")" "$(cat "$INCLUDE")" \
	"rm leaves every other Host block as it was"
assert_not_ok "rm removes the task's whole state dir" test -e "$STATE_DIR/feature-a"
assert_ok "rm leaves other tasks' state alone" test -f "$STATE_DIR/other/meta"
assert_eq "$refs_before" "$(git -C "$repo" for-each-ref --format='%(objectname) %(refname)')" \
	"rm leaves the host branch and refs/sandbox/<task>/* alone"
assert_eq "$(cat "$fixture/old-config-before")" "$(cat "$OLD_CONFIG")" \
	"rm never writes ~/.ssh/pj-sandbox-config"

# The instance is already gone: rm still clears the rest, without a delete.
setup
grep -vxF pjsb-feature-a "$STUB_DIR/instances" > "$STUB_DIR/i" && mv "$STUB_DIR/i" "$STUB_DIR/instances"
if out="$("$CLI" rm feature-a 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "rm of a task whose VM is already gone exits 0 (output: $out)"
assert_eq "" "$(cat "$STUB_DIR/calls")" "rm doesn't ask Lima to delete a VM it doesn't have"
assert_not_ok "rm still removes the state dir" test -e "$STATE_DIR/feature-a"
assert_not_contains "$(cat "$INCLUDE")" "pjsb-feature-a" "rm still removes the Host block"

# --- rm --fetch ---

setup
if out="$("$CLI" rm feature-a --fetch 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "rm --fetch exits 0 (output: $out)"
calls="$(cut -d" " -f1 "$STUB_DIR/calls")"
assert_eq "$(printf "%s\n" fetch limactl)" "$calls" "rm --fetch fetches before it deletes"
assert_contains "$(head -1 "$STUB_DIR/calls")" "pjsb-feature-a" "rm --fetch fetches from the task's instance"
assert_eq "$guest_commit" "$(git -C "$repo" rev-parse refs/sandbox/feature-a/feature-a)" \
	"rm --fetch leaves the fetched ref in place"
assert_not_ok "rm --fetch removes the state dir" test -e "$STATE_DIR/feature-a"
git -C "$repo" update-ref refs/sandbox/feature-a/feature-a refs/heads/feature-a

# A failed fetch stops rm before anything is deleted.
setup
if out="$(SSH_FAIL=1 "$CLI" rm --fetch feature-a 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "rm --fetch exits 1 when the fetch fails"
assert_not_contains "$(cat "$STUB_DIR/calls")" "limactl delete" "a failed fetch deletes no VM"
assert_ok "a failed fetch keeps the state record" test -f "$STATE_DIR/feature-a/meta"
assert_contains "$(cat "$INCLUDE")" "Host pjsb-feature-a" "a failed fetch keeps the Host block"

# --- refusals ---

if out="$("$CLI" rm 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "rm with no task exits 1"
assert_contains "$out" "Usage: pj-sandbox rm" "rm with no task prints usage"

if out="$("$CLI" rm feature-a --bogus 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "rm with an unknown option exits 1"

if out="$("$CLI" rm no-such-task 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "rm of an unknown task exits 1"
assert_contains "$out" "no sandbox task 'no-such-task'" "rm of an unknown task says so"

# A record naming an instance outside the pjsb- namespace is never deleted.
setup
printf '%s\n' task=other instance=pj-sbx-thing "repo=$repo" branch=other > "$STATE_DIR/other/meta"
if out="$("$CLI" rm other 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "rm refuses a record whose instance lacks the pjsb- prefix"
assert_eq "" "$(cat "$STUB_DIR/calls")" "rm never deletes a non-pjsb- instance"

# Lima can't be asked: rm can't tell whether the VM is gone, so it stops.
setup
cat > "$fixture/bin/limactl-fail" <<'STUB'
#!/bin/sh
exit 1
STUB
chmod +x "$fixture/bin/limactl-fail"
mv "$fixture/bin/limactl" "$fixture/bin/limactl-ok"
mv "$fixture/bin/limactl-fail" "$fixture/bin/limactl"
if out="$("$CLI" rm feature-a 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "rm exits 1 when limactl list fails"
assert_ok "rm keeps the record when it couldn't check Lima" test -f "$STATE_DIR/feature-a/meta"
mv "$fixture/bin/limactl-ok" "$fixture/bin/limactl"

assert_report
