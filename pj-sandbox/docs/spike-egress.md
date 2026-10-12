# Egress enforcement spike

Which mechanism keeps a pj-sandbox guest's only network route ending at the
host proxy, enforced from outside the guest (issues/prd-pj-sandbox.md,
"Egress enforcement point"; issue 009). The guest has root, so anything it
can undo doesn't count.

The tooling is `pj-sandbox/test/live/spike_egress.sh`, with one Lima config
per candidate in `pj-sandbox/lima/spike/`. It needs a real Mac host with Lima
and socket_vmnet, so it's run by hand (MT-4 in `issues/manual-tests.md`).

## Pass criteria

A candidate passes when every escape attempt reports `PASS` and both
must-keep-working checks report `PASS`:

| Label                 | What it tries, as root in the guest                                    |
|-----------------------|------------------------------------------------------------------------|
| `direct-tcp`          | a TCP connection to a non-allowlisted target (`PJ_SPIKE_TARGET`)       |
| `dns-udp` / `dns-tcp` | DNS to an outside resolver on UDP and TCP 53                           |
| `ssh-22`              | port 22 on an outside host                                             |
| `lan-rfc1918`         | a LAN address (set `PJ_SPIKE_LAN_ADDR` to one that's really listening) |
| `docker-macvlan`      | the same TCP connection from a container on a macvlan network          |
| `flush-and-reroute`   | TCP and DNS again after `iptables -F`, `nft flush ruleset` and pointing the default route at every gateway the guest booted with |
| `proxy-path`          | must work: HTTPS to `PJ_SPIKE_ALLOWED_HOST` through the proxy          |
| `host-ssh`            | must work: ssh from the host into the guest                            |

Before probing, the script tries the same targets from the host. A
`CONTROL-UNREACHABLE` line means the host can't reach that target either, so
a `PASS` against it proves nothing. Pick a different target and run again.

`flush-and-reroute` runs last because it wrecks the guest's network. The VM is
deleted at the end whatever happens, so there's nothing to restore.

## Open question shared by every candidate

Lima always gives a guest its built-in user-mode NIC (`eth0`: SLIRP under
QEMU), and the config can't remove it. It's also what host→guest ssh rides on
under QEMU. The vmnet-hostonly and gateway-vm candidates only delete its
default route from inside the guest, and `flush-and-reroute` puts that route
back through `192.168.5.2`. If that gets out, the candidate fails as
configured. The finding should say whether there's a host-side way to close
that NIC (e.g. a vz VM with only a vmnet NIC, or a pf rule on the usernet
process) or whether the candidate is out.

Status (2026-10-12): deferred. The 12:07/12:12 runs showed `eth0` is the
only leak for both vmnet-hostonly and gateway-vm (`docker-macvlan` and
`flush-and-reroute`). Closing it from the host is put off for now. The lead
for when this is picked up again is QEMU's `-netdev user,...,restrict=on`.
Lima builds `user,id=net0,...,hostfwd=tcp:...-:22`, so a wrapper could be
supplied through Lima's `QEMU_SYSTEM_<arch>` override (not yet tested). That
would also mean provisioning through the proxy instead of `eth0`. The other
option is to retest both candidates under `vmType: vz`.

## Candidate: vmnet-hostonly

A socket_vmnet host-only network (`lima: host`, 192.168.106.0/24) with no
route off the Mac. Lima's NAT NIC is blackholed after boot, and the guest
reaches the proxy at the host's address on that network.

Config: `pj-sandbox/lima/spike/vmnet-hostonly.yaml`

Commands:

    mitmdump --listen-host 192.168.106.1 --listen-port 8080 &   # the stand-in proxy
    pj-sandbox/test/live/spike_egress.sh --dry-run --candidate vmnet-hostonly
    pj-sandbox/test/live/spike_egress.sh --candidate vmnet-hostonly

Results (2026-10-12, Lima 2.2.0, macOS 26.6.2, qemu):

| Label               | Result |
|---------------------|--------|
| `direct-tcp`        | PASS (blocked) |
| `dns-udp`           | PASS (blocked) |
| `dns-tcp`           | PASS (blocked) |
| `ssh-22`            | PASS (blocked) |
| `lan-rfc1918`       | PASS (blocked) |
| `docker-macvlan`    | FAIL (reached) |
| `flush-and-reroute` | FAIL (reached) |
| `proxy-path`        | PASS (rerun, `mitmdump` bound to 192.168.106.1:8080) |
| `host-ssh`          | PASS |

Both failures are Lima's user-mode `eth0`, the open question above (rerun 12:07/12:12 with probe stderr shown): `macvlan off eth0 reached 1.1.1.1:443` and `via 192.168.5.2 dev eth0 got out`. Everything else held, so the candidate passes if `eth0` can be closed from the host.

## Candidate: user-v2

Lima's `user-v2` network (gvisor-tap-vsock, 192.168.104.0/24). Every guest
connection leaves the Mac as a socket of the host-side usernet process, so the
filter has to be on the host. Put the command that installs it (for example, a
`pfctl -a` anchor) in `PJ_SPIKE_HOST_FILTER`, and the one that removes it in
`PJ_SPIKE_HOST_UNFILTER`. The script runs them after boot and at teardown.
With no filter set, the run is a baseline of what user-v2 allows.

Config: `pj-sandbox/lima/spike/user-v2.yaml`

Commands:

    mitmdump --listen-port 8080 &
    pj-sandbox/test/live/spike_egress.sh --dry-run --candidate user-v2
    PJ_SPIKE_HOST_FILTER='…' PJ_SPIKE_HOST_UNFILTER='…' \
        pj-sandbox/test/live/spike_egress.sh --candidate user-v2

Filter used:

Results (date, Lima and macOS versions):

| Label               | Result |
|---------------------|--------|
| `direct-tcp`        |        |
| `dns-udp`           |        |
| `dns-tcp`           |        |
| `ssh-22`            |        |
| `lan-rfc1918`       |        |
| `docker-macvlan`    |        |
| `flush-and-reroute` |        |
| `proxy-path`        |        |
| `host-ssh`          |        |

Baseline, no filter (2026-10-12, Lima 2.2.0, macOS 26.6.2, vz). Run with
`PJ_SPIKE_HOST_FILTER` unset and no `mitmdump` on the host, so this only
shows what user-v2 allows by itself. It isn't a candidate result.

| Label               | Result |
|---------------------|--------|
| `direct-tcp`        | FAIL (reached) |
| `dns-udp`           | FAIL (reached) |
| `dns-tcp`           | FAIL (reached) |
| `ssh-22`            | FAIL (reached) |
| `lan-rfc1918`       | FAIL (reached) |
| `docker-macvlan`    | FAIL (reached) |
| `flush-and-reroute` | PASS (blocked) |
| `proxy-path`        | FAIL (broken; no proxy was listening on the host's :8080) |
| `host-ssh`          | PASS |

Under vz, Lima's ssh rides vsock (`vsock forwarder: 127.0.0.1:<port> ->
vsock:22`), not the usernet NIC.

## Candidate: gateway-vm

A Qubes-style firewall VM. A second Lima VM (`pjsb-spike-gateway-vm-gw`,
`gateway-vm-gw.yaml`) shares the host-only network with the agent VM, forwards
nothing (nftables `forward` policy drop, `ip_forward=0`), accepts only :8080 on
that network, and runs `mitmdump` there. The agent's NAT NIC is blackholed and
its default route points at the gateway. The script starts the gateway's proxy
itself.

Configs: `pj-sandbox/lima/spike/gateway-vm.yaml` (agent),
`pj-sandbox/lima/spike/gateway-vm-gw.yaml` (gateway)

Commands:

    pj-sandbox/test/live/spike_egress.sh --dry-run --candidate gateway-vm
    pj-sandbox/test/live/spike_egress.sh --candidate gateway-vm

Results (2026-10-12, Lima 2.2.0, macOS 26.6.2, qemu):

| Label               | Result |
|---------------------|--------|
| `direct-tcp`        | PASS (blocked) |
| `dns-udp`           | PASS (blocked) |
| `dns-tcp`           | PASS (blocked) |
| `ssh-22`            | PASS (blocked) |
| `lan-rfc1918`       | PASS (blocked) |
| `docker-macvlan`    | FAIL (reached) |
| `flush-and-reroute` | FAIL (reached) |
| `proxy-path`        | PASS |
| `host-ssh`          | PASS |

Both failures are Lima's user-mode `eth0`, the open question above (rerun 12:07/12:12 with probe stderr shown): `macvlan off eth0 reached 1.1.1.1:443` and `via 192.168.5.2 dev eth0 got out`. Everything else held, so the candidate passes if `eth0` can be closed from the host.

## Findings
