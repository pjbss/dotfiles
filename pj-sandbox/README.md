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
