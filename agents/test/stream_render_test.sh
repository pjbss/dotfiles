#!/bin/bash
# stream_render_test.sh
#
# Unit tests for agents/lib/stream_render.py, the renderer that turns a
# `claude -p --output-format stream-json` event stream into the labeled,
# colored lines bin/pj-run-issues prints while it drains the queue.
#
# Canned JSONL on stdin, assertions on what comes out: no `claude`, no model,
# no network. The fixtures below are trimmed from real streams captured off
# claude 2.1.273, so the field names are the ones actually on the wire rather
# than the ones the docs imply.
#
# The malformed-input cases matter as much as the happy path. This renderer
# sits mid-pipeline in an unattended loop that may run for hours; a schema that
# shifted under a claude upgrade has to degrade into an ugly line, never into
# a dead run.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
DOTFILES_HOME="$(cd -P "$TEST_DIR/../.." && pwd)"

. "$DOTFILES_HOME/test/assert.sh"

RENDER="$DOTFILES_HOME/agents/lib/stream_render.py"

fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

# render ARGS... -- feeds $input on stdin, leaves output in $out and status in $rc
render() {
	if out="$(printf '%s' "$input" | python3 -u "$RENDER" "$@" 2>&1)"; then
		rc=0
	else
		rc=$?
	fi
}

esc="$(printf '\033')"

# === tool calls =============================================================

input='{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"make test","description":"Run the suite"}}]},"parent_tool_use_id":null}
'
render --label tdd
assert_exit_code 0 "$rc" "a tool_use event renders without error"
assert_contains "$out" "tdd" "the rendered line carries the phase label"
assert_contains "$out" "Bash" "the rendered line names the tool"
assert_contains "$out" "make test" "the rendered line says what the tool was asked to do"

input='{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"'"$PWD"'/issues/003-slice.md"}}]}}
'
render --label tdd
assert_contains "$out" "issues/003-slice.md" "a file tool renders its path"
assert_not_contains "$out" "$PWD/issues" \
	"the path is relative to the project, so the part that differs isn't pushed off the edge"

input='{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Agent","input":{"subagent_type":"pj-test-auditor","description":"Audit the tests"}}]}}
'
render --label tdd
assert_contains "$out" "pj-test-auditor" "a subagent launch names the subagent, not just its description"

# === nesting ================================================================

# Work done inside a subagent carries parent_tool_use_id. "the implementer
# checked its own tests" and "a separate auditor checked them" are different
# claims, so the second is indented rather than flattened in.
input='{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Grep","input":{"pattern":"assert_"}}]},"parent_tool_use_id":"t1"}
'
render --label tdd
assert_contains "$out" "  ↳" "a subagent's work is indented under the phase that spawned it"

input='{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Grep","input":{"pattern":"assert_"}}]},"parent_tool_use_id":null}
'
render --label tdd
assert_not_contains "$out" "↳" "work the phase did itself is not indented"

# === tool results ===========================================================

input='{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"false"}}]}}
{"type":"user","message":{"content":[{"tool_use_id":"t1","type":"tool_result","content":"Exit code 1","is_error":true}]}}
'
render --label tdd
assert_contains "$out" "Exit code 1" "a failed tool says why it failed"
assert_contains "$out" "✗" "a failure is marked as one"
assert_contains "$out" "Bash" "the failure names the tool that failed"

input='{"type":"user","message":{"content":[{"tool_use_id":"t1","type":"tool_result","content":"a very long stdout dump","is_error":false}]},"tool_use_result":{"stdout":"a very long stdout dump"}}
'
render --label tdd
assert_eq "" "$out" "a successful tool result renders nothing -- silence on success is what makes a failure line mean something"

# === the result event =======================================================

input='{"type":"result","subtype":"success","is_error":false,"duration_ms":252000,"total_cost_usd":0.41}
'
render --label tdd
assert_contains "$out" "finished" "a completed phase says so"
assert_contains "$out" "4m12s" "the phase reports how long it took"
assert_contains "$out" "\$0.41" "the phase reports what it cost"

input='{"type":"result","subtype":"error_max_turns","is_error":true,"duration_ms":9000}
'
render --label rev
assert_contains "$out" "failed" "a phase that ended badly says so"
assert_contains "$out" "error_max_turns" "the failure names the subtype, so the reason is on screen"

# === assistant prose ========================================================

input='{"type":"assistant","message":{"content":[{"type":"text","text":"Verdict: approved"}]}}
'
render --label rev
assert_contains "$out" "Verdict: approved" "the agent's own words are shown"

# === noise ==================================================================

input='{"type":"system","subtype":"init","cwd":"/workspace","tools":["Bash"]}
{"type":"system","subtype":"hook_started","hook_name":"SessionStart:startup"}
{"type":"system","subtype":"hook_response","hook_name":"SessionStart:startup","exit_code":0}
{"type":"system","subtype":"commands_changed","commands":[{"name":"pj-tdd"}]}
{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}
'
render --label tdd
assert_eq "" "$out" "session bookkeeping, hook chatter and rate-limit heartbeats are dropped"
assert_exit_code 0 "$rc" "dropping noise is not an error"

# === malformed input ========================================================

# claude's own stderr shares this stream (run_claude merges 2>&1). Swallowing
# it would hide the one line that explains a crashed phase.
input='not json at all
'
render --label tdd
assert_exit_code 0 "$rc" "a non-JSON line does not fail the renderer"
assert_contains "$out" "not json at all" "a non-JSON line is passed through rather than swallowed -- it is where claude's stderr lands"

input='{"type":"assistant","message":{"content":[{"type":"tool_use"
{"type":"result"
[]
null
"a bare string"
{"type":"assistant","message":"not an object"}
{"type":"assistant","message":{"content":[null,{"type":"tool_use","name":"Read","input":null}]}}

'
render --label tdd
assert_exit_code 0 "$rc" "truncated JSON, wrong-typed fields and blank lines never take the run down"

# === logging ================================================================

logfile="$fixture_root/phase.log"
input='{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"make test"}}]}}
'
render --label tdd --log "$logfile" --color
assert_contains "$out" "$esc[" "--color puts escape sequences on the terminal stream"
assert_contains "$(cat "$logfile")" "make test" "the log gets the same line"
assert_not_contains "$(cat "$logfile")" "$esc" \
	"the log gets it without escapes -- a log full of escape sequences is a log nobody greps"

render --label tdd
assert_not_contains "$out" "$esc" "without --color the terminal stream is plain too"

# A second phase appends rather than truncating: three phases share one issue's
# log, and a review that erased the implementation's lines would be worse than
# no log at all.
render --label rev --log "$logfile"
assert_contains "$(cat "$logfile")" "tdd" "an existing log is appended to, not truncated"
assert_contains "$(cat "$logfile")" "rev" "the appended lines carry the new phase's label"

assert_ok "an unwritable log is not a reason to lose the live output" \
	bash -c "printf '%s' '$input' | python3 -u '$RENDER' --label tdd --log /nonexistent-dir/x.log | grep -q 'make test'"

# === width ==================================================================

long_command="$(python3 -c 'print("x" * 5000)')"
input="{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Bash\",\"input\":{\"command\":\"$long_command\"}}]}}
"
render --label tdd --width 100
# Measured in characters, not bytes: the glyphs are multi-byte UTF-8, and a
# byte count would read a correctly-fitted line as an over-long one.
longest="$(printf '%s\n' "$out" | python3 -c 'import sys; print(max(len(l.rstrip("\n")) for l in sys.stdin))')"
assert_ok "a 5000-character command is truncated rather than wrapped into a wall" \
	test "$longest" -le 100

assert_report
