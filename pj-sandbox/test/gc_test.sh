#!/bin/bash
# gc_test.sh
#
# Tests for `pj-sandbox gc`, run through the real dispatcher with a stub
# limactl first on PATH. Lima reports pjsb-orphan (no record), pjsb-live (has
# a record) and pj-sbx-thing (the old sandbox's); the state dir also holds a
# record for a VM that's gone, once past the grace period and once inside it.

set -euo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PJ_SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"
. "$TEST_DIR/../../test/assert.sh"

CLI="$PJ_SANDBOX_DIR/bin/pj-sandbox"

fixture="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "$fixture"' EXIT

unset PJ_SANDBOX_STATE_DIR PJ_SANDBOX_SSH_INCLUDE_FILE PJ_SANDBOX_SSH_CONFIG_FILE \
	PJ_SANDBOX_INSTANCE_PREFIX PJ_SANDBOX_GC_GRACE_MINUTES XDG_STATE_HOME XDG_CONFIG_HOME
export HOME="$fixture/home"
export STUB_DIR="$fixture/stub"
export PJ_SANDBOX_DOTFILES_HOME="$fixture/unused"
STATE_DIR="$HOME/.local/state/pj-sandbox"
INCLUDE="$HOME/.ssh/pj-sandbox-next-config"
OLD_CONFIG="$HOME/.ssh/pj-sandbox-config"
mkdir -p "$HOME/.ssh" "$fixture/bin" "$STUB_DIR"

cat > "$fixture/bin/limactl" <<'STUB'
#!/bin/sh
case "$1" in
	list)
		[ "$2" = --json ] || { echo "unexpected limactl call: $*" >&2; exit 3; }
		[ -z "${LIMACTL_FAIL:-}" ] || exit 1
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
chmod +x "$fixture/bin/limactl"
export PATH="$fixture/bin:$PATH"

# record TASK INSTANCE
record() {
	mkdir -p "$STATE_DIR/$1"
	printf '%s\n' "task=$1" "instance=$2" branch=main > "$STATE_DIR/$1/meta"
}

host_block() {
	printf '%s\n' "Host $1" "  HostName 127.0.0.1" "  Port 61022"
}

setup() {
	rm -rf "$STATE_DIR"
	: > "$STUB_DIR/calls"
	printf '%s\n' pjsb-orphan pjsb-live pj-sbx-thing > "$STUB_DIR/instances"
	record live pjsb-live
	record stale-old pjsb-stale-old
	touch "$STATE_DIR/stale-old/proxy.log"
	# Two days old: well past the default grace period.
	touch -t "$(date -v-2d +%Y%m%d%H%M 2>/dev/null || date -d '2 days ago' +%Y%m%d%H%M)" \
		"$STATE_DIR/stale-old/meta"
	record stale-new pjsb-stale-new
	# Five minutes old: inside the default grace period.
	touch -t "$(date -v-5M +%Y%m%d%H%M 2>/dev/null || date -d "5 minutes ago" +%Y%m%d%H%M)" \
		"$STATE_DIR/stale-new/meta"
	{
		host_block pjsb-live; echo
		host_block pjsb-orphan; echo
		host_block pjsb-stale-old; echo
		host_block pjsb-stale-new; echo
		host_block pjsb-stray; echo
		host_block not-ours
	} > "$INCLUDE"
	cp "$INCLUDE" "$fixture/include-before"
	printf '%s\n' "Host pjsb-old-stray" "  HostName 127.0.0.1" > "$OLD_CONFIG"
	cp "$OLD_CONFIG" "$fixture/old-config-before"
	cp -R "$STATE_DIR" "$fixture/state-before"
}

# --- gc --dry-run ---

setup
if out="$("$CLI" gc --dry-run 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "gc --dry-run exits 0 (output: $out)"
assert_eq "" "$(cat "$STUB_DIR/calls")" "gc --dry-run deletes no instance"
assert_eq "$(printf '%s\n' pjsb-orphan pjsb-live pj-sbx-thing)" "$(cat "$STUB_DIR/instances")" \
	"gc --dry-run leaves every instance in place"
assert_eq "$(cat "$fixture/include-before")" "$(cat "$INCLUDE")" "gc --dry-run leaves the include file alone"
assert_ok "gc --dry-run leaves the state dir alone" diff -r "$fixture/state-before" "$STATE_DIR"
assert_contains "$out" "would delete instance pjsb-orphan" "gc --dry-run lists the orphaned instance"
assert_contains "$out" "would delete state stale-old" "gc --dry-run lists the stale record"
assert_contains "$out" "would delete ssh entry pjsb-stray" "gc --dry-run lists a stray Host entry"
assert_not_contains "$out" "pjsb-live" "gc --dry-run doesn't list the live task"
assert_not_contains "$out" "pj-sbx-thing" "gc --dry-run doesn't list a pj-sbx-style instance"
assert_not_contains "$out" "stale-new" "gc --dry-run doesn't list a record still in its grace period"
rm -rf "$fixture/state-before"

# --- gc ---

setup
if out="$("$CLI" gc 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "gc exits 0 (output: $out)"
assert_eq "limactl delete --force pjsb-orphan" "$(cat "$STUB_DIR/calls")" "gc deletes only pjsb-orphan"
assert_eq "$(printf '%s\n' pjsb-live pj-sbx-thing)" "$(cat "$STUB_DIR/instances")" \
	"gc leaves the recorded pjsb- instance and the pj-sbx-style one"
assert_not_ok "gc deletes a record whose VM is gone, once past the grace period" test -e "$STATE_DIR/stale-old"
assert_ok "gc keeps a record whose VM is gone but that is inside the grace period" test -f "$STATE_DIR/stale-new/meta"
assert_ok "gc keeps a live task's record" test -f "$STATE_DIR/live/meta"
assert_eq "$({ host_block pjsb-live; echo; host_block pjsb-stale-new; echo; host_block not-ours; })" "$(cat "$INCLUDE")" \
	"gc removes Host entries no record claims, and only pjsb- ones"
assert_eq "$(cat "$fixture/old-config-before")" "$(cat "$OLD_CONFIG")" \
	"gc never writes ~/.ssh/pj-sandbox-config"
rm -rf "$fixture/state-before"

# A one-minute grace period lets the five-minute-old stale record go too.
setup
if out="$(PJ_SANDBOX_GC_GRACE_MINUTES=1 "$CLI" gc 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "gc with a one-minute grace period exits 0 (output: $out)"
assert_not_ok "PJ_SANDBOX_GC_GRACE_MINUTES sets the grace period" test -e "$STATE_DIR/stale-new"
rm -rf "$fixture/state-before"

# --- refusals ---

# Lima can't be asked: every record would look orphaned, so gc does nothing.
setup
if out="$(LIMACTL_FAIL=1 "$CLI" gc 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "gc exits 1 when limactl list fails"
assert_ok "gc deletes no state when it couldn't ask Lima" diff -r "$fixture/state-before" "$STATE_DIR"
assert_eq "$(cat "$fixture/include-before")" "$(cat "$INCLUDE")" "gc removes no Host entry when it couldn't ask Lima"
rm -rf "$fixture/state-before"

if out="$("$CLI" gc --bogus 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "gc with an unknown argument exits 1"
assert_contains "$out" "Usage: pj-sandbox gc" "gc with an unknown argument prints usage"

if out="$(PJ_SANDBOX_GC_GRACE_MINUTES=soon "$CLI" gc 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "gc refuses a non-numeric grace period"

assert_report
