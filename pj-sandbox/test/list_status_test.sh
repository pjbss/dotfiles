#!/bin/bash
# list_status_test.sh
#
# Tests for `pj-sandbox list` and `pj-sandbox status`, run through the real
# dispatcher with a stub `limactl` first on PATH. Tasks come from the state
# dir; live status is merged in from `limactl list --json`, and only for
# pjsb- instances.

set -euo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PJ_SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"
. "$TEST_DIR/../../test/assert.sh"

CLI="$PJ_SANDBOX_DIR/bin/pj-sandbox"

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

export HOME="$fixture/home"
export PJ_SANDBOX_STATE_DIR="$fixture/state"
mkdir -p "$HOME/.ssh" "$fixture/bin"

# The ssh include files both sandboxes write. Each names a host that has no
# state record; if either were read to discover tasks, that host would show up.
printf 'Host ghost-old\n  HostName 127.0.0.1\n' > "$HOME/.ssh/pj-sandbox-config"
printf 'Host pjsb-ghost-next\n  HostName 127.0.0.1\n' > "$HOME/.ssh/pj-sandbox-next-config"

# Real `limactl list --json` prints one object per line, and each carries a
# nested config.user.name that must not be mistaken for the instance name.
cat > "$fixture/bin/limactl" <<'STUB'
#!/bin/sh
[ "$1 $2" = "list --json" ] || { echo "unexpected limactl call: $*" >&2; exit 3; }
[ -n "${LIMACTL_FAIL:-}" ] && exit 1
cat <<'JSON'
{"name":"pjsb-alpha","status":"Running","sshLocalPort":61022,"config":{"user":{"name":"tester"}}}
{"name":"pjsb-beta","status":"Stopped","sshLocalPort":61024,"config":{"user":{"name":"tester"}}}
{"name":"old-task","status":"Running","sshLocalPort":60022,"config":{"user":{"name":"pjsb-gamma"}}}
{"name":"pj-sbx-thing","status":"Running","sshLocalPort":60023}
{"name":"pjsb-unrecorded","status":"Running","sshLocalPort":61030}
JSON
STUB
chmod +x "$fixture/bin/limactl"
export PATH="$fixture/bin:$PATH"

# record TASK KEY=VALUE...
record() {
	sh -c 'PJ_SANDBOX_DOTFILES_HOME=/unused; . "$1/lib/namespace.sh"; . "$1/lib/state.sh"; shift; pj_sandbox_state_write "$@"' \
		sh "$PJ_SANDBOX_DIR" "$@"
}

# --- empty state dir ---

if out="$("$CLI" list 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "list with no tasks exits 0"
assert_not_contains "$out" "ghost" "list doesn't discover tasks from either ssh include file"
assert_not_contains "$out" "pjsb-unrecorded" "list doesn't show a pjsb- VM that has no state record"
assert_eq "[]" "$("$CLI" list --json)" "list --json with no tasks is an empty array"

# --- a mix of tasks ---

record alpha task=alpha instance=pjsb-alpha branch=main ssh_port=61022
record beta task=beta instance=pjsb-beta branch=feat/b ssh_port=61024
record gone task=gone instance=pjsb-gone branch=main
# Recorded against a name Lima reports as Running, but without the pjsb-
# prefix: pj-sandbox never claims a VM outside its namespace.
record gamma task=gamma instance=old-task branch=main
record weird task=weird instance=pjsb-weird repo='/r/"q" \b' branch='tab	x'

out="$("$CLI" list)"
alpha_line="$(printf '%s\n' "$out" | grep '^alpha ' || true)"
beta_line="$(printf '%s\n' "$out" | grep '^beta ' || true)"
gone_line="$(printf '%s\n' "$out" | grep '^gone ' || true)"
gamma_line="$(printf '%s\n' "$out" | grep '^gamma ' || true)"
assert_contains "$alpha_line" "Running" "list merges a running pjsb- VM's live status"
assert_contains "$beta_line" "Stopped" "list merges a stopped pjsb- VM's live status"
assert_contains "$gone_line" "missing" "list shows a recorded VM Lima doesn't know about as missing"
assert_contains "$gamma_line" "missing" "list ignores Lima instances without the pjsb- prefix, even for a recorded name"
assert_not_contains "$out" "pj-sbx-thing" "list never shows a pj-sbx-style Lima instance"
assert_not_contains "$out" "pjsb-unrecorded" "list never shows a pjsb- VM that has no state record"
assert_not_contains "$out" "ghost" "list still ignores both ssh include files"
assert_eq "$(printf '%s\n' TASK alpha beta gamma gone weird)" "$(printf '%s\n' "$out" | awk '{ print $1 }')" "list prints a header then one line per recorded task, sorted"

# --- list --json ---

json="$("$CLI" list --json)"
assert_ok "list --json passes python3 -m json.tool" sh -c 'printf "%s" "$1" | python3 -m json.tool' sh "$json"
got="$(printf '%s' "$json" | python3 -c '
import json, sys
for t in json.load(sys.stdin):
    print(t["task"], t["status"], repr(t.get("repo")), repr(t["branch"]))
')"
assert_eq "$(printf '%s\n' \
	"alpha Running None 'main'" \
	"beta Stopped None 'feat/b'" \
	"gamma missing None 'main'" \
	"gone missing None 'main'" \
	"weird missing '/r/\"q\" \\\\b' 'tab\\tx'")" "$got" "list --json carries every task's record and status, with quotes, backslashes and tabs intact"

# --- status ---

if out="$("$CLI" status alpha 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "status of a known task exits 0"
assert_contains "$out" "instance=pjsb-alpha" "status shows the task's record"
assert_contains "$out" "ssh_port=61022" "status shows every recorded field"
assert_contains "$out" "status=Running" "status shows the live status"
assert_contains "$("$CLI" status gone)" "status=missing" "status shows a recorded VM Lima doesn't know about as missing"

json="$("$CLI" status weird --json)"
assert_ok "status --json passes python3 -m json.tool" sh -c 'printf "%s" "$1" | python3 -m json.tool' sh "$json"
got="$(printf '%s' "$json" | python3 -c 'import json, sys; d = json.load(sys.stdin); print(d["repo"]); print(d["branch"]); print(d["status"])')"
assert_eq "$(printf '%s\n' '/r/"q" \b' 'tab	x' missing)" "$got" "status --json round-trips values with quotes, backslashes and tabs"

if out="$("$CLI" status nosuch 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "status of an unknown task exits 1"
assert_contains "$out" "no sandbox task 'nosuch'" "status of an unknown task says so"

if out="$("$CLI" status 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "status with no task exits 1"
assert_contains "$out" "Usage:" "status with no task prints usage"

if out="$("$CLI" list --bogus 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "list with an unknown option exits 1"

# --- limactl unavailable ---

if out="$(LIMACTL_FAIL=1 "$CLI" list 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "list still works when limactl fails"
assert_contains "$(printf '%s\n' "$out" | grep '^alpha ' || true)" "unknown" "a failed limactl call shows status unknown, not missing"

# --- never reads the ssh include files ---

refs="$(grep -nE 'pj-sandbox(-next)?-config|PJ_SANDBOX_SSH_INCLUDE_FILE' \
	"$PJ_SANDBOX_DIR/lib/state.sh" "$PJ_SANDBOX_DIR/lib/lima.sh" \
	"$PJ_SANDBOX_DIR/lib/cmd_list.sh" "$PJ_SANDBOX_DIR/lib/cmd_status.sh" 2>&1 | grep -v ':[0-9]*:#' || true)"
assert_eq "" "$refs" "no list/status code references either ssh include file outside comments"

assert_report
