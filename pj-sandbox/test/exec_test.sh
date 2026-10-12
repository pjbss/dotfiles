#!/bin/bash
# exec_test.sh
#
# Tests for `pj-sandbox exec`, `run` and `attach`, run through the real
# dispatcher. ssh hands the guest one string for its shell to re-split, so a
# stub ssh first on PATH records its argv and then `eval`s that remote string
# locally -- with `cd` redirected under GUEST_ROOT -- so what's checked is the
# argument vector that actually arrives, not how the string looks. A stub
# limactl says which instances are running.

set -euo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PJ_SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"
. "$TEST_DIR/../../test/assert.sh"

CLI="$PJ_SANDBOX_DIR/bin/pj-sandbox"

fixture="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "$fixture"' EXIT

export HOME="$fixture/home"
export PJ_SANDBOX_STATE_DIR="$fixture/state"
export PJ_SANDBOX_DOTFILES_HOME="$fixture/unused"
export STUB_DIR="$fixture/stub"
export GUEST_ROOT="$fixture/guest"
mkdir -p "$HOME" "$fixture/bin" "$fixture/guest-bin" "$STUB_DIR" "$GUEST_ROOT/workspace"

cat > "$fixture/bin/limactl" <<'STUB'
#!/bin/sh
[ "$1 $2" = "list --json" ] || { echo "unexpected limactl call: $*" >&2; exit 3; }
[ -n "${LIMACTL_FAIL:-}" ] && exit 1
echo '{"name":"pjsb-alpha","status":"Running","config":{"user":{"name":"tester"}}}'
echo '{"name":"pjsb-beta","status":"Stopped","config":{"user":{"name":"tester"}}}'
STUB

# Each argv entry is written NUL-terminated, so one with a newline in it can't
# be mistaken for two. The remote command is the last argument.
cat > "$fixture/bin/ssh" <<'STUB'
#!/bin/sh
printf '%s\0' "$@" > "$STUB_DIR/ssh-argv"
for remote_cmd in "$@"; do :; done
[ "${STUB_SSH_EVAL:-yes}" = yes ] || exit 0
cd() { command cd "$GUEST_ROOT$1"; }
PATH="$GUEST_BIN:$PATH"
eval "$remote_cmd"
STUB

# Prints each argument it receives as [arg], NUL-terminated, plus where it ran.
cat > "$fixture/guest-bin/argv" <<'STUB'
#!/bin/sh
pwd > "$STUB_DIR/guest-pwd"
for arg in "$@"; do printf '[%s]\0' "$arg"; done > "$STUB_DIR/guest-argv"
exit "${GUEST_STATUS:-0}"
STUB
cp "$fixture/guest-bin/argv" "$fixture/guest-bin/pj-run-issues"
chmod +x "$fixture/bin/"* "$fixture/guest-bin/"*
export GUEST_BIN="$fixture/guest-bin"
export PATH="$fixture/bin:$PATH"

for task in alpha beta; do
	mkdir -p "$PJ_SANDBOX_STATE_DIR/$task"
	printf '%s\n' "task=$task" "instance=pjsb-$task" "repo=$fixture/repo" "branch=$task" \
		> "$PJ_SANDBOX_STATE_DIR/$task/meta"
done

# expected ARG... -- the [arg]\0 stream the guest stub writes for ARG...
expected() {
	for arg in "$@"; do printf '[%s]\0' "$arg"; done | od -c
}
guest_argv() {
	od -c < "$STUB_DIR/guest-argv"
}
reset_stubs() {
	rm -f "$STUB_DIR"/*
}

# --- exec: argument boundaries survive the hop ---

tricky=('two words' "it's" 'say "hi"' '$HOME' '`id`' '' 'a
b' 'trailing
' '*' '\back' ';' 'x&&y')

reset_stubs
if out="$("$CLI" exec alpha -- argv "${tricky[@]}" 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "exec of a succeeding command exits 0 (output: $out)"
assert_eq "$(expected "${tricky[@]}")" "$(guest_argv)" \
	"spaces, quotes, \$, backticks, empty strings and newlines all arrive unchanged"
assert_eq "$GUEST_ROOT/workspace" "$(cat "$STUB_DIR/guest-pwd")" "exec runs the command in /workspace"
assert_eq "pjsb-alpha" "$(tr '\0' '\n' < "$STUB_DIR/ssh-argv" | head -1)" \
	"exec reaches the guest through the instance's Host entry"
assert_not_contains "$(tr '\0' '\n' < "$STUB_DIR/ssh-argv")" "-t" "exec doesn't ask for a tty"

reset_stubs
if out="$(GUEST_STATUS=42 "$CLI" exec alpha -- argv 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 42 "$rc" "exec passes the command's exit status through"

reset_stubs
if out="$("$CLI" exec alpha argv 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "exec without -- exits 1"
assert_contains "$out" "Usage: pj-sandbox exec" "exec without -- prints usage"
if out="$("$CLI" exec alpha -- 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "exec with no command exits 1"
assert_not_ok "a usage error never calls ssh" test -e "$STUB_DIR/ssh-argv"

# --- run: the issue loop, with --test-cmd intact (port of a3e036d's test) ---

reset_stubs
if out="$("$CLI" run alpha --test-cmd 'make -C backend test' --max-issues 3 --no-review 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "run exits 0 when the loop does (output: $out)"
assert_eq "$(expected --test-cmd 'make -C backend test' --max-issues 3 --no-review)" "$(guest_argv)" \
	"--test-cmd 'make -C backend test' reaches pj-run-issues as one argument"
assert_eq "$GUEST_ROOT/workspace" "$(cat "$STUB_DIR/guest-pwd")" "run starts the loop in /workspace"
assert_eq "-t pjsb-alpha" "$(tr '\0' '\n' < "$STUB_DIR/ssh-argv" | head -2 | paste -sd' ' -)" \
	"run uses ssh -t with the instance's Host entry"

reset_stubs
if out="$("$CLI" run alpha --test-cmd 'echo $HOME; it'"'"'s' 2>&1)"; then rc=0; else rc=$?; fi
assert_eq "$(expected --test-cmd 'echo $HOME; it'"'"'s')" "$(guest_argv)" \
	"a --test-cmd holding \$, ; and a quote isn't expanded or split in the guest"

reset_stubs
if out="$(GUEST_STATUS=3 "$CLI" run alpha 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 3 "$rc" "run passes the loop's exit status through"
assert_eq "" "$(guest_argv)" "run with no loop args passes none"

if out="$("$CLI" run 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "run with no task exits 1"
assert_contains "$out" "Usage: pj-sandbox run" "run with no task prints usage"

# --- attach: an interactive shell in /workspace ---

# The remote string starts a login shell, so the stub only records it.
reset_stubs
if out="$(STUB_SSH_EVAL=no "$CLI" attach alpha 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "attach exits 0 (output: $out)"
ssh_argv="$(tr '\0' '\n' < "$STUB_DIR/ssh-argv")"
assert_eq "-t pjsb-alpha" "$(printf '%s\n' "$ssh_argv" | head -2 | paste -sd' ' -)" \
	"attach invokes ssh -t with the instance's Host entry"
assert_contains "$(printf '%s\n' "$ssh_argv" | tail -1)" "cd /workspace && " "attach starts the shell in /workspace"

if out="$("$CLI" attach 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "attach with no task exits 1"
assert_contains "$out" "Usage: pj-sandbox attach" "attach with no task prints usage"

# --- refusals: unknown or stopped tasks never reach ssh ---

for sub in exec run attach; do
	args=()
	[ "$sub" = exec ] && args=(-- argv)
	for task in no-such-task beta; do
		reset_stubs
		if out="$("$CLI" "$sub" "$task" "${args[@]+"${args[@]}"}" 2>&1)"; then rc=0; else rc=$?; fi
		assert_exit_code 1 "$rc" "$sub of '$task' exits 1"
		assert_not_ok "$sub of '$task' never calls ssh" test -e "$STUB_DIR/ssh-argv"
	done
	if out="$("$CLI" "$sub" no-such-task "${args[@]+"${args[@]}"}" 2>&1)"; then :; fi
	assert_contains "$out" "no sandbox task 'no-such-task'" "$sub of an unknown task says so"
	if out="$("$CLI" "$sub" beta "${args[@]+"${args[@]}"}" 2>&1)"; then :; fi
	assert_contains "$out" "'beta' isn't running (status: Stopped)" "$sub of a stopped task says so"
done

reset_stubs
if out="$(LIMACTL_FAIL=1 "$CLI" exec alpha -- argv 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "exec refuses when Lima can't say the VM is running"
assert_not_ok "an unknown live status never calls ssh" test -e "$STUB_DIR/ssh-argv"

assert_report
