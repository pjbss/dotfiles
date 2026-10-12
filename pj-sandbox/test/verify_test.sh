#!/bin/bash
# verify_test.sh
#
# Tests for `pj-sandbox verify`, run through the real dispatcher. A stub
# limactl reports the VM and its mounts. A stub ssh records each call's argv
# and stdin, then runs the remote command locally against a fake guest
# filesystem under GUEST_ROOT: `cd` is redirected there, and the guest
# script's first line, `root=`, is pointed at it. Guest-side stubs stand in
# for curl (the proxy's verdict, appending to the task's egress.log as the
# real proxy would) and sudo.

set -euo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PJ_SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"
. "$TEST_DIR/../../test/assert.sh"

CLI="$PJ_SANDBOX_DIR/bin/pj-sandbox"

if ! command -v python3 >/dev/null 2>&1; then
	echo "SKIP: python3 not found; pj-sandbox verify needs it"
	exit 0
fi

fixture="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "$fixture"' EXIT

export HOME="$fixture/home"
export PJ_SANDBOX_STATE_DIR="$fixture/state"
export PJ_SANDBOX_DOTFILES_HOME="$fixture/unused"
export PYTHONDONTWRITEBYTECODE=1
export STUB_DIR="$fixture/stub"
export GUEST_ROOT="$fixture/guest"
export GUEST_BIN="$fixture/guest-bin"
mkdir -p "$HOME" "$fixture/bin" "$GUEST_BIN" "$STUB_DIR"

TOKEN="ghp_FixtureToken0123456789abcdefghijKLMNOP"
printf '%s\n' "$TOKEN" > "$fixture/gh-token"

# --- stubs ---

cat > "$fixture/bin/limactl" <<'STUB'
#!/bin/sh
[ "$1 $2" = "list --json" ] || { echo "unexpected limactl call: $*" >&2; exit 3; }
for name in pjsb-alpha pjsb-beta; do
	[ -z "${3:-}" ] || [ "$3" = "$name" ] || continue
	status=Running
	[ "$name" = pjsb-beta ] && status=Stopped
	printf '{"name":"%s","status":"%s","config":{"mounts":%s,"user":{"name":"tester"}}}\n' \
		"$name" "$status" "${LIMA_MOUNTS:-[]}"
done
STUB

# Each call's argv and stdin are kept as ssh-argv.<n> and ssh-stdin.<n>.
cat > "$fixture/bin/ssh" <<'STUB'
#!/bin/sh
n=$(ls "$STUB_DIR" | grep -c '^ssh-stdin\.' || true)
printf '%s\0' "$@" > "$STUB_DIR/ssh-argv.$n"
cat > "$STUB_DIR/ssh-stdin.$n"
for remote_cmd in "$@"; do :; done
cd() { command cd "$GUEST_ROOT$1"; }
PATH="$GUEST_BIN:$PATH"
HOME=/home/tester
sed "1s|^root=\$|root='$GUEST_ROOT'|" "$STUB_DIR/ssh-stdin.$n" | eval "$remote_cmd"
STUB

# The proxy's verdict: hosts ending .invalid are denied (and logged) unless
# PROBE_ALLOWED is set; everything else gets through and is logged as
# allowed, unless CURL_CA_FAIL makes TLS fail the way an untrusted CA does.
# CURL_DIRECT is a guest that bypasses the proxy: it succeeds unlogged.
cat > "$GUEST_BIN/curl" <<'STUB'
#!/bin/sh
for url in "$@"; do :; done
host="${url#https://}"
host="${host%%/*}"
printf '%s\n' "$url" >> "$STUB_DIR/curl-urls"
case "$host" in
	*.invalid)
		[ -z "${PROBE_ALLOWED:-}" ] || exit 0
		[ -n "${CURL_NO_LOG:-}" ] ||
			printf '{"ts": "2026-10-12T10:00:00.000Z", "task": "alpha", "mode": "deny", "host": "%s", "method": "CONNECT", "path": "", "decision": "%s", "rule": "no-match"}\n' \
				"$host" "${CURL_LOG_DECISION:-deny}" >> "$PJ_SANDBOX_STATE_DIR/alpha/egress.log"
		exit 56
		;;
esac
[ -z "${CURL_CA_FAIL:-}" ] || exit 60
[ -n "${CURL_DIRECT:-}" ] ||
	printf '{"ts": "2026-10-12T10:00:00.000Z", "task": "alpha", "mode": "deny", "host": "%s", "method": "CONNECT", "path": "", "decision": "allow", "rule": "policy/allowlist:3"}\n' \
		"$host" >> "$PJ_SANDBOX_STATE_DIR/alpha/egress.log"
exit 0
STUB
printf '#!/bin/sh\n[ "$1" = -n ] && shift\nexec "$@"\n' > "$GUEST_BIN/sudo"
chmod +x "$fixture/bin/"* "$GUEST_BIN/"*
export PATH="$fixture/bin:$PATH"

# --- fixture task and guest ---

record() {
	sh -c '. "$1/lib/namespace.sh"; . "$1/lib/state.sh"; shift; pj_sandbox_state_write "$@"' \
		sh "$PJ_SANDBOX_DIR" "$@"
}
record alpha task=alpha instance=pjsb-alpha egress_mode=deny creds=gh:brokered,claude:unbrokered,copilot:none
record beta task=beta instance=pjsb-beta egress_mode=deny creds=gh:brokered
policy="$PJ_SANDBOX_STATE_DIR/alpha/policy"
mkdir -p "$policy"
cat > "$policy/inject.json" <<JSON
[
  {"host": "api.github.com", "header": "Authorization", "scheme": "bearer", "placeholder": "pjsb-placeholder-gh", "token_source": ["file:$fixture/gh-token"]}
]
JSON
printf '%s\n' '*.githubusercontent.com' 'uploads.github.com POST' 'api.github.com GET /repos' 'github.com' > "$policy/allowlist"

clean_guest() {
	rm -rf "$GUEST_ROOT"
	mkdir -p "$GUEST_ROOT/etc" "$GUEST_ROOT/workspace/src" "$GUEST_ROOT/home/tester" "$GUEST_ROOT/proc/1" "$GUEST_ROOT/proc/42"
	printf 'pj-sandbox guest\n' > "$GUEST_ROOT/etc/pj-sandbox"
	printf 'export GH_TOKEN=pjsb-placeholder-gh\n' > "$GUEST_ROOT/home/tester/.profile"
	printf '{"oauthAccount": null}\n' > "$GUEST_ROOT/home/tester/.claude.json"
	printf 'print("hello")\n' > "$GUEST_ROOT/workspace/src/main.py"
	printf 'PATH=/usr/bin\0HOME=/root\0' > "$GUEST_ROOT/proc/1/environ"
	printf 'GH_TOKEN=pjsb-placeholder-gh\0' > "$GUEST_ROOT/proc/42/environ"
	rm -f "$STUB_DIR"/* "$PJ_SANDBOX_STATE_DIR/alpha/egress.log"
}

# run_verify [ENV=VALUE...] -- sets out and rc.
run_verify() {
	if out="$(env "$@" "$CLI" verify alpha 2>&1)"; then rc=0; else rc=$?; fi
}
line_for() {
	printf '%s\n' "$out" | grep -E "^(PASS|FAIL|SKIP) +$1" || true
}

# --- a clean sandbox passes every check ---

clean_guest
run_verify
assert_exit_code 0 "$rc" "verify of a clean sandbox exits 0 (output: $out)"
for check in mounts no-tokens egress-denied ca-trusted marker; do
	assert_contains "$(line_for "$check")" "PASS" "a clean sandbox passes $check"
done
assert_not_contains "$out" "FAIL" "a clean sandbox has no FAIL line"
assert_contains "$(cat "$STUB_DIR/curl-urls")" "https://api.github.com/repos" \
	"the CA probe goes to the first exact allowlisted host GET may reach, at its path prefix"

# Everything verify sent the guest, over every ssh call: argv (where the
# scan's salt and fingerprints go) and stdin (the scripts).
sent="$(cat "$STUB_DIR"/ssh-stdin.*; cat "$STUB_DIR"/ssh-argv.* | tr '\0' '\n')"
assert_not_contains "$sent" "$TOKEN" "nothing sent to the guest, argv or stdin, holds the full fixture token"
assert_ok "the scan's fingerprint for the gh token is among what was sent, so the check above saw the scan's data" \
	grep -Eq "'gh=[0-9a-f]{16}'" <<< "$sent"

# --- an unbrokered profile is reported but doesn't fail the run ---

unbrokered="$(printf '%s\n' "$out" | grep claude || true)"
assert_contains "$unbrokered" "SKIP" "the unbrokered claude profile is reported as a SKIP"
assert_contains "$unbrokered" "unbrokered" "the report says why it's skipped"

# --- each fault fails its own check, and the run ---

clean_guest
run_verify LIMA_MOUNTS='[{"location":"/Users/x","mountPoint":"/workspace","writable":true}]'
assert_exit_code 1 "$rc" "a host mount makes verify exit 1"
assert_contains "$(line_for mounts)" "FAIL" "a non-empty mounts list fails the mounts check"
assert_contains "$(line_for mounts)" "/workspace" "the mounts failure names the mount point"
assert_contains "$(line_for marker)" "PASS" "a mount doesn't fail the marker check"

for place in proc/1/environ home/tester/.claude.json home/tester/.bashrc workspace/src/config.env \
	home/tester/.config/gh/hosts.yml home/tester/.claude/.credentials.json; do
	clean_guest
	mkdir -p "$(dirname "$GUEST_ROOT/$place")"
	printf 'GH_TOKEN=%s\0' "$TOKEN" >> "$GUEST_ROOT/$place"
	run_verify
	assert_exit_code 1 "$rc" "a real token in the guest's /$place makes verify exit 1"
	assert_contains "$(line_for no-tokens)" "FAIL" "a real token in /$place fails the no-tokens check"
	assert_contains "$(line_for no-tokens)" "/$place" "the no-tokens failure names /$place"
	assert_contains "$(line_for mounts)" "PASS" "a planted token doesn't fail the mounts check"
done

clean_guest
run_verify LEAKED_IN_SESSION="$TOKEN"
assert_contains "$(line_for no-tokens)" "FAIL" "a real token in the guest session's env fails the no-tokens check"

clean_guest
run_verify PROBE_ALLOWED=1
assert_exit_code 1 "$rc" "an allowed probe makes verify exit 1"
assert_contains "$(line_for egress-denied)" "FAIL" "an allowed probe fails the egress-denied check"
assert_contains "$(line_for ca-trusted)" "PASS" "an allowed probe doesn't fail the CA check"

clean_guest
run_verify CURL_NO_LOG=1
assert_contains "$(line_for egress-denied)" "FAIL" "a refused probe the proxy never logged fails the egress-denied check"

clean_guest
run_verify CURL_LOG_DECISION=allow
assert_contains "$(line_for egress-denied)" "FAIL" "a probe the proxy logged as allowed fails egress-denied, even though curl failed"

clean_guest
run_verify CURL_CA_FAIL=1
assert_exit_code 1 "$rc" "an untrusted CA makes verify exit 1"
assert_contains "$(line_for ca-trusted)" "FAIL" "a TLS failure fails the ca-trusted check"

clean_guest
run_verify CURL_DIRECT=1
assert_exit_code 1 "$rc" "a CA probe that bypassed the proxy makes verify exit 1"
assert_contains "$(line_for ca-trusted)" "FAIL" "a CA probe the proxy never logged fails the ca-trusted check"

clean_guest
printf '{"ts": "2026-10-12T09:00:00.000Z", "task": "alpha", "mode": "deny", "host": "api.github.com", "method": "CONNECT", "path": "", "decision": "allow", "rule": "policy/allowlist:3"}\n' \
	> "$PJ_SANDBOX_STATE_DIR/alpha/egress.log"
run_verify CURL_DIRECT=1
assert_contains "$(line_for ca-trusted)" "FAIL" "an older log entry for the CA host doesn't count for this run's probe"

clean_guest
rm "$GUEST_ROOT/etc/pj-sandbox"
run_verify
assert_exit_code 1 "$rc" "a missing marker makes verify exit 1"
assert_contains "$(line_for marker)" "FAIL" "a missing marker fails the marker check"
assert_contains "$(line_for no-tokens)" "PASS" "a missing marker doesn't fail the no-tokens check"

clean_guest
record alpha task=alpha instance=pjsb-alpha egress_mode=observe creds=gh:brokered,claude:unbrokered,copilot:none
run_verify
assert_contains "$(line_for egress-denied)" "FAIL" "a sandbox not in deny mode fails the egress-denied check"
assert_contains "$(line_for egress-denied)" "observe" "the failure names the egress mode"
record alpha task=alpha instance=pjsb-alpha egress_mode=deny creds=gh:brokered,claude:unbrokered,copilot:none

# --- refusals ---

clean_guest
if out="$("$CLI" verify beta 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "verify of a stopped sandbox exits 1"
assert_contains "$out" "isn't running" "verify of a stopped sandbox says so"
assert_not_ok "verify of a stopped sandbox never calls ssh" sh -c 'ls "$1"/ssh-argv.* >/dev/null 2>&1' sh "$STUB_DIR"

if out="$("$CLI" verify 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "verify with no task exits 1"
assert_contains "$out" "Usage: pj-sandbox verify" "verify with no task prints usage"

assert_report
