#!/bin/bash
# logs_test.sh
#
# Tests for `pj-sandbox logs` and `pj-sandbox allowlist suggest`, run through
# the real dispatcher against a fixture egress.log in the task's state dir:
# the table has a row per line, --denied keeps only denials and placeholder
# leaks, --json passes lines through unchanged, and suggest turns an
# observe-mode log into allowlist entries the issue-020 parser accepts.

set -euo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PJ_SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"
. "$TEST_DIR/../../test/assert.sh"

CLI="$PJ_SANDBOX_DIR/bin/pj-sandbox"

if ! command -v python3 >/dev/null 2>&1; then
	echo "SKIP: python3 not found; pj-sandbox logs needs it"
	exit 0
fi

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

export HOME="$fixture/home"
export PJ_SANDBOX_STATE_DIR="$fixture/state"
export PYTHONDONTWRITEBYTECODE=1
mkdir -p "$HOME"

# record TASK KEY=VALUE...
record() {
	sh -c 'PJ_SANDBOX_DOTFILES_HOME=/unused; . "$1/lib/namespace.sh"; . "$1/lib/state.sh"; shift; pj_sandbox_state_write "$@"' \
		sh "$PJ_SANDBOX_DIR" "$@"
}

# --- logs: a deny-mode log ---

record alpha task=alpha instance=pjsb-alpha egress_mode=deny
log="$PJ_SANDBOX_STATE_DIR/alpha/egress.log"
cat > "$log" <<'LOG'
{"ts": "2026-10-12T10:00:00.000Z", "task": "alpha", "mode": "deny", "host": "api.github.com", "method": "CONNECT", "path": "", "decision": "allow", "rule": "policy/allowlist:2 api.github.com"}
{"ts": "2026-10-12T10:00:01.000Z", "task": "alpha", "mode": "deny", "host": "api.github.com", "method": "GET", "path": "/repos/o/r", "decision": "inject", "rule": "api.github.com", "placeholder": "pjsb-placeholder-gh", "token_sha256": "ab12"}
{"ts": "2026-10-12T10:00:02.000Z", "task": "alpha", "mode": "deny", "host": "evil.example", "method": "CONNECT", "path": "", "decision": "deny", "rule": "no-match"}
{"ts": "2026-10-12T10:00:03.000Z", "task": "alpha", "mode": "deny", "host": "pypi.org", "method": "GET", "path": "/simple/", "decision": "deny", "rule": "placeholder-leak", "placeholder": "pjsb-placeholder-claude"}
{"ts": "2026-10-12T10:00:04.000Z", "task": "alpha", "mode": "deny", "host": "github.com", "method": "GET", "path": "/o/r.git/info/refs", "decision": "allow", "rule": "policy/allowlist:1 github.com"}
LOG

if out="$("$CLI" logs alpha 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "logs exits 0 for a task with a log"
assert_eq 6 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "the table is a header plus one row per log line"
header="$(printf '%s\n' "$out" | head -n 1)"
for col in TIME DECISION METHOD HOST PATH RULE; do
	assert_contains "$header" "$col" "the table header has a $col column"
done
row="$(printf '%s\n' "$out" | grep '/repos/o/r')"
for field in 2026-10-12T10:00:01.000Z inject GET api.github.com "injected: gh"; do
	assert_contains "$row" "$field" "the inject row shows '$field'"
done
assert_not_contains "$out" "ab12" "the table doesn't show the token fingerprint"
assert_eq 1 "$(printf '%s\n' "$out" | grep -c 'injected:')" "only the inject row carries an injected marker"

if out="$("$CLI" logs alpha --denied 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "logs --denied exits 0"
assert_eq 3 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "--denied keeps the header and the two denials"
assert_contains "$out" "evil.example" "--denied shows a policy denial"
assert_contains "$out" "placeholder-leak" "--denied shows a placeholder leak"
assert_not_contains "$out" "info/refs" "--denied leaves out allowed requests"
assert_not_contains "$out" "injected:" "--denied leaves out injections"

if out="$("$CLI" logs alpha --json)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "logs --json exits 0"
assert_eq "$(cat "$log")" "$out" "--json passes the log lines through unchanged"

out="$("$CLI" logs alpha --json --denied)"
assert_eq "$(grep -e '"decision": "deny"' "$log")" "$out" "--json --denied passes the denial lines through unchanged"

# --- logs --follow ---

"$CLI" logs alpha --follow > "$fixture/follow.out" 2>&1 &
follow_pid=$!
for _ in $(seq 50); do
	grep -q 'info/refs' "$fixture/follow.out" 2>/dev/null && break
	sleep 0.1
done
printf '%s\n' '{"ts": "2026-10-12T10:00:05.000Z", "task": "alpha", "mode": "deny", "host": "late.example", "method": "GET", "path": "/", "decision": "deny", "rule": "no-match"}' >> "$log"
for _ in $(seq 50); do
	grep -q 'late.example' "$fixture/follow.out" 2>/dev/null && break
	sleep 0.1
done
kill "$follow_pid" 2>/dev/null || true
wait "$follow_pid" 2>/dev/null || true
assert_contains "$(cat "$fixture/follow.out")" "late.example" "--follow shows a line appended after it started"

# --- logs: errors ---

record quiet task=quiet instance=pjsb-quiet egress_mode=deny
if out="$("$CLI" logs quiet 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "logs for a task with no egress log exits 1"
assert_contains "$out" "no egress log" "logs for a task with no log says so"
assert_contains "$out" "quiet" "logs for a task with no log names the task"

if out="$("$CLI" logs nosuch 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "logs for an unknown task exits 1"
assert_contains "$out" "no sandbox task 'nosuch'" "logs for an unknown task says so"

if out="$("$CLI" logs 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "logs with no task exits 1"
assert_contains "$out" "Usage: pj-sandbox logs" "logs with no task prints usage"

if out="$("$CLI" logs alpha --bogus 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "logs with an unknown flag exits 1"

# --- allowlist suggest: an observe-mode log ---

record beta task=beta instance=pjsb-beta egress_mode=observe
mkdir -p "$PJ_SANDBOX_STATE_DIR/beta/policy"
printf 'github.com\n*.githubusercontent.com\napi.github.com GET /repos/\n' > "$PJ_SANDBOX_STATE_DIR/beta/policy/allowlist"
# obs HOST METHOD DECISION
obs() {
	printf '{"ts": "2026-10-12T11:00:00.000Z", "task": "beta", "mode": "observe", "host": "%s", "method": "%s", "path": "/", "decision": "%s", "rule": "no-match"}\n' "$1" "$2" "$3"
}
{
	obs github.com GET allow
	obs raw.githubusercontent.com GET allow
	obs api.github.com POST would-deny
	obs pypi.org CONNECT would-deny
	obs pypi.org GET would-deny
	obs pypi.org GET would-deny
	obs files.pythonhosted.org GET would-deny
	obs 140.82.112.3 CONNECT would-deny
	obs 2001:db8::1 GET would-deny
	obs registry.npmjs.org GET would-deny
} > "$PJ_SANDBOX_STATE_DIR/beta/egress.log"

if out="$("$CLI" allowlist suggest beta 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "allowlist suggest exits 0 (output: $out)"
entries="$(printf '%s\n' "$out" | sed 's/[[:space:]]*#.*$//' | grep -v '^$' || true)"
assert_eq "$(printf 'files.pythonhosted.org\npypi.org\nregistry.npmjs.org')" "$entries" \
	"suggest lists each new host once, sorted, leaving out covered hosts and IP literals"
assert_contains "$(printf '%s\n' "$out" | grep '^pypi.org')" "# 3 requests" "suggest counts each host's log lines in a comment"
assert_contains "$(printf '%s\n' "$out" | grep '^files.pythonhosted.org')" "# 1 request" "a single request is counted in the singular"
assert_not_contains "$out" "140.82.112.3" "suggest never emits an IPv4 literal"
assert_not_contains "$out" "2001:db8" "suggest never emits an IPv6 literal"

parsed="$(printf '%s\n' "$out" | (cd "$PJ_SANDBOX_DIR/proxy" &&
	python3 -c 'import sys, policy; print("\n".join(r.host for r in policy.parse_allowlist(sys.stdin.read(), "suggest")))'))"
assert_eq "$entries" "$parsed" "suggest's output parses with the issue-020 allowlist parser"

# --- allowlist suggest --write ---

target="$fixture/repo-allowlist"
printf '# hand-written\nexample.org\n' > "$target"
if out="$("$CLI" allowlist suggest beta --write "$target" 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "allowlist suggest --write exits 0 (output: $out)"
assert_contains "$out" "$target" "--write says where it wrote"
assert_contains "$(cat "$target")" "example.org" "--write keeps what the file already held"
assert_eq "$entries" "$(sed -n '3,$p' "$target" | sed 's/[[:space:]]*#.*$//' | grep -v '^$')" "--write appends the suggested entries"

# The next spawn's merge step: a profile plus the written file.
mkdir -p "$fixture/profiles/p1"
printf 'github.com\n' > "$fixture/profiles/p1/allowlist"
sh -c 'PJ_SANDBOX_DOTFILES_HOME=/unused; . "$1/lib/profiles.sh"; pj_sandbox_profiles_write_policy "$2" p1 "$3" "$4" "$5"' \
	sh "$PJ_SANDBOX_DIR" "$fixture/profiles" "$fixture/merged" "$target" "$fixture/no-such-allowlist"
assert_eq "$(printf 'github.com\nexample.org\nfiles.pythonhosted.org\npypi.org\nregistry.npmjs.org')" \
	"$(cat "$fixture/merged/allowlist")" "the merge step folds a --write file into policy/allowlist after the profiles' entries"

# --- allowlist: errors ---

if out="$("$CLI" allowlist suggest quiet 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "suggest for a task with no egress log exits 1"
assert_contains "$out" "no egress log for task 'quiet'" "suggest for a task with no log says so"

if out="$("$CLI" allowlist suggest nosuch 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "suggest for an unknown task exits 1"

if out="$("$CLI" allowlist 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "allowlist with no action exits 1"
assert_contains "$out" "Usage: pj-sandbox allowlist suggest" "allowlist with no action prints usage"

if out="$("$CLI" allowlist suggest beta --write 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "--write with no path exits 1"

assert_report
