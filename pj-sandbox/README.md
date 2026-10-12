# pj-sandbox

The next-generation agent sandbox: a Lima VM per task that holds no host
credentials and no host mounts. The guest gets the repo as a cloned git bundle,
and reaches the network only through a host-side proxy that enforces egress
policy and injects brokered credentials. The design and its reasoning are in
`issues/prd-pj-sandbox.md`.

It's built here, beside the current `sandbox/` module and `pj-sbx-*` tools, and
it stays inert until it's promoted to replace them.

## Running it

Until promotion it is run by path, from the dotfiles checkout:

    pj-sandbox/bin/pj-sandbox --help

It's deliberately not on PATH. `zshrc` only puts the top-level `bin/` there.

## Isolation rules

These rules keep the old and new tooling from interfering while both exist:

- **No `install.sh` here.** The root installer sources every module's
  `install.sh`, including inside sandbox guests, so adding one would install
  this tree everywhere. One gets added at promotion.
- **Nothing in top-level `bin/` or `zsh/` refers to `pj-sandbox/`.** That's
  what keeps it off PATH and out of every shell.
- **Never source `sandbox/lib`.** Anything reused from the old module is
  copied in and then changes independently (e.g. `pj_sandbox_instance_name` in
  `lib/namespace.sh`).
- **Separate runtime namespaces**, all defined in `lib/namespace.sh`, so
  neither tool set ever sees the other's VMs, ssh entries, ports or state:

  | What                 | Default                                       | Override                                        |
  |----------------------|-----------------------------------------------|-------------------------------------------------|
  | Lima instance prefix | `pjsb-`                                       | `PJ_SANDBOX_INSTANCE_PREFIX`                    |
  | ssh include file     | `~/.ssh/pj-sandbox-next-config`               | `PJ_SANDBOX_SSH_INCLUDE_FILE`                   |
  | user ssh config      | `~/.ssh/config`                               | `PJ_SANDBOX_SSH_CONFIG_FILE`                    |
  | ssh/forward ports    | `61022`–`61099`                               | `PJ_SANDBOX_PORT_MIN` / `PJ_SANDBOX_PORT_MAX`   |
  | config dir           | `${XDG_CONFIG_HOME:-~/.config}/pj-sandbox`    | `PJ_SANDBOX_CONFIG_DIR`                         |
  | state dir            | `${XDG_STATE_HOME:-~/.local/state}/pj-sandbox`| `PJ_SANDBOX_STATE_DIR`                          |
  | local templates      | `local/pj-sandbox/templates`                  | `PJ_SANDBOX_TEMPLATES_DIR`                      |

  `test/isolation_test.sh` enforces the first three rules.

## Layout

- `bin/pj-sandbox`: the dispatcher. `pj-sandbox <sub>` sources
  `lib/cmd_<sub>.sh` and calls its `cmd_<sub>` function. A planned subcommand
  without a file yet exits 2 with "not implemented yet".
- `lib/`: sourced POSIX sh.
- `test/`: `*_test.sh` files, which `make test` runs. `make lint` also checks
  `bin/`, `lib/` and `test/`.
- `test/live/`: scripts that need a real Mac host with Lima, so they are run
  by hand and never by `make test` (`spike_egress.sh`, the egress spike, and
  `spike_ca.sh`, the CA and pinning spike).
- `lima/template.yaml`: the hardened base config every VM is rendered from
  (`lib/render.sh`). It has `mounts: []`, so no host directory is mounted.
- `lima/core-provision.yaml`: the provision step every VM gets (Docker,
  Node/npm, git-lfs), whatever its agent profiles.
- `templates/`: the built-in `--base` templates (`lib/base_template.sh`).
- `profiles/`: the agent profiles `--agent` picks from (`lib/profiles.sh`).
- `proxy/`: the mitmproxy egress policy (`policy.py`, stdlib only), the log
  reader behind `logs` and `allowlist suggest` (`egress_log.py`), and its
  glue (`addon.py`, the only file that imports mitmproxy). Its unittest
  suite runs through `test/proxy_policy_test.sh`, which skips without
  `python3`.
- `lima/spike/`: throwaway Lima configs, used only by the spike scripts.
- `docs/`: spike write-ups and findings (`spike-egress.md`, `spike-ca.md`).

## State

Each task's record is `<state dir>/<task>/meta`: `key=value` lines (task,
instance, repo, branch, base, agents, ssh_port, ports, created, fetched,
egress_mode, proxy_port, proxy_pid)
written by `lib/state.sh` through a temp file and `mv`, so a reader never sees
a half-written record. This file is the only thing that says a task exists.
Neither ssh include file is ever read to find tasks.

`pj-sandbox list [--json]` shows every recorded task, and
`pj-sandbox status <task> [--json]` shows one. Both merge in live status from
`limactl list --json`, counting only `pjsb-` instances. A recorded VM that Lima
doesn't report shows as `missing`. If `limactl` itself fails, the status shows
as `unknown`. JSON fields are all strings.

## Spawning

`pj-sandbox spawn <task> --base none [--ports 8000,5432] [--egress deny|observe|open]` boots
`pjsb-<slug>` from `lima/template.yaml` with no host mounts. It writes a
`Host pjsb-<slug>` entry to the include file (never to the old
`~/.ssh/pj-sandbox-config`), makes sure `~/.ssh/config` includes that file,
and writes the state record last. The ssh port and every forward's host port
come from the pj-sandbox range (`lib/ports.sh`). They skip ports that other
state records hold and ports that can't be bound right now. Forwards are bound
to `127.0.0.1` and recorded as `ports=<guest>:<host>,...`. A task that already
has a record is refused before `limactl` is called.

`--base` names a template from `templates/` (`none`, `python3.12`,
`python3.14`) or from the local templates dir, which wins a name collision.

### Egress

Every VM gets the network that `docs/spike-egress.md` ("Findings") chose:
`vmType: qemu` plus a NIC on Lima's socket_vmnet `host` network (`lima0`,
192.168.106.0/24), which has no route off the Mac. Once the VM is up, spawn
starts the task's own `mitmdump` (`lib/proxy.sh`) on
`$PJ_SANDBOX_PROXY_HOST` (default `192.168.106.1`, the host's address on that
network; a wildcard address is refused). It listens on a port from the
pj-sandbox range. The proxy loads `proxy/addon.py` with the task's `policy/`
dir and `--egress deny|observe|open` (default `deny`), and the tokens
`lib/tokens.sh` resolves go into its environment. Its log is
`<state dir>/<task>/egress.log`, and mitmdump's own output goes to
`proxy.log` beside it. The record gains `egress_mode`, `proxy_port` and
`proxy_pid`. Any failure after the proxy starts stops it again. Install
socket_vmnet and give Lima's `networks.yaml` the right `group:` first, as
for the spike (MT-4).

The bootstrap's last step points the guest at the proxy. It sets
`HTTP(S)_PROXY`/`NO_PROXY` in `/etc/profile.d/pjsb-proxy.sh` and
`/etc/environment`, sets apt's proxy, and writes `"proxies"` into
`/etc/docker/daemon.json`. Then it enables `pjsb-egress-lockdown.service`,
which deletes `eth0`'s default route at every boot and blackholes Lima's
resolver (192.168.5.3). The guest has no DNS of its own, because the proxy
resolves names. All of that is inside the guest, so root can undo it. That's
the known gap the findings accepted, along with guests sharing one host-only
network.
`pj-sandbox spawn --base list` prints the valid names, and `--help` and an
unknown `--base` show them too. The format is the old sandbox's: a flat file
of Lima `provision:` items, or a directory holding `provision.yaml` and a
`files` manifest of `host_path:guest_path` lines. Each listed host file is
copied into the guest as a `mode: data` item at spawn time, as a snapshot
rather than a mount. A template with a `mounts.yaml` is refused before
`limactl` is called, because pj-sandbox allows no host mounts.
`port_forwards.yaml` isn't supported, so every forward stays on `127.0.0.1`.

## Agent profiles

The core never names an agent. Each one is a directory under `profiles/`
(the defaults are `claude`, `copilot` and `gh`) holding:

- `provision.sh`, run as root at provision time
- `allowlist`, one host pattern per line, optionally followed by methods and
  a path prefix (`#` comments allowed)
- `inject.json`, a JSON array of
  `{host, header, scheme, placeholder, token_source}` rules, where
  `token_source` is a list of host-side sources tried in order (see
  "Credential injection")
- `guest-env`, `KEY=value` lines for the guest, all `pjsb-placeholder-*`
  values
- optionally `post-bootstrap.sh`, run as the guest user after the bootstrap
  (`claude`'s seeds `hasCompletedOnboarding` and
  `bypassPermissionsModeAccepted` into `~/.claude.json`)

`spawn --agent gh,claude` picks profiles; with no `--agent`, every profile is
picked. An unknown name is refused before `limactl` is called, with the valid
names listed. The rendered `provision:` block is `lima/core-provision.yaml`,
then each chosen profile's `provision.sh`, then the `--base` template. The
chosen profiles' allowlists (comments and repeats dropped) and inject rules
(one JSON array) are merged into `<state dir>/<task>/policy/allowlist` and
`policy/inject.json` for the proxy, and the record gains `agents=gh,claude`.
`guest-env` isn't delivered to the guest yet.

Spawn runs inside a git repo, and the task name doubles as the host branch
name, so it has to pass `git check-ref-format --branch`. If the branch already
exists it's used as it is. Otherwise it's created from `--from <ref>`, or from
`refs/sandbox/<task>/<task>` if an earlier sandbox's work was fetched there, or
from `HEAD`. `lib/git_transport.sh` bundles `refs/heads/<task>` into the task's
state dir, `limactl copy` puts it in the guest's `/tmp`, and a script fed to
`limactl shell --workdir / ... sh -s` clones it to `/workspace` on the guest's
own disk, checks out the branch and removes the bundle remote (origin stays
unset). The bundle is deleted on both sides afterwards. Before cloning, the
script sets the guest's global `core.hooksPath` to an empty directory and
`protocol.ext.allow=never`. Since the guest has sudo, these only stop
accidents. No host path from the repo or its git dir is ever handed to the
guest. The record gains `repo=` and `branch=`.

Then `lib/bootstrap.sh` sets up the guest over `ssh -F <include file>`. The
dotfiles are copied in, not mounted: `git -C "$DOTFILES_HOME" archive HEAD` is
streamed over ssh stdin into the guest's `~/dotfiles`, so only tracked files
go and `local/` never does. A second ssh call pipes the bootstrap script into
`sh -s`. It first installs the proxy CA's certificate as
`/usr/local/share/ca-certificates/pjsb.crt` and runs
`update-ca-certificates`. The certificate's text is in the script itself, and
the script builder refuses any file that isn't exactly one PEM certificate,
so the CA key can't ride along. Then it installs zsh if it's missing, runs the dotfiles installer with
`DOTFILES_SANDBOX_GUEST=1`, runs `chsh` to zsh, writes the `/etc/pj-sandbox`
marker that `pj-run-issues` and the `pj-hook-*` guards check, and adds a zsh
handoff to the bash login file. The handoff is guarded by the inherited
`PJSANDBOX_ZSH_HANDED_OFF` marker, so shells that Claude Code's Bash tool
starts from that profile don't hang on `exec zsh -l`. Each chosen profile's
`post-bootstrap.sh` is then piped to `sh -s` in the guest the same way. Neither ssh call puts
a value in argv, and no credential is exported in the guest. If the bootstrap
fails, spawn fails and writes no record.

## Egress policy

`proxy/policy.py` decides each request from the task's `policy/allowlist`.
Each line is `HOST [METHOD,...] [/PATH-PREFIX]`, for example
`api.github.com GET,HEAD /repos/`. HOST is an exact name or a `*.suffix`
pattern. `*.github.com` matches every subdomain, but not `github.com` itself
and not `evilgithub.com`. IP addresses, ports, URLs, `*` and `*.tld` are
rejected, and the error names the file and line number. A path
prefix ignores the query string. A path with a `.` or `..` segment (encoded
or written with a backslash) never matches one.

- `deny` lets through only allowlisted requests. IP-literal destinations are
  always denied.
- `observe` lets everything through and logs what `deny` would refuse as
  `would-deny`.
- `open` lets everything through.

A CONNECT passes if any rule names its host. Method and path are checked on
each request inside the tunnel. Every decision appends one JSON line to
`<state dir>/<task>/egress.log` with `ts`, `task`, `mode`, `host`, `method`,
`path` (without its query string), `decision` (`allow`, `deny` or
`would-deny`) and `rule` (`<file>:<line> <entry>`, `no-match`, `ip-literal`
or `open-mode`).

    mitmdump -s pj-sandbox/proxy/addon.py \
        --set pjsb_policy_dir=<state dir>/<task>/policy --set pjsb_mode=deny

A denied request or CONNECT gets a 403 with a one-line reason. A malformed
allowlist or an unknown mode stops mitmdump from starting, and an error while
deciding denies the request. `spawn` starts one per task (see "Egress"
under "Spawning").

### Reading the log and building an allowlist

    pj-sandbox logs <task> [--denied] [--follow] [--json]
    pj-sandbox allowlist suggest <task> [--write <path>]

`logs` prints the log as a table with time, decision, method, host, path and
rule columns. A row where a token was swapped in also shows
`injected: <profile>`, taken from its `pjsb-placeholder-<profile>`.
`--denied` keeps only `deny` lines, which covers both policy denials and
`placeholder-leak`s. `--follow` keeps printing as lines are appended, and
`--json` prints the matching lines unchanged.

`allowlist suggest` turns a log, usually from an `observe` run, into
allowlist entries. Each host the task contacted is listed once, sorted, with
`# N requests` after it. Hosts the task's `policy/allowlist` already covers
are left out, and so are IP literals and anything else the allowlist parser
would reject. Entries are hostnames only, so narrow them by method or path
by hand. `--write` appends the entries to a file instead of printing them.
On each `spawn` the profiles' allowlists are merged first, then two optional
files, with comments and repeats dropped:

- a directory template's `allowlist` (for example
  `local/pj-sandbox/templates/<name>/allowlist`)
- the repo's `<git common dir>/pj-sandbox/allowlist`. It sits in the host's
  git dir, which is never bundled, so the guest can't commit one to widen
  its own next policy.

## Credential injection

The guest only ever holds placeholders (`pjsb-placeholder-gh` and so on).
Once policy allows a request, `proxy/inject.py` applies `policy/inject.json`:

- For a request over HTTPS to a rule's host whose rule header carries the
  rule's placeholder, the placeholder is swapped for the real token. A
  `bearer` rule wants `Bearer <placeholder>`. A `basic` rule wants the
  placeholder anywhere inside `Basic base64(user:password)`, which is how
  git's credential helper sends it.
- A placeholder anywhere else in a request to a host with no rule for that
  placeholder is denied with a 403 and logged with rule `placeholder-leak`.
  That covers any header name or value (basic auth decoded), the path and
  the query string (raw and percent-decoded).
- A request with no placeholder in it passes unchanged and isn't logged
  again.

An injection or a leak appends a line to `egress.log` in the policy format,
plus `placeholder`. An injection also gets `token_sha256`, the first 4 hex
characters of the token's sha256, so you can tell which token was used
without the log ever holding one. A rule whose token couldn't be resolved
logs `no-token`, and the placeholder is sent as-is, so the upstream answers
401.

`lib/tokens.sh` resolves the tokens on the host. Each `token_source` entry is
tried in order and the first that yields a non-empty token wins:

- `keychain:SERVICE/ACCOUNT` runs `security find-generic-password -s SERVICE -a ACCOUNT -w`.
  The shipped profiles look under service `pj-sandbox` first, with the
  profile name as the account.
- `cmd:COMMAND` uses `sh -c COMMAND`'s output.
- `file:PATH` reads the file, with a leading `~/` meaning `$HOME`.

If nothing works, you get a warning and an empty token, not a failure.
`pj_sandbox_tokens_exec POLICY_DIR CMD...` resolves every placeholder once,
exports each token as `PJSB_TOKEN_<PLACEHOLDER>` in a subshell, and execs
the proxy there. So the tokens live only in the proxy's environment. They
never touch the caller's environment, a command line, the state or policy
dir, or the guest.

### The proxy CA

`lib/ca.sh` makes the per-install CA the first time `spawn` needs it, under
`<config dir>/ca/`: `ca.pem` (the certificate, the only file a guest ever
gets), `ca-key.pem` (mode 600) and `mitmproxy-ca.pem` (key then certificate,
mode 600), the file `mitmdump --set confdir=<config dir>/ca` loads instead of
making its own CA. After that it's reused. A CA missing any of the three files
is replaced whole. The dir is mode 700.

Each profile's `guest-env` points its tools at it: `NODE_EXTRA_CA_CERTS` at
`pjsb.crt` for the Node agents (claude, copilot), and `SSL_CERT_FILE` and
`GIT_SSL_CAINFO` at the rebuilt system bundle for gh and git.

The CA spike (`docs/spike-ca.md`) found that all of them can be brokered, so
no profile is unbrokered. `profiles_test.sh` checks the profiles against that
doc's Results table: marking an agent unbrokered there fails the suite until
its profile has an `unbrokered` file and the fallback is built.

## Fetching

`pj-sandbox fetch <task>` brings the guest's commits back without trusting
anything the guest serves. From the recorded host repo it runs
`git -c core.hooksPath=/dev/null -c core.fsmonitor=false -c protocol.ext.allow=never fetch pjsb-<slug>:/workspace '+refs/heads/*:refs/sandbox/<task>/*'`
over the instance's ssh Host entry (`lib/git_transport.sh`). So the guest's
branches only land under `refs/sandbox/<task>/*`: `refs/heads/*` is never
moved, nothing is checked out, and no command runs in a guest-controlled
directory. It then prints the fetched refs and
`git log --oneline <branch>..refs/sandbox/<task>/<branch>` for review, and
records the time as `fetched=` in the state record
(`pj_sandbox_state_update`, which keeps every other field). Merging the work
is left to the user.

## Driving a VM

`pj-sandbox attach <task>` opens a login shell in the guest's `/workspace`
with `ssh -t pjsb-<slug>`. `pj-sandbox exec <task> -- <cmd> [args...]` runs
one command there without a tty and exits with its status.
`pj-sandbox run <task> [--test-cmd <cmd>] [loop args...]` runs `pj-run-issues`
there over `ssh -t`, like `bin/pj-sbx-run`, and exits with the loop's status.
ssh joins its command into one string for the guest shell to re-split
(commit a3e036d), so every argument goes through `pj_sandbox_shell_quote`
(`lib/remote.sh`) first. Spaces, quotes, `$`, empty strings and newlines all
arrive unchanged. All three refuse a task with no state record, or one whose
VM Lima doesn't report as `Running`, before calling ssh.

## Tearing down

`pj-sandbox rm <task> [--fetch]` removes one task. With `--fetch` it runs
`fetch` first and stops if the fetch fails. It then stops the task's proxy
(only the recorded PID, and only while that is still the task's mitmdump),
runs `limactl delete --force pjsb-<slug>`
if Lima still has the VM, drops that one Host block from
`~/.ssh/pj-sandbox-next-config`, and deletes the task's state dir. The host
branch and `refs/sandbox/<task>/*` are kept. It refuses a record whose
instance lacks the `pjsb-` prefix, and does nothing if `limactl list` fails.

`pj-sandbox gc [--dry-run]` cleans up after crashes. It deletes `pjsb-*` VMs
that no record names. It deletes records whose VM is gone once their `meta`
is older than `PJ_SANDBOX_GC_GRACE_MINUTES` (default 60), stopping each
one's proxy first. It removes `pjsb-`
Host entries that no remaining record names. It works from one
`limactl list --json` call and refuses to run without it, and it never sees
instances outside the `pjsb-` prefix. `--dry-run` prints the
`would delete ...` lines and changes nothing. Neither command touches the
old `~/.ssh/pj-sandbox-config`.
