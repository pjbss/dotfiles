#!/bin/bash
# state_test.sh
#
# Tests for pj-sandbox/lib/state.sh: the per-task <state dir>/<task>/meta
# record -- write/read/delete round-trip, atomic replacement, and its JSON
# rendering. Every case runs against a throwaway PJ_SANDBOX_STATE_DIR.

set -euo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PJ_SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"
. "$TEST_DIR/../../test/assert.sh"

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

export PJ_SANDBOX_STATE_DIR="$fixture/state"
export PJ_SANDBOX_DOTFILES_HOME="$fixture/dots"

# st SCRIPT
#
# Runs SCRIPT in a fresh sh with namespace.sh and state.sh sourced, so the
# library is exercised under POSIX sh rather than this file's bash.
st() {
	sh -c '. "$1/lib/namespace.sh"; . "$1/lib/state.sh"; eval "$2"' sh "$PJ_SANDBOX_DIR" "$1"
}

# --- write / read round-trip ---

st 'pj_sandbox_state_write my-task task=my-task instance=pjsb-my-task repo=/src/repo branch=feat/x base=default agents=claude,codex ssh_port=61022 ports=61023:8000 created=2026-10-02T10:00:00Z egress_mode=proxy'

assert_ok "write creates <state dir>/<task>/meta" test -f "$PJ_SANDBOX_STATE_DIR/my-task/meta"
assert_eq "pjsb-my-task" "$(st 'pj_sandbox_state_get my-task instance')" "get reads back a written key"
assert_eq "61023:8000" "$(st 'pj_sandbox_state_get my-task ports')" "get reads back a value containing ':'"
assert_eq "feat/x" "$(st 'pj_sandbox_state_get my-task branch')" "get reads back a value containing '/'"
assert_eq "$(printf '%s\n' task=my-task instance=pjsb-my-task repo=/src/repo branch=feat/x base=default agents=claude,codex ssh_port=61022 ports=61023:8000 created=2026-10-02T10:00:00Z egress_mode=proxy)" \
	"$(cat "$PJ_SANDBOX_STATE_DIR/my-task/meta")" "meta is plain key=value lines"

st 'pj_sandbox_state_write odd task=odd repo="/a b/c=d\\e\"f"'
assert_eq '/a b/c=d\e"f' "$(st 'pj_sandbox_state_get odd repo')" "a value with spaces, '=', backslashes and quotes round-trips unchanged"
assert_eq "" "$(st 'pj_sandbox_state_get odd branch')" "get of a key the record doesn't hold prints nothing"

assert_ok "exists is true for a written task" st 'pj_sandbox_state_exists my-task'
assert_not_ok "exists is false for an unknown task" st 'pj_sandbox_state_exists nope'
assert_not_ok "get of an unknown task fails" st 'pj_sandbox_state_get nope instance'

assert_eq "$(printf '%s\n' my-task odd | sort)" "$(st 'pj_sandbox_state_tasks')" "tasks lists every recorded task, sorted"

# --- rewrite replaces the whole record ---

st 'pj_sandbox_state_write odd task=odd branch=main'
assert_eq "$(printf '%s\n' task=odd branch=main)" "$(cat "$PJ_SANDBOX_STATE_DIR/odd/meta")" "a second write replaces the record rather than appending"

# --- update changes only the fields it's given ---

st 'pj_sandbox_state_write upd task=upd repo="/a b/*" branch=main fetched=old'
st 'pj_sandbox_state_update upd fetched=2026-10-05T12:00:00Z ports=61023:8000'
assert_eq "$(printf '%s\n' task=upd 'repo=/a b/*' branch=main ports=61023:8000 fetched=2026-10-05T12:00:00Z)" \
	"$(cat "$PJ_SANDBOX_STATE_DIR/upd/meta")" "update sets the given fields and keeps the rest, unglobbed, in key order"
assert_not_ok "update of an unknown task fails" st 'pj_sandbox_state_update nope fetched=x'
assert_not_ok "update of an unknown task writes no record" test -e "$PJ_SANDBOX_STATE_DIR/nope"
assert_not_ok "update refuses an unknown key" st 'pj_sandbox_state_update upd colour=red'
st 'pj_sandbox_state_delete upd'

# --- validation ---

assert_not_ok "an unknown key is refused" st 'pj_sandbox_state_write bad task=bad colour=red'
assert_not_ok "a value containing a newline is refused" st 'pj_sandbox_state_write bad "task=bad
injected=1"'
assert_not_ok "an argument without '=' is refused" st 'pj_sandbox_state_write bad task'
for name in "" "a/b" ".." ".hidden"; do
	assert_not_ok "task name '$name' is refused" st "pj_sandbox_state_write '$name' task=x"
done
assert_ok "no record is left behind by a refused write" test ! -e "$PJ_SANDBOX_STATE_DIR/bad"

# --- delete ---

st 'pj_sandbox_state_delete odd'
assert_ok "delete removes the task's record" test ! -e "$PJ_SANDBOX_STATE_DIR/odd/meta"
assert_not_ok "a deleted task no longer exists" st 'pj_sandbox_state_exists odd'
assert_eq "my-task" "$(st 'pj_sandbox_state_tasks')" "a deleted task is no longer listed"
assert_not_ok "deleting an unknown task fails" st 'pj_sandbox_state_delete nope'

# --- atomic write ---

before="$(cat "$PJ_SANDBOX_STATE_DIR/my-task/meta")"

# The rename never happens: the old record must survive whole, with no temp
# file left beside it.
assert_not_ok "a write whose rename fails reports failure" \
	st 'mv() { return 1; }; pj_sandbox_state_write my-task task=my-task branch=CHANGED'
assert_eq "$before" "$(cat "$PJ_SANDBOX_STATE_DIR/my-task/meta")" "a failed rename leaves the previous record intact"
assert_eq "meta" "$(ls -A "$PJ_SANDBOX_STATE_DIR/my-task")" "a failed rename leaves no temp file behind"

# Interrupted by a signal between writing the temp file and renaming it.
assert_not_ok "a write interrupted by SIGTERM reports failure" \
	st 'mv() { sh -c "kill -TERM \$PPID"; }; pj_sandbox_state_write my-task task=my-task branch=CHANGED'
assert_eq "$before" "$(cat "$PJ_SANDBOX_STATE_DIR/my-task/meta")" "an interrupted write leaves the previous record intact"
assert_eq "meta" "$(ls -A "$PJ_SANDBOX_STATE_DIR/my-task")" "an interrupted write leaves no temp file behind"

# A brand-new task interrupted the same way leaves no meta at all.
assert_not_ok "an interrupted first write reports failure" \
	st 'mv() { sh -c "kill -TERM \$PPID"; }; pj_sandbox_state_write fresh task=fresh'
assert_ok "an interrupted first write leaves no meta" test ! -e "$PJ_SANDBOX_STATE_DIR/fresh/meta"
assert_eq "my-task" "$(st 'pj_sandbox_state_tasks')" "an interrupted first write isn't listed as a task"

# --- JSON rendering ---

st 'pj_sandbox_state_write jt task=jt repo="C:\\dir \"quoted\"" branch="tab	here"'
json="$(st 'pj_sandbox_state_json jt Running')"
if parsed="$(printf '%s' "$json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["repo"]); print(d["branch"]); print(d["status"]); print(d["task"])')"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "state_json output parses as JSON (got: $json)"
assert_eq "$(printf '%s\n' 'C:\dir "quoted"' 'tab	here' Running jt)" "$parsed" "state_json escapes quotes, backslashes and tabs, and adds status"
assert_ok "state_json output passes python3 -m json.tool" sh -c 'printf "%s" "$1" | python3 -m json.tool >/dev/null' sh "$json"

assert_report
