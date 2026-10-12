#!/bin/bash
# spike_egress.sh
#
# The egress-enforcement spike (issues/prd-pj-sandbox.md, "Egress enforcement
# point"; issue 009). Boots a throwaway pjsb-spike-* VM for one candidate
# mechanism, locks its network down the way that candidate would, then tries,
# as root in the guest, to escape to hosts that aren't allowlisted. It needs a
# real Mac host with Lima, so it's run by hand (MT-4 in issues/manual-tests.md)
# and its results go into pj-sandbox/docs/spike-egress.md.
#
# Usage: spike_egress.sh [--dry-run] --candidate <candidate>
#
# Candidates (Lima configs in pj-sandbox/lima/spike/):
#   vmnet-hostonly  socket_vmnet host-only network, Lima's default NAT NIC
#                   blackholed; proxy on the host at 192.168.106.1:8080
#   user-v2         Lima user-v2 networking plus an outside filter on the host
#                   (PJ_SPIKE_HOST_FILTER); proxy at host.lima.internal:8080
#   gateway-vm      a second Lima VM running nftables + mitmdump is the agent
#                   VM's only route; proxy at the gateway's address, port 8080
#   vz-usernet      vmType vz, Lima's built-in network only; eth0's default
#                   route deleted and Lima's resolver blackholed; proxy on
#                   the host's 127.0.0.1:8080, reached at 192.168.5.2:8080
#   vz-tunnel       vmType vz, ssh over vsock, eth0 taken down; proxy reached
#                   through `ssh -R 127.0.0.1:3128:<host proxy>`, so the
#                   guest's proxy is 127.0.0.1:3128 (host side: PJ_SPIKE_HOST_PROXY)
# The vz candidates need neither qemu nor socket_vmnet, which ThreatLocker
# kills on the host (pj-sandbox/docs/spike-egress-vz.md).
#
# Escape attempts, each run as root in the guest against a non-allowlisted
# target and printed as PASS (blocked) or FAIL (reached):
#   [direct-tcp]         a direct TCP connection to PJ_SPIKE_TARGET
#   [dns-udp]            DNS to an outside resolver on UDP 53
#   [dns-tcp]            DNS to an outside resolver on TCP 53
#   [ssh-22]             SSH (port 22) to an outside host
#   [lan-rfc1918]        a LAN (RFC1918) address
#   [docker-macvlan]     a Docker container on a macvlan network
#   [flush-and-reroute]  direct TCP and DNS again after `iptables -F`,
#                        `nft flush ruleset`, bringing every NIC back up and
#                        pointing the default route at every gateway the
#                        guest booted with (run last, since it wrecks the
#                        guest's network)
#
# Checks that must keep working, printed PASS (works) or FAIL (broken):
#   [proxy-path]  HTTPS to PJ_SPIKE_ALLOWED_HOST through the proxy
#   [host-ssh]    ssh from the host into the guest
#
# Before probing, the same targets are tried from the host itself. A target
# the host can't reach either is reported as CONTROL-UNREACHABLE, and a PASS
# against it proves nothing.
#
# The VM (both VMs, for gateway-vm) is deleted at the end, even after a
# failure or Ctrl-C. Exits 0 only if every line is a PASS.
#
# Options:
#   --candidate <c>  which mechanism to test (required)
#   --dry-run        print the Lima config(s), the commands and the guest probe
#                    script, without calling limactl or touching the network
#   -h, --help       show this help
#
# Environment (defaults in parentheses):
#   PJ_SPIKE_TARGET, PJ_SPIKE_TARGET_PORT   non-allowlisted target (1.1.1.1, 443)
#   PJ_SPIKE_RESOLVER, PJ_SPIKE_DNS_NAME    outside resolver (8.8.8.8, example.com)
#   PJ_SPIKE_SSH_HOST                       outside ssh host (github.com)
#   PJ_SPIKE_LAN_ADDR, PJ_SPIKE_LAN_PORT    a LAN host that listens (the host's
#                                           default gateway, 80)
#   PJ_SPIKE_ALLOWED_HOST                   allowlisted host (api.github.com)
#   PJ_SPIKE_PROXY                          proxy host:port (per candidate, above)
#   PJ_SPIKE_HOST_FILTER                    user-v2 only: host command that
#                                           installs the outside filter
#   PJ_SPIKE_HOST_UNFILTER                  user-v2 only: host command that
#                                           removes it, run at teardown
#   PJ_SPIKE_HOST_PROXY                     vz-tunnel only: the host proxy the
#                                           tunnel ends at (127.0.0.1:8080)
#
# For vmnet-hostonly, user-v2 and both vz candidates a proxy (e.g. `mitmdump
# --listen-port 8080`) must already be listening on the host; for the vz
# ones, on 127.0.0.1. gateway-vm starts its own.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do SOURCE="$(readlink "$SOURCE")"; done
LIVE_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
PJ_SANDBOX_HOME="$(cd -P "$LIVE_DIR/../.." && pwd)"
PJ_SANDBOX_DOTFILES_HOME="$(cd -P "$PJ_SANDBOX_HOME/.." && pwd)"
SPIKE_LIMA_DIR="$PJ_SANDBOX_HOME/lima/spike"

# shellcheck source=../../lib/namespace.sh
. "$PJ_SANDBOX_HOME/lib/namespace.sh"

usage() {
	sed -n '2,/^$/p' "$SOURCE" | sed 's/^# \{0,1\}//'
}

die() {
	echo "spike_egress.sh: $*" >&2
	exit 1
}

candidate=""
dry_run=0
while [ "$#" -gt 0 ]; do
	case "$1" in
		-h | --help)
			usage
			exit 0
			;;
		--dry-run)
			dry_run=1
			;;
		--candidate)
			[ "$#" -ge 2 ] || die "--candidate needs a value"
			candidate="$2"
			shift
			;;
		--candidate=*)
			candidate="${1#--candidate=}"
			;;
		*)
			die "unknown argument '$1' (see --help)"
			;;
	esac
	shift
done

[ -n "$candidate" ] || die "--candidate is required: vmnet-hostonly, user-v2 or gateway-vm (see --help)"

# vz-tunnel: the guest-side end of the reverse tunnel, and the host proxy it
# ends at.
TUNNEL_PORT=3128
HOST_PROXY="${PJ_SPIKE_HOST_PROXY:-127.0.0.1:8080}"

case "$candidate" in
	vmnet-hostonly) default_proxy="192.168.106.1:8080" ;;
	user-v2) default_proxy="host.lima.internal:8080" ;;
	gateway-vm) default_proxy="<gateway-lima0-address>:8080" ;;
	vz-usernet) default_proxy="192.168.5.2:8080" ;;
	vz-tunnel) default_proxy="127.0.0.1:$TUNNEL_PORT" ;;
	*) die "unknown candidate '$candidate': expected vmnet-hostonly, user-v2, gateway-vm, vz-usernet or vz-tunnel" ;;
esac

TARGET="${PJ_SPIKE_TARGET:-1.1.1.1}"
TARGET_PORT="${PJ_SPIKE_TARGET_PORT:-443}"
RESOLVER="${PJ_SPIKE_RESOLVER:-8.8.8.8}"
DNS_NAME="${PJ_SPIKE_DNS_NAME:-example.com}"
SSH_HOST="${PJ_SPIKE_SSH_HOST:-github.com}"
# The host's own default gateway is a LAN address that's there on any
# network, unlike a guessed one such as 192.168.1.1.
default_gateway() {
	route -n get default 2>/dev/null | awk '$1 == "gateway:" { print $2; exit }' || true
}
LAN_ADDR="${PJ_SPIKE_LAN_ADDR:-$(default_gateway)}"
LAN_PORT="${PJ_SPIKE_LAN_PORT:-80}"
ALLOWED_HOST="${PJ_SPIKE_ALLOWED_HOST:-api.github.com}"
PROXY="${PJ_SPIKE_PROXY:-$default_proxy}"

agent_instance="${PJ_SANDBOX_INSTANCE_PREFIX}spike-$candidate"
agent_config="$SPIKE_LIMA_DIR/$candidate.yaml"
gw_instance=""
gw_config=""
if [ "$candidate" = gateway-vm ]; then
	gw_instance="${PJ_SANDBOX_INSTANCE_PREFIX}spike-gateway-vm-gw"
	gw_config="$SPIKE_LIMA_DIR/gateway-vm-gw.yaml"
fi

# enforce_script GW_ADDR
#
# What runs as root in the agent guest right after boot, before any probe: it
# snapshots the routes the guest booted with (flush-and-reroute restores them
# later, playing the attacker) and then applies the candidate's lockdown.
enforce_script() {
	cat <<EOF
set -u
ip -4 route show default > /run/pjsb-spike-boot-routes
ip -4 route show scope link proto kernel > /run/pjsb-spike-boot-links
EOF
	case "$candidate" in
		vmnet-hostonly)
			cat <<'EOF'
# Blackhole Lima's built-in NAT NIC; lima0 (host-only) is all that's left.
while ip -4 route del default dev eth0 2>/dev/null; do :; done
EOF
			;;
		user-v2)
			cat <<'EOF'
# Nothing in the guest: user-v2 relies on PJ_SPIKE_HOST_FILTER on the host.
EOF
			;;
		gateway-vm)
			cat <<EOF
# Blackhole Lima's built-in NAT NIC and route everything via the gateway VM.
while ip -4 route del default dev eth0 2>/dev/null; do :; done
ip -4 route replace default via $1 dev lima0
EOF
			;;
		vz-usernet)
			cat <<'EOF'
# eth0's link route to 192.168.5.2 (the host) is all that's left; Lima's
# resolver on the same subnet is blackholed.
while ip -4 route del default dev eth0 2>/dev/null; do :; done
ip -4 route replace blackhole 192.168.5.3/32
EOF
			;;
		vz-tunnel)
			cat <<'EOF'
# No NIC in use at all: ssh rides vsock, and the proxy arrives through the
# host's reverse tunnel on 127.0.0.1.
ip link set eth0 down
EOF
			;;
	esac
}

# probe_script SSH_ADDR TARGET_ADDR
#
# The escape attempts and the proxy-path check, run as root in the agent guest
# with bash. Prints one PASS/FAIL line per label; exits 1 if any FAILs.
probe_script() {
	cat <<EOF
set -u
TARGET=$2
TARGET_PORT=$TARGET_PORT
RESOLVER=$RESOLVER
DNS_NAME=$DNS_NAME
SSH_ADDR=$1
LAN_ADDR=$LAN_ADDR
LAN_PORT=$LAN_PORT
ALLOWED_HOST=$ALLOWED_HOST
PROXY=$PROXY
EOF
	cat <<'EOF'
fails=0

# blocked LABEL CMD...: PASS if CMD can't get through. On a FAIL, CMD's stderr
# follows, since that's where a probe says which route got out.
blocked() {
	label="$1"
	shift
	if err="$("$@" 2>&1 >/dev/null)"; then
		echo "FAIL [$label] reached: $*"
		[ -z "$err" ] || printf '%s\n' "$err"
		fails=1
	else
		echo "PASS [$label] blocked: $*"
	fi
}

# works LABEL CMD...: PASS if CMD gets through.
works() {
	label="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		echo "PASS [$label] works: $*"
	else
		echo "FAIL [$label] broken: $*"
		fails=1
	fi
}

# macvlan_escape: a container on a macvlan network off each guest NIC in
# turn, gatewayed the way that NIC was at boot. Succeeds if any reaches TARGET.
macvlan_escape() {
	reached=1
	for dev in $(ls /sys/class/net); do
		case "$dev" in lo | docker* | veth* | br-*) continue ;; esac
		# The subnet the NIC booted with, since the lockdown may have taken
		# the NIC down and its routes with it. The attacker brings it back.
		subnet="$(awk -v d="$dev" '$0 ~ "dev " d " " || $0 ~ "dev " d "$" {print $1; exit}' /run/pjsb-spike-boot-links)"
		[ -n "$subnet" ] || continue
		ip link set "$dev" up
		gw="$(awk -v d="$dev" '$0 ~ "dev " d " " || $0 ~ "dev " d "$" {print $3; exit}' /run/pjsb-spike-boot-routes)"
		docker network rm pjsb-spike-mv >/dev/null 2>&1 || true
		docker network create -d macvlan -o parent="$dev" --subnet "$subnet" ${gw:+--gateway "$gw"} pjsb-spike-mv >/dev/null 2>&1 || continue
		if docker run --rm --network pjsb-spike-mv alpine nc -z -w 5 "$TARGET" "$TARGET_PORT"; then
			echo "  macvlan off $dev reached $TARGET:$TARGET_PORT" >&2
			reached=0
		fi
		docker network rm pjsb-spike-mv >/dev/null 2>&1 || true
	done
	return "$reached"
}

# flush_and_reroute: drop every guest firewall rule, then point the default
# route at each gateway the guest booted with (and Lima's SLIRP gateway).
# Succeeds if TCP or DNS gets out through any of them.
flush_and_reroute() {
	iptables -F; iptables -P OUTPUT ACCEPT; iptables -t nat -F
	ip6tables -F 2>/dev/null; ip6tables -P OUTPUT ACCEPT 2>/dev/null
	nft flush ruleset 2>/dev/null
	for dev in $(ls /sys/class/net); do ip link set "$dev" up; done
	sleep 3
	reached=1
	while read -r _ _ gw _ dev _; do
		[ -n "$gw" ] || continue
		ip -4 route replace default via "$gw" dev "$dev" || continue
		if nc -z -w 5 "$TARGET" "$TARGET_PORT" || dig +time=3 +tries=1 "@$RESOLVER" "$DNS_NAME"; then
			echo "  via $gw dev $dev got out" >&2
			reached=0
		fi
	done < <(cat /run/pjsb-spike-boot-routes; echo "default via 192.168.5.2 dev eth0")
	return "$reached"
}

# [direct-tcp] a direct TCP connection
blocked direct-tcp nc -z -w 5 "$TARGET" "$TARGET_PORT"
# [dns-udp] [dns-tcp] DNS to an outside resolver
blocked dns-udp dig +time=3 +tries=1 "@$RESOLVER" "$DNS_NAME"
blocked dns-tcp dig +tcp +time=3 +tries=1 "@$RESOLVER" "$DNS_NAME"
# [ssh-22] SSH to an outside host
blocked ssh-22 nc -z -w 5 "$SSH_ADDR" 22
# [lan-rfc1918] a LAN address
blocked lan-rfc1918 nc -z -w 5 "$LAN_ADDR" "$LAN_PORT"
# [docker-macvlan] a container on a macvlan network
blocked docker-macvlan macvlan_escape
# [proxy-path] the allowlisted path through the proxy still works
works proxy-path curl -sk -o /dev/null --max-time 15 -x "http://$PROXY" "https://$ALLOWED_HOST/"
# [flush-and-reroute] iptables -F + nft flush + a route change, then TCP and
# DNS again. Last, because it wrecks the guest's network.
blocked flush-and-reroute flush_and_reroute

exit "$fails"
EOF
}

# gateway_script: starts the proxy on the gateway VM (nftables is already up
# from its provision).
gateway_script() {
	cat <<'EOF'
systemctl reset-failed pjsb-spike-proxy 2>/dev/null || true
systemd-run --unit pjsb-spike-proxy mitmdump --listen-host 0.0.0.0 --listen-port 8080
EOF
}

# Each of these runs the command, or with DRY_RUN=1 prints it instead.
DRY_RUN="$dry_run"
run_or_print() {
	if [ "$DRY_RUN" -eq 1 ]; then
		echo "$*"
	else
		"$@"
	fi
}

host_ssh() {
	run_or_print ssh -F "${LIMA_HOME:-$HOME/.lima}/$1/ssh.config" "lima-$1" true
}

# tunnel_cmd INSTANCE: vz-tunnel's reverse tunnel. Over the instance's own
# ssh (vsock), the guest's 127.0.0.1:TUNNEL_PORT ends at HOST_PROXY on the
# host, so the guest reaches its proxy without using any NIC.
tunnel_cmd() {
	echo ssh -F "${LIMA_HOME:-$HOME/.lima}/$1/ssh.config" -N \
		-o ExitOnForwardFailure=yes -o ServerAliveInterval=15 \
		-R "127.0.0.1:$TUNNEL_PORT:$HOST_PROXY" "lima-$1"
}

limactl_start() {
	run_or_print limactl start --tty=false --name="$1" "$2"
}

# control LABEL CMD...: a host-side check that the target is reachable at
# all, so a guest probe that fails proves the block, not a dead target. With
# DRY_RUN=1 it prints the command instead.
control() {
	label="$1"
	shift
	if [ "$DRY_RUN" -eq 1 ]; then
		echo "[$label] $*"
	elif "$@" >/dev/null 2>&1; then
		echo "CONTROL-OK [$label]"
	else
		echo "CONTROL-UNREACHABLE [$label] the host can't reach this either: $*"
	fi
}

# host_controls TARGET_ADDR SSH_ADDR
#
# macOS nc ignores -w while connecting, so without -G a control against an
# address that never answers sits out the ~75s TCP connect timeout.
host_controls() {
	control direct-tcp nc -z -G 5 -w 5 "$1" "$TARGET_PORT"
	control dns-udp dig +time=3 +tries=1 "@$RESOLVER" "$DNS_NAME"
	control dns-tcp dig +tcp +time=3 +tries=1 "@$RESOLVER" "$DNS_NAME"
	control ssh-22 nc -z -G 5 -w 5 "$2" 22
	control lan-rfc1918 nc -z -G 5 -w 5 "$LAN_ADDR" "$LAN_PORT"
}

if [ "$dry_run" -eq 1 ]; then
	[ -n "$LAN_ADDR" ] || LAN_ADDR="<default-gateway>"
	for config in $gw_config $agent_config; do
		echo "== Lima config: $config =="
		cat "$config"
		echo
	done

	echo "== Controls (from the host) =="
	host_controls "$TARGET" "$SSH_HOST"
	echo
	echo "== Boot =="
	[ -z "$gw_instance" ] || limactl_start "$gw_instance" "$gw_config"
	limactl_start "$agent_instance" "$agent_config"
	echo
	if [ -n "$gw_instance" ]; then
		echo "== Gateway setup (limactl shell $gw_instance sudo bash -s) =="
		gateway_script
		echo
	fi
	if [ "$candidate" = user-v2 ]; then
		echo "== Host filter =="
		echo "${PJ_SPIKE_HOST_FILTER:-<PJ_SPIKE_HOST_FILTER unset: no outside filter>}"
		echo
	fi
	echo "== Enforce (limactl shell $agent_instance sudo bash -s) =="
	enforce_script "<gateway-lima0-address>"
	echo
	if [ "$candidate" = vz-tunnel ]; then
		echo "== Reverse tunnel (in the background, from the host) =="
		tunnel_cmd "$agent_instance"
		echo
	fi
	echo "== Probes (limactl shell $agent_instance sudo bash -s) =="
	probe_script "$SSH_HOST" "$TARGET"
	echo
	echo "== Host checks =="
	echo "[host-ssh] $(host_ssh "$agent_instance")"
	echo
	echo "== Teardown (always, even after a failure) =="
	[ "$candidate" != vz-tunnel ] || echo "kill <tunnel pid>   (stop the reverse tunnel)"
	for inst in $gw_instance $agent_instance; do
		echo "limactl delete --force $inst"
	done
	exit 0
fi

# --- live run ---

command -v limactl >/dev/null 2>&1 || die "limactl not found"
[ -n "$LAN_ADDR" ] || die "couldn't find the host's default gateway; set PJ_SPIKE_LAN_ADDR to a LAN host that listens"

# Resolve on the host, so a guest whose DNS is (rightly) blocked still aims
# each probe at a real address instead of passing because a name didn't resolve.
resolve() {
	python3 -c 'import socket, sys; print(socket.gethostbyname(sys.argv[1]))' "$1"
}
target_addr="$(resolve "$TARGET")"
ssh_addr="$(resolve "$SSH_HOST")"

for inst in $gw_instance $agent_instance; do
	if limactl list --quiet 2>/dev/null | grep -qx "$inst"; then
		die "$inst already exists; delete it first (limactl delete --force $inst)"
	fi
done

started=""
filtered=0
tunnel_pid=""
teardown() {
	status=$?
	trap - EXIT INT TERM
	[ -z "$tunnel_pid" ] || kill "$tunnel_pid" 2>/dev/null || true
	if [ "$filtered" -eq 1 ] && [ -n "${PJ_SPIKE_HOST_UNFILTER:-}" ]; then
		sh -c "$PJ_SPIKE_HOST_UNFILTER" || echo "spike_egress.sh: PJ_SPIKE_HOST_UNFILTER failed" >&2
	fi
	for inst in $started; do
		limactl delete --force "$inst" || echo "spike_egress.sh: failed to delete $inst" >&2
	done
	exit "$status"
}
trap teardown EXIT
trap 'exit 130' INT TERM

echo "== Controls (from the host) =="
host_controls "$target_addr" "$ssh_addr"

gw_addr=""
if [ -n "$gw_instance" ]; then
	started="$gw_instance"
	limactl_start "$gw_instance" "$gw_config"
	gateway_script | limactl shell "$gw_instance" sudo bash -s
	gw_addr="$(limactl shell "$gw_instance" ip -4 -o addr show dev lima0 | awk '{sub("/.*", "", $4); print $4; exit}')"
	[ -n "$gw_addr" ] || die "couldn't find the gateway VM's lima0 address"
	[ -n "${PJ_SPIKE_PROXY:-}" ] || PROXY="$gw_addr:8080"
fi

started="$started $agent_instance"
limactl_start "$agent_instance" "$agent_config"

if [ "$candidate" = user-v2 ]; then
	if [ -n "${PJ_SPIKE_HOST_FILTER:-}" ]; then
		filtered=1
		sh -c "$PJ_SPIKE_HOST_FILTER"
	else
		echo "spike_egress.sh: PJ_SPIKE_HOST_FILTER unset -- probing user-v2 with no outside filter" >&2
	fi
fi

enforce_script "$gw_addr" | limactl shell "$agent_instance" sudo bash -s

if [ "$candidate" = vz-tunnel ]; then
	# shellcheck disable=SC2046 # tunnel_cmd prints one word per argument
	$(tunnel_cmd "$agent_instance") &
	tunnel_pid=$!
	sleep 3
	kill -0 "$tunnel_pid" 2>/dev/null || die "the reverse tunnel into $agent_instance didn't stay up (is a proxy listening on $HOST_PROXY?)"
fi

echo "== Probes (root in $agent_instance) =="
rc=0
probe_script "$ssh_addr" "$target_addr" | limactl shell "$agent_instance" sudo bash -s || rc=1

echo "== Host checks =="
if host_ssh "$agent_instance" >/dev/null 2>&1; then
	echo "PASS [host-ssh] works: ssh into $agent_instance"
else
	echo "FAIL [host-ssh] broken: ssh into $agent_instance"
	rc=1
fi

exit "$rc"
