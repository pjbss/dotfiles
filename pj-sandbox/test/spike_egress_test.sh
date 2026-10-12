#!/bin/bash
# spike_egress_test.sh
#
# Hermetic checks for the egress-enforcement spike tooling
# (pj-sandbox/test/live/spike_egress.sh). The spike itself needs a real Mac
# host with Lima and is run by hand (MT-4 in issues/manual-tests.md); these
# tests only prove its --help and --dry-run surfaces, its Lima configs and its
# write-up skeleton, with `limactl` stubbed to fail loudly if it's ever called.

set -euo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PJ_SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"
. "$TEST_DIR/../../test/assert.sh"

SPIKE="$PJ_SANDBOX_DIR/test/live/spike_egress.sh"
SPIKE_LIMA_DIR="$PJ_SANDBOX_DIR/lima/spike"
SPIKE_DOC="$PJ_SANDBOX_DIR/docs/spike-egress.md"
VZ_DOC="$PJ_SANDBOX_DIR/docs/spike-egress-vz.md"
# The original candidates (spike-egress.md), and the vz ones added when
# ThreatLocker started killing qemu and socket_vmnet (spike-egress-vz.md).
ORIGINAL_CANDIDATES="vmnet-hostonly user-v2 gateway-vm"
VZ_CANDIDATES="vz-usernet vz-tunnel"
CANDIDATES="$ORIGINAL_CANDIDATES $VZ_CANDIDATES"

# A limactl that records any call and fails, first on PATH.
stub_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir"' EXIT
cat > "$stub_dir/limactl" <<STUB
#!/bin/sh
echo "limactl \$*" >> "$stub_dir/limactl.calls"
echo "limactl stub: must not be called" >&2
exit 99
STUB
# A `route` that reports a fixed default gateway, so the LAN default is
# hermetic.
cat > "$stub_dir/route" <<'STUB'
#!/bin/sh
printf '   route to: default\ndestination: default\n    gateway: 10.11.12.1\n  interface: en0\n'
STUB
chmod +x "$stub_dir/limactl" "$stub_dir/route"
PATH="$stub_dir:$PATH"
export PATH

# The escape attempts, by the label each is printed under.
ATTEMPTS="direct-tcp flush-and-reroute dns-udp dns-tcp ssh-22 lan-rfc1918 docker-macvlan"

# --- --help ---

if out="$("$SPIKE" --help 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "spike_egress.sh --help exits 0"
for c in $CANDIDATES; do
	assert_contains "$out" "$c" "--help documents candidate '$c'"
done
for a in $ATTEMPTS; do
	assert_contains "$out" "$a" "--help documents escape attempt '$a'"
done
assert_contains "$out" "--dry-run" "--help documents --dry-run"

# --- argument errors ---

if out="$("$SPIKE" 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "no --candidate exits 1"
assert_contains "$out" "--candidate" "no --candidate says it's required"

if out="$("$SPIKE" --dry-run --candidate bogus 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "an unknown candidate exits 1"
assert_contains "$out" "unknown candidate 'bogus'" "an unknown candidate is named in the error"

# --- --dry-run ---

for c in $CANDIDATES; do
	if out="$("$SPIKE" --dry-run --candidate "$c" 2>&1)"; then rc=0; else rc=$?; fi
	assert_exit_code 0 "$rc" "--dry-run --candidate $c exits 0"
	assert_contains "$out" "$SPIKE_LIMA_DIR/$c.yaml" "--dry-run $c names its Lima config"
	assert_contains "$out" "$(sed -n '/^[a-z]/{p;q;}' "$SPIKE_LIMA_DIR/$c.yaml")" "--dry-run $c prints its Lima config's contents"
	for a in $ATTEMPTS; do
		assert_contains "$out" "[$a]" "--dry-run $c prints the '$a' probe"
	done
	assert_contains "$out" "iptables -F" "--dry-run $c prints the iptables flush"
	assert_contains "$out" "macvlan" "--dry-run $c prints the macvlan container probe"
	assert_contains "$out" "[proxy-path]" "--dry-run $c prints the allowlisted proxy check"
	assert_contains "$out" "[host-ssh]" "--dry-run $c prints the host->guest ssh check"
	assert_contains "$out" "limactl delete --force pjsb-spike-" "--dry-run $c prints the teardown it would run"
done

# --- host controls ---

# macOS nc ignores -w while connecting, so a control against an address that
# never answers would sit out the ~75s TCP connect timeout; -G bounds it.
out="$(env -u PJ_SPIKE_LAN_ADDR "$SPIKE" --dry-run --candidate user-v2 2>&1)" || true
controls="$(printf '%s\n' "$out" | awk '/^== Controls/ { on = 1; next } /^== / { on = 0 } on && NF')"
for label in direct-tcp dns-udp dns-tcp ssh-22 lan-rfc1918; do
	assert_contains "$controls" "[$label]" "--dry-run prints the '$label' host control"
done
nc_controls="$(printf '%s\n' "$controls" | grep ' nc ' || true)"
assert_eq "3" "$(printf '%s\n' "$nc_controls" | grep -c . || true)" "three host controls use nc"
assert_eq "" "$(printf '%s\n' "$nc_controls" | grep -v -- ' -G ' || true)" "every host nc control bounds its connect with -G"

assert_contains "$controls" "[lan-rfc1918] nc -z -G 5 -w 5 10.11.12.1 80" "the LAN target defaults to the host's default gateway"
out="$(PJ_SPIKE_LAN_ADDR=172.16.9.9 "$SPIKE" --dry-run --candidate user-v2 2>&1)" || true
assert_contains "$out" "172.16.9.9" "PJ_SPIKE_LAN_ADDR overrides the LAN target"

if out="$("$SPIKE" --dry-run --candidate gateway-vm 2>&1)"; then :; fi
assert_contains "$out" "$SPIKE_LIMA_DIR/gateway-vm-gw.yaml" "--dry-run gateway-vm also names the gateway VM's config"

out="$(PJ_SPIKE_TARGET=203.0.113.9 "$SPIKE" --dry-run --candidate user-v2 2>&1)" || true
assert_contains "$out" "203.0.113.9" "PJ_SPIKE_TARGET overrides the non-allowlisted target"

assert_eq "" "$(cat "$stub_dir/limactl.calls" 2>/dev/null || true)" "--help and --dry-run never call limactl"

# A probe that gets out says on stderr which route it used; `blocked` has to
# show that under the FAIL line, or a failing run can't say what leaked.
probe="$("$SPIKE" --dry-run --candidate user-v2 2>&1)" || true
blocked_fn="$(printf '%s\n' "$probe" | sed -n '/^blocked() {$/,/^}$/p')"
leak() { echo "  via 192.0.2.1 dev eth0 got out" >&2; }
out="$(eval "$blocked_fn"; blocked fake-leak leak 2>&1)"
assert_contains "$out" "FAIL [fake-leak] reached: leak" "blocked reports a probe that got out"
assert_contains "$out" "via 192.0.2.1 dev eth0 got out" "blocked shows the escaping probe's own explanation"

# --- Lima configs ---

for c in $CANDIDATES; do
	assert_ok "Lima config exists for $c" test -f "$SPIKE_LIMA_DIR/$c.yaml"
done
for f in "$SPIKE_LIMA_DIR"/*.yaml; do
	name="${f#"$PJ_SANDBOX_DIR/"}"
	# Commented-out keys don't count; only a live top-level `mounts:` with
	# anything but an empty list does.
	mounts="$(grep -E '^mounts:' "$f" || true)"
	if [ -z "$mounts" ] || [ "$mounts" = "mounts: []" ]; then
		echo "PASS: $name declares no host mounts"
	else
		echo "FAIL: $name declares no host mounts (found '$mounts')"
		failures=$((failures + 1))
	fi
	assert_contains "$(cat "$f")" "mounts: []" "$name pins mounts to an empty list, overriding Lima's default home mount"
done

# --- vz candidates ---

for c in $VZ_CANDIDATES; do
	cfg="$(grep -v '^[[:space:]]*#' "$SPIKE_LIMA_DIR/$c.yaml" 2>/dev/null || true)"
	assert_contains "$cfg" "vmType: vz" "$c.yaml boots with vz, not qemu"
	assert_eq "" "$(printf '%s\n' "$cfg" | grep -E 'lima: *(host|shared|bridged)|socket:' || true)" "$c.yaml needs no socket_vmnet network"
done

out="$("$SPIKE" --dry-run --candidate vz-usernet 2>&1)" || true
assert_contains "$out" "blackhole 192.168.5.3" "vz-usernet blackholes Lima's resolver"
assert_contains "$out" "192.168.5.2:8080" "vz-usernet reaches the host proxy at host.lima.internal by default"

out="$("$SPIKE" --dry-run --candidate vz-tunnel 2>&1)" || true
assert_contains "$out" "ip link set eth0 down" "vz-tunnel takes eth0 down"
assert_contains "$out" "-R 127.0.0.1:3128:127.0.0.1:8080" "vz-tunnel opens a reverse tunnel from the guest's 3128 to the host proxy"
assert_contains "$out" "PROXY=127.0.0.1:3128" "vz-tunnel's guest uses the tunnel as its proxy"
teardown="$(printf '%s\n' "$out" | sed -n '/^== Teardown/,$p')"
assert_contains "$teardown" "stop the reverse tunnel" "vz-tunnel's teardown stops the tunnel"
out="$("$SPIKE" --dry-run --candidate vz-usernet 2>&1)" || true
assert_not_contains "$out" "-R 127.0.0.1:3128" "vz-usernet opens no tunnel"

# A NIC the lockdown took down mustn't make the reroute and macvlan probes
# pass without trying: the attacker brings it back up first, and uses the
# link subnets the guest booted with.
probe="$(printf '%s\n' "$out" | sed -n '/^== Probes/,/^== Host checks/p')"
assert_contains "$probe" 'ip link set "$dev" up' "the probes bring each NIC back up"
assert_contains "$probe" "/run/pjsb-spike-boot-links" "macvlan uses the link subnets the guest booted with"
enforce="$(printf '%s\n' "$out" | sed -n '/^== Enforce/,/^== Probes/p')"
assert_contains "$enforce" "> /run/pjsb-spike-boot-links" "enforcement snapshots the boot-time link subnets first"

assert_eq "" "$(cat "$stub_dir/limactl.calls" 2>/dev/null || true)" "the vz dry runs never call limactl"

# The candidate list in the "required" error names every candidate.
out="$("$SPIKE" 2>&1)" || true
for c in $CANDIDATES; do
	assert_contains "$out" "$c" "the --candidate-required error names '$c'"
done

# Lima's ssh.config multiplexes (ControlMaster auto, ControlPersist yes), so
# a tunnel ssh that used it would hand -R to the shared master and exit at
# once, leaving nothing for the liveness check or teardown to hold.
out="$("$SPIKE" --dry-run --candidate vz-tunnel 2>&1)" || true
tunnel_line="$(printf '%s\n' "$out" | grep -- ' -R 127.0.0.1:3128' || true)"
assert_contains "$tunnel_line" "-o ControlMaster=no" "the tunnel ssh doesn't become or use a mux master"
assert_contains "$tunnel_line" "-o ControlPath=none" "the tunnel ssh ignores Lima's ControlPath"

# Each NIC-up line is pinned inside its own function.
probe="$(printf '%s\n' "$out" | sed -n '/^== Probes/,/^== Host checks/p')"
macvlan_fn="$(printf '%s\n' "$probe" | sed -n '/^macvlan_escape() {$/,/^}$/p')"
flush_fn="$(printf '%s\n' "$probe" | sed -n '/^flush_and_reroute() {$/,/^}$/p')"
assert_contains "$macvlan_fn" 'ip link set "$dev" up' "docker-macvlan brings each NIC back up"
assert_contains "$flush_fn" 'ip link set "$dev" up' "flush-and-reroute brings each NIC back up"

# proxy-path runs before anything brings a NIC back up, so for vz-tunnel it
# really is tested with eth0 down.
proxy_line="$(printf '%s\n' "$probe" | grep -n '^works proxy-path' | cut -d: -f1)"
macvlan_line="$(printf '%s\n' "$probe" | grep -n '^blocked docker-macvlan' | cut -d: -f1)"
if [ -n "$proxy_line" ] && [ -n "$macvlan_line" ] && [ "$proxy_line" -lt "$macvlan_line" ]; then
	echo "PASS: proxy-path runs before docker-macvlan brings eth0 back up"
else
	echo "FAIL: proxy-path runs before docker-macvlan brings eth0 back up (proxy-path line ${proxy_line:-none}, docker-macvlan line ${macvlan_line:-none})"
	failures=$((failures + 1))
fi

# --- vz-tunnel live path ---
#
# limactl, ssh, nc and dig are stubbed; every address is an IP literal, so
# nothing touches the network. The tunnel ssh stub stays up until it's
# signalled, like a real one, and records that it was.

live="$(mktemp -d)"
mkdir -p "$live/bin"
cat > "$live/bin/limactl" <<STUB
#!/bin/sh
echo "limactl \$*" >> "$live/calls"
case "\$1" in
	shell) cat >/dev/null ;;
esac
exit 0
STUB
cat > "$live/bin/ssh" <<STUB
#!/bin/sh
case "\$*" in
	*" -R "*)
		echo "tunnel \$*" >> "$live/calls"
		# Let go of the caller's output, so a tunnel nobody kills can't hold
		# the test's command substitution open; give up after 15s instead.
		exec >/dev/null 2>&1
		trap 'echo "tunnel killed" >> "$live/calls"; exit 0' TERM
		n=0
		while [ "\$n" -lt 75 ]; do sleep 0.2; n=\$((n + 1)); done
		echo "tunnel never killed" >> "$live/calls"
		;;
esac
exit 0
STUB
# The host proxy answers only when PROXY_UP=1.
cat > "$live/bin/nc" <<'STUB'
#!/bin/sh
case "$*" in
	*" 18080") [ "${PROXY_UP:-0}" = 1 ] ;;
	*) exit 0 ;;
esac
STUB
printf '#!/bin/sh\nexit 0\n' > "$live/bin/dig"
chmod +x "$live/bin/"*
run_live() {
	PATH="$live/bin:$PATH" PJ_SPIKE_HOST_PROXY=127.0.0.1:18080 PJ_SPIKE_SSH_HOST=192.0.2.22 \
		PJ_SPIKE_LAN_ADDR=192.0.2.1 "$SPIKE" --candidate vz-tunnel </dev/null 2>&1
}

: > "$live/calls"
if out="$(PROXY_UP=0 run_live)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "vz-tunnel stops when nothing listens on the host proxy"
assert_contains "$out" "127.0.0.1:18080" "the missing-proxy error names the host proxy"
assert_eq "" "$(grep '^tunnel ' "$live/calls" || true)" "no tunnel is started without a host proxy"
assert_contains "$(cat "$live/calls")" "limactl delete --force pjsb-spike-vz-tunnel" "the VM is still deleted"

: > "$live/calls"
out="$(PROXY_UP=1 run_live)" || true
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q 'tunnel killed' "$live/calls" && break; sleep 0.2; done
calls="$(cat "$live/calls")"
assert_contains "$calls" "-o ControlMaster=no" "the live tunnel ssh runs without the mux master"
assert_contains "$calls" "tunnel killed" "teardown stops the tunnel ssh it started"
assert_contains "$calls" "limactl delete --force pjsb-spike-vz-tunnel" "teardown deletes the VM"
assert_not_contains "$out" "didn't stay up" "a tunnel that stays up isn't reported as dead"
rm -rf "$live"

# --- write-up skeleton ---

assert_ok "pj-sandbox/docs/spike-egress-vz.md exists" test -f "$VZ_DOC"
vz_doc="$(cat "$VZ_DOC" 2>/dev/null || true)"
for c in $VZ_CANDIDATES; do
	assert_contains "$vz_doc" "## Candidate: $c" "spike-egress-vz.md has a section for $c"
done
assert_eq "## Findings" "$(grep -E '^## ' "$VZ_DOC" 2>/dev/null | tail -1)" "spike-egress-vz.md ends with a ## Findings section"

assert_ok "pj-sandbox/docs/spike-egress.md exists" test -f "$SPIKE_DOC"
doc="$(cat "$SPIKE_DOC" 2>/dev/null || true)"
for c in $ORIGINAL_CANDIDATES; do
	assert_contains "$doc" "## Candidate: $c" "spike-egress.md has a section for $c"
done
assert_eq "## Findings" "$(grep -E '^## ' "$SPIKE_DOC" 2>/dev/null | tail -1)" "spike-egress.md ends with a ## Findings section"

assert_report
