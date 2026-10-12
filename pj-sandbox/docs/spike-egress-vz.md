# Egress enforcement spike: vz

Can a pj-sandbox guest still have its egress enforced when the host won't
run QEMU or socket_vmnet (issue 028)? It's the same question as
`spike-egress.md`, asked again because that spike's answer can no longer
boot on the Mac.

## Why this spike exists

On 2026-10-12, ThreatLocker (an application-allowlisting Endpoint Security
agent on the Mac) started killing `/opt/socket_vmnet/bin/socket_vmnet` and
`/opt/homebrew/bin/qemu-system-aarch64` at exec. Each exits 137 even when run
unprivileged with `--version`. This is permanent. Every pj-sandbox VM is
`vmType: qemu` on the socket_vmnet `host` network (`spike-egress.md`,
"Findings"), so none can boot.

`limactl` itself still runs. It has the `com.apple.security.virtualization`
entitlement, so on Lima 2.2.0 the following run inside `limactl`, with no
other binary involved:

- `vmType: vz`, using Apple's Virtualization.framework
- Lima's built-in network, which on vz is gvisor-tap-vsock
- ssh over vsock (`ssh.overVsock`, the default for vz Linux guests)

`spike-egress.md` is left as it was, as the record of the original decision.

## Pass criteria

The same as `spike-egress.md`, with the same labels, controls and teardown:
`spike_egress.sh` runs every escape attempt against every candidate.

For both vz candidates, `flush-and-reroute` and `docker-macvlan` play a
stronger attacker. They bring every NIC back up and use the link subnets
the guest booted with, which the lockdown snapshots to
`/run/pjsb-spike-boot-links` before it does anything. Without that, a NIC
the lockdown took down would make both probes pass without trying
anything.

## Open question shared by both candidates

Lima has no setting to boot a vz VM without its built-in NIC. `networks:`
only adds NICs, and Lima's annotated `default.yaml` documents no way to
remove one. So whatever the lockdown does to `eth0` happens inside the
guest, and root can undo it. Both candidates are expected to fail
`flush-and-reroute` the way vmnet-hostonly did. That would leave them no
worse than the accepted `eth0` gap in `spike-egress.md`, but no better.

What the runs should settle:

1. **Does a vz VM boot and provision at all** under ThreatLocker?
2. **Does the proxy path work:**
   - for vz-usernet, through 192.168.5.2 to the host's 127.0.0.1;
   - for vz-tunnel, through an ssh reverse tunnel over vsock with `eth0`
     down?
3. **Does `eth0` still leak**, and through which probe?
4. **Does the guest work with `eth0` down?** That is the vz-tunnel
   question. If it does, a NIC-less vz VM would close the `eth0` gap from
   outside, should Lima (or a small patch to it) ever allow one.

## Candidate: vz-usernet

`vmType: vz` with only Lima's built-in network. The lockdown deletes `eth0`'s
default route and blackholes Lima's resolver at 192.168.5.3, so the only
thing left on `eth0` is its link route to 192.168.5.2. On Lima's usernet,
that address is the host's loopback, where the proxy listens. This is the
current Findings mechanism, with `eth0` doing the job `lima0` did. Unlike
`lima0`, the proxy is on the host's 127.0.0.1, which every guest and every
local process can reach. So the "guests share one network" gap stays open.

Config: `pj-sandbox/lima/spike/vz-usernet.yaml`

Commands:

    mitmdump --listen-host 127.0.0.1 --listen-port 8080 &   # the stand-in proxy
    pj-sandbox/test/live/spike_egress.sh --dry-run --candidate vz-usernet
    pj-sandbox/test/live/spike_egress.sh --candidate vz-usernet

Results (not yet run):

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

## Candidate: vz-tunnel

`vmType: vz` with ssh over vsock. The lockdown takes `eth0` down entirely.
The host then runs `ssh -R 127.0.0.1:3128:127.0.0.1:8080` into the guest over
vsock, using whatever `ssh` is first on the host's PATH. macOS's own
`/usr/bin/ssh` is Apple-signed, which ThreatLocker should allow. The
guest's only proxy is then 127.0.0.1:3128. While `eth0` stays down, each
task's tunnel ends at its own proxy port, and the guest has no route to
another task's. Root can bring `eth0` back up and reach 192.168.5.2,
though, so that holds no better than the lockdown does. Lima's own
`portForwards` can't be used for this, because it only reverses unix
sockets, not TCP. The tunnel is killed at teardown.

Config: `pj-sandbox/lima/spike/vz-tunnel.yaml`

Commands:

    mitmdump --listen-host 127.0.0.1 --listen-port 8080 &   # the stand-in proxy
    pj-sandbox/test/live/spike_egress.sh --dry-run --candidate vz-tunnel
    pj-sandbox/test/live/spike_egress.sh --candidate vz-tunnel

Set `PJ_SPIKE_HOST_PROXY` if the stand-in proxy listens somewhere other than
127.0.0.1:8080.

Results (not yet run):

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

## Findings

