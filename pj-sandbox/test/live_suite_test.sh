#!/bin/bash
# live_suite_test.sh
#
# Hermetic checks for the live security suite (pj-sandbox/test/live/run.sh).
# The suite itself boots a real VM and is run by hand (MT-6 in
# issues/manual-tests.md); these tests only prove its --help and --dry-run
# surfaces, that its teardown always runs, and that it stays out of
# `make test`. `limactl` is stubbed to fail loudly if it's ever called, and
# the pj-sandbox CLI is swapped for a recording stub via PJ_SANDBOX_LIVE_CLI.

set -euo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PJ_SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"
DOTFILES_DIR="$(cd -P "$PJ_SANDBOX_DIR/.." && pwd)"
. "$TEST_DIR/../../test/assert.sh"

SUITE="$PJ_SANDBOX_DIR/test/live/run.sh"
ATTACKS="hook-escape egress-root container-egress dns-tunnel token-hunt placeholder-leak"

fixture="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "$fixture"' EXIT

export HOME="$fixture/home"
export PJ_SANDBOX_STATE_DIR="$fixture/state"
export PYTHONDONTWRITEBYTECODE=1
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export CALLS="$fixture/calls"
# Resolves without a network, so the live path stays hermetic.
export PJ_SANDBOX_LIVE_DENIED_HOST=localhost
mkdir -p "$HOME" "$fixture/bin"

cat > "$fixture/bin/limactl" <<STUB
#!/bin/sh
echo "limactl \$*" >> "$fixture/limactl.calls"
echo "limactl stub: must not be called" >&2
exit 99
STUB

# A pj-sandbox that records each call. STUB_FAIL names the subcommands that
# fail; everything else succeeds quietly.
cat > "$fixture/bin/pj-sandbox" <<'STUB'
#!/bin/sh
echo "$*" >> "$CALLS"
[ "$1" != exec ] || cat >/dev/null
case " ${STUB_FAIL:-} " in
	*" $1 "*) echo "stub pj-sandbox: $1 forced to fail" >&2; exit "${STUB_RC:-1}" ;;
esac
exit 0
STUB
chmod +x "$fixture/bin/limactl" "$fixture/bin/pj-sandbox"
PATH="$fixture/bin:$PATH"
export PATH

# --- --help ---

if out="$("$SUITE" --help 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "run.sh --help exits 0"
for a in $ATTACKS; do
	assert_contains "$out" "$a" "--help lists attack '$a'"
done
assert_contains "$out" "--dry-run" "--help documents --dry-run"
assert_contains "$out" "pj-sandbox verify" "--help says it runs pj-sandbox verify"

if out="$("$SUITE" --bogus 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "an unknown argument exits 1"

# --- --dry-run ---

if out="$(PJ_SANDBOX_LIVE_CLI="$fixture/bin/pj-sandbox" "$SUITE" --dry-run 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "--dry-run exits 0"
for a in $ATTACKS; do
	assert_contains "$out" "== [$a]" "--dry-run prints a section for '$a'"
done
assert_contains "$out" "spawn live-" "--dry-run prints the spawn of a live-* task"
assert_contains "$out" "core.fsmonitor" "--dry-run prints the fsmonitor plant"
assert_contains "$out" "core.hooksPath" "--dry-run prints the hooksPath plant"
assert_contains "$out" ".git/hooks/post-checkout" "--dry-run prints the post-checkout hook plant"
assert_contains "$out" "fetch live-" "--dry-run prints the fetch"
assert_contains "$out" "git checkout" "--dry-run prints the host checkout of the fetched ref"
assert_contains "$out" "iptables -F" "--dry-run prints the iptables flush"
assert_contains "$out" "ip -4 route replace default" "--dry-run prints the route change"
assert_contains "$out" "macvlan" "--dry-run prints the macvlan container"
assert_contains "$out" "docker run" "--dry-run prints the bridge container"
assert_contains "$out" "dig \"\$@\"" "--dry-run prints the dig probe"
assert_contains "$out" "+tcp" "--dry-run prints DNS over TCP"
assert_contains "$out" "verify_scan.py" "--dry-run names verify's scanner for the token hunt"
assert_contains "$out" "pjsb-placeholder-gh" "--dry-run prints the gh placeholder send"
assert_contains "$out" "placeholder-leak" "--dry-run says it looks for a placeholder-leak line"
assert_contains "$out" "verify live-" "--dry-run prints the verify run"
assert_contains "$out" "rm live-" "--dry-run prints the teardown"
assert_eq "" "$(cat "$fixture/limactl.calls" 2>/dev/null || true)" "--help and --dry-run never call limactl"
assert_eq "" "$(cat "$CALLS" 2>/dev/null || true)" "--dry-run never calls pj-sandbox"

# --- teardown always runs ---

# Every guest step fails, so every attack does.
if out="$(STUB_FAIL="exec" PJ_SANDBOX_LIVE_CLI="$fixture/bin/pj-sandbox" "$SUITE" 2>&1 </dev/null)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "a failing attack makes the suite exit 1"
assert_contains "$out" "FAIL [hook-escape]" "the forced failure is reported as a FAIL"
assert_contains "$out" "== Summary ==" "a PASS/FAIL summary is printed"
calls="$(cat "$CALLS")"
assert_contains "$calls" "spawn live-" "the suite spawned a live-* task"
task="$(awk '$1 == "spawn" { print $2; exit }' "$CALLS")"
assert_contains "$calls" "rm $task" "rm runs after an attack step fails"
assert_eq "rm $task" "$(tail -1 "$CALLS")" "rm is the last thing the suite does"
assert_contains "$out" "FAIL [dns-tunnel] DNS for localhost: couldn't run" "a guest step that merely broke isn't reported as a breach"
assert_not_contains "$out" "got through" "no attack is called a breach when the guest steps only broke"

# A guest script exits 10 when its attack got through.
if out="$(STUB_FAIL="exec" STUB_RC=10 PJ_SANDBOX_LIVE_CLI="$fixture/bin/pj-sandbox" "$SUITE" 2>&1 </dev/null)"; then rc=0; else rc=$?; fi
assert_contains "$out" "FAIL [egress-root] root after iptables -F and a route change, to localhost: got through" "exit 10 from a guest attack is reported as a breach"

: > "$CALLS"
if out="$(STUB_FAIL="spawn" PJ_SANDBOX_LIVE_CLI="$fixture/bin/pj-sandbox" "$SUITE" 2>&1 </dev/null)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "a failing spawn makes the suite exit 1"
task="$(awk '$1 == "spawn" { print $2; exit }' "$CALLS")"
assert_eq "rm $task" "$(tail -1 "$CALLS")" "rm runs even when spawn fails, so a half-built VM isn't left behind"
assert_not_contains "$(cat "$CALLS")" "exec" "no attack runs after spawn fails"
assert_eq "" "$(cat "$fixture/limactl.calls" 2>/dev/null || true)" "the suite never calls limactl itself"

# --- guest scripts ---
#
# Each guest script is taken from --dry-run's output and run here with bash,
# against stubs of the guest tools it calls. G_* variables steer the stubs.
# Exit 0 is blocked, 10 got through, anything else couldn't run.

dry="$("$SUITE" --dry-run 2>&1)"
guest_script() {
	printf '%s\n' "$dry" | awk -v s="== [$1] ==" '
		$0 == s { on = 1; next }
		on && /<<.GUEST.$/ { g = 1; next }
		g && $0 == "GUEST" { exit }
		g { print }'
}
gstub="$fixture/guest-bin"
mkdir -p "$gstub"
cat > "$gstub/dig" <<'STUB'
#!/bin/sh
if [ "${G_DNS:-blocked}" = open ]; then echo 93.184.215.14; exit 0; fi
# What a real dig prints on a timeout: to stdout, not stderr.
echo ';; connection timed out; no servers could be reached'
exit 9
STUB
cat > "$gstub/ls" <<'STUB'
#!/bin/sh
echo eth0 lo
STUB
cat > "$gstub/ip" <<'STUB'
#!/bin/sh
case "$*" in
	"-4 route show dev eth0 scope link proto kernel") echo "${G_SUBNET:-192.168.5.0/24} src 192.168.5.15" ;;
	"-4 route show default") echo "default via 192.168.106.1 dev lima0" ;;
	"-4 route show") echo "192.168.5.0/24 dev eth0 proto kernel scope link src 192.168.5.15" ;;
	# Like the real ip, a route with no gateway or device is an error.
	"-4 route replace default via  dev "*) exit 1 ;;
	"-4 route replace "*) [ "${G_ROUTE:-ok}" = ok ] ;;
	"-4 route del default") exit 1 ;;
	*) exit 0 ;;
esac
STUB
# `docker run` exits G_RUN_RC: 7 by default, curl's "couldn't connect".
# Docker's own 125 means the container never started.
cat > "$gstub/docker" <<STUB
#!/bin/sh
case "\$1 \$2" in
	"network create") echo "\$*" >> "$fixture/docker-network-create"; [ "\${G_MACVLAN:-ok}" = ok ] ;;
	"run --rm") exit "\${G_RUN_RC:-7}" ;;
	*) exit 0 ;;
esac
STUB
cat > "$gstub/curl" <<'STUB'
#!/bin/sh
exit "${G_CURL_RC:-7}"
STUB
for t in iptables ip6tables nft; do
	printf '#!/bin/sh\nexit 0\n' > "$gstub/$t"
done
chmod +x "$gstub"/*

# run_guest LABEL [VAR=VALUE...]: runs LABEL's guest script; prints its exit status.
run_guest() {
	label="$1"
	shift
	if guest_script "$label" | env "$@" PATH="$gstub:$PATH" bash -s >/dev/null 2>"$fixture/guest.err"; then
		echo 0
	else
		echo "$?"
	fi
}

assert_eq 0 "$(run_guest dns-tunnel)" "dns-tunnel: a dig that times out (and says so on stdout) is blocked, not a breach"
assert_eq 10 "$(run_guest dns-tunnel G_DNS=open)" "dns-tunnel: a dig that gets an answer is a breach"

assert_eq 0 "$(run_guest container-egress)" "container-egress: bridge and macvlan containers that can't connect are blocked"
rc="$(run_guest container-egress G_MACVLAN=fail)"
assert_not_contains " 0 10 " " $rc " "container-egress: with no macvlan network created, it couldn't run (got $rc), rather than passing on the bridge probe alone"
assert_contains "$(cat "$fixture/guest.err")" "eth0" "container-egress names the NIC whose macvlan network couldn't be made"

rc="$(run_guest container-egress G_RUN_RC=125)"
assert_not_contains " 0 10 " " $rc " "container-egress: a container docker couldn't start (exit 125) couldn't run (got $rc), rather than passing"
assert_eq 0 "$(run_guest container-egress G_RUN_RC=28)" "container-egress: a container whose curl timed out is blocked"

# The macvlan container mustn't take the first free address, which is the
# guest's own DHCP lease on lima0.
: > "$fixture/docker-network-create"
run_guest container-egress >/dev/null
assert_contains "$(cat "$fixture/docker-network-create")" "--ip-range 192.168.5.250/32" "the macvlan container is pinned to .250, away from DHCP leases"

# Pinning to .250 only makes sense on a /24; any other subnet is skipped.
: > "$fixture/docker-network-create"
rc="$(run_guest container-egress G_SUBNET=10.0.0.0/16)"
assert_not_contains " 0 10 " " $rc " "container-egress: a NIC on a non-/24 subnet couldn't run (got $rc), rather than passing"
assert_contains "$(cat "$fixture/guest.err")" "10.0.0.0/16" "container-egress names the non-/24 subnet it skipped"
assert_eq "" "$(cat "$fixture/docker-network-create")" "no macvlan network is made on a non-/24 subnet"

assert_eq 0 "$(run_guest egress-root)" "egress-root: a reroute that still can't connect is blocked"
rc="$(run_guest egress-root G_CURL_RC=127)"
assert_not_contains " 0 10 " " $rc " "egress-root: a curl that couldn't run (exit 127) couldn't run (got $rc), rather than passing"
assert_eq 10 "$(run_guest egress-root G_CURL_RC=0)" "egress-root: a curl that connects is a breach"
rc="$(run_guest egress-root G_ROUTE=fail)"
assert_not_contains " 0 10 " " $rc " "egress-root: with no route change made, it couldn't run (got $rc), rather than passing"

# --- placeholder-leak waits for the proxy to flush ---

# A logs that shows the leak line only from its second call on, like a proxy
# that hadn't flushed yet when the guest's curl returned.
cat > "$fixture/bin/pj-sandbox-slowlog" <<'STUB'
#!/bin/sh
echo "$*" >> "$CALLS"
[ "$1" != exec ] || cat >/dev/null
if [ "$1" = logs ]; then
	n=$(grep -c '^logs ' "$CALLS")
	[ "$n" -lt 2 ] || echo '{"host": "api.anthropic.com", "decision": "deny", "rule": "placeholder-leak"}'
fi
exit 0
STUB
chmod +x "$fixture/bin/pj-sandbox-slowlog"
: > "$CALLS"
out="$(PJ_SANDBOX_LIVE_CLI="$fixture/bin/pj-sandbox-slowlog" "$SUITE" 2>&1 </dev/null)" || true
assert_contains "$out" "PASS [placeholder-leak]" "placeholder-leak finds a log line the proxy flushed after the first read"

# --- kept out of make test ---

assert_contains "$(make -C "$DOTFILES_DIR" --no-print-directory help)" "sandbox-live-test" "make help lists sandbox-live-test"
assert_contains "$(cat "$DOTFILES_DIR/Makefile")" "pj-sandbox/test/live/run.sh" "make sandbox-live-test runs the live suite"

# test/run.sh's discovery, run on a copy of the tree where a *_test.sh sits
# under pj-sandbox/test/live/: it must run the ordinary test and skip that one.
tree="$fixture/tree"
mkdir -p "$tree/test" "$tree/pj-sandbox/test/live"
cp "$DOTFILES_DIR/test/run.sh" "$tree/test/run.sh"
printf '#!/bin/bash\necho ran-ordinary\n' > "$tree/pj-sandbox/test/ordinary_test.sh"
printf '#!/bin/bash\necho ran-live\n' > "$tree/pj-sandbox/test/live/boots_vm_test.sh"
out="$(sh "$tree/test/run.sh" 2>&1)" || true
assert_contains "$out" "ran-ordinary" "test/run.sh runs pj-sandbox/test/*_test.sh"
assert_not_contains "$out" "ran-live" "test/run.sh never runs anything under pj-sandbox/test/live/"

assert_report
