# task.sh
#
# Pure(-ish) task-name -> resource-name logic for the sandbox module: a
# deterministic, Lima-valid instance name derived from a free-text task
# name, and SSH port allocation across concurrently-running Lima
# instances. Meant to be sourced, not executed directly.
#
# sandbox_instance_name TASK_NAME
#
# Lima instance names must match ^[A-Za-z0-9]+(?:[._-][A-Za-z0-9]+)*$
# (confirmed against a real `limactl create` rejection). Lowercases the
# task name, replaces runs of invalid characters with a single '-', and
# trims leading/trailing separators.
sandbox_instance_name() {
	task_name="$1"

	slug="$(echo "$task_name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"

	if [ -z "$slug" ]; then
		slug="sandbox-task"
	fi

	echo "$slug"
}

# Defined range for dynamically-allocated sandbox SSH ports (PRD: "tooling
# must allocate SSH ports ... dynamically ... rather than hardcoding a
# single port"). Read at call time (not captured into a readonly) so tests
# can override the range after sourcing this file.
SANDBOX_SSH_PORT_MIN="${SANDBOX_SSH_PORT_MIN:-60022}"
SANDBOX_SSH_PORT_MAX="${SANDBOX_SSH_PORT_MAX:-60099}"

# Ceiling for sandbox_allocate_ports' upward scan from each requested guest
# port (see below) -- the highest valid TCP port number. Read at call time
# for the same reason as the SSH range above.
SANDBOX_FORWARD_PORT_SCAN_MAX="${SANDBOX_FORWARD_PORT_SCAN_MAX:-65535}"

# sandbox_used_host_ports
#
# Prints every host port currently claimed by a running Lima instance, one
# per line: each instance's `sshLocalPort` plus every explicit port
# forward's `hostPort` -- `limactl list --json`'s per-instance
# `config.portForwards[].hostPort` (confirmed against Lima's
# limatype.Instance/PortForward struct definitions, which `store.Inspect`
# populates for every instance `limactl list --json` reports, not just a
# `--all-fields`-gated subset). Grep-based rather than real JSON parsing,
# matching the pre-existing style below: both keys are unique enough in
# this output not to collide with unrelated JSON elsewhere in the stream,
# regardless of nesting.
sandbox_used_host_ports() {
	# `|| true`: under `set -e`, a caller invoking this from /bin/sh (bash
	# 3.2 in POSIX mode) treats a no-match grep in this assignment's
	# pipeline as a fatal error, aborting before the search loop below even
	# runs -- confirmed by reproducing it directly (a plain interactive
	# bash shell does not have this failure mode, only posix-mode sh).
	limactl list --json 2>/dev/null | grep -Eo '"(sshLocalPort|hostPort)":[0-9]+' | grep -Eo '[0-9]+$' || true
}

# sandbox_host_port_free PORT
#
# True (exit 0) if PORT is actually free to bind on the host right now,
# false otherwise. A real OS-level probe -- binds a TCP socket to
# 127.0.0.1:PORT and immediately closes it -- rather than just consulting
# sandbox_used_host_ports, since sandbox_allocate_ports (below) now starts
# its scan at the caller's own requested guest port, which is just as
# likely to already be claimed by some unrelated host process (e.g. a
# locally running Postgres on 5432) as by another sandbox. A separate
# function (rather than inlined) so tests can shadow it the same way they
# already shadow `limactl`.
sandbox_host_port_free() {
	port="$1"
	python3 -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    s.bind(('127.0.0.1', $port))
except OSError:
    raise SystemExit(1)
finally:
    s.close()
" 2>/dev/null
}

# sandbox_allocate_port
#
# Prints the first free SSH port in [$SANDBOX_SSH_PORT_MIN,
# $SANDBOX_SSH_PORT_MAX] not already claimed by a running Lima instance
# (sandbox_used_host_ports). Errors if the range is exhausted.
sandbox_allocate_port() {
	used_ports="$(sandbox_used_host_ports)"

	port="$SANDBOX_SSH_PORT_MIN"
	while [ "$port" -le "$SANDBOX_SSH_PORT_MAX" ]; do
		if ! echo "$used_ports" | grep -qx "$port"; then
			echo "$port"
			return 0
		fi
		port=$((port + 1))
	done

	echo "sandbox_allocate_port: no free port in range $SANDBOX_SSH_PORT_MIN-$SANDBOX_SSH_PORT_MAX" >&2
	return 1
}

# sandbox_allocate_ports GUEST_PORTS [EXTRA_RESERVED_PORTS]
#
# GUEST_PORTS is a comma-separated list of guest ports (the `--ports`
# flag's raw value, e.g. "8000,5432"). Prints one "guestPort:hostPort" pair
# per line: for each guest port, the host port is that same port number if
# it's free, otherwise the first free port found by scanning upward from it
# (up to $SANDBOX_FORWARD_PORT_SCAN_MAX) -- so a guest port is reachable at
# the identical host port whenever possible, matching what a user passing
# e.g. `--ports 5001` expects to find at localhost:5001. "Free" means both
# not claimed by a running Lima instance (sandbox_used_host_ports) *and*
# actually bindable on the host right now (sandbox_host_port_free) -- the
# latter because, unlike the old fixed dynamic range, a guest port's own
# number is just as likely to already be in use by some unrelated host
# process. EXTRA_RESERVED_PORTS is an optional space/newline-separated list
# of additional ports to treat as claimed -- e.g. the SSH port this same
# spawn just allocated via sandbox_allocate_port, which won't show up in
# sandbox_used_host_ports until the VM it belongs to is actually up. Also
# skips any port this same call already handed out to an earlier guest port
# in the list, so two guest ports in one spawn never collide with each
# other either. Because the used-port snapshot comes from currently-running
# instances, two sandboxes requesting the same guest port never collide as
# long as each spawn's own VM is up (and thus visible to `limactl list`)
# before the next spawn allocates -- the same assumption sandbox_allocate_port
# already relies on for SSH ports. Errors if the scan reaches
# $SANDBOX_FORWARD_PORT_SCAN_MAX before a guest port is assigned a host port.
sandbox_allocate_ports() {
	guest_ports_csv="$1"
	extra_reserved="${2:-}"

	used_ports="$(sandbox_used_host_ports)"
	[ -n "$extra_reserved" ] && used_ports="$(printf '%s\n%s' "$used_ports" "$extra_reserved")"

	old_ifs="$IFS"
	IFS=','
	set -- $guest_ports_csv
	IFS="$old_ifs"

	for guest_port in "$@"; do
		[ -z "$guest_port" ] && continue

		port="$guest_port"
		host_port=""
		while [ "$port" -le "$SANDBOX_FORWARD_PORT_SCAN_MAX" ]; do
			if ! echo "$used_ports" | grep -qx "$port" && sandbox_host_port_free "$port"; then
				host_port="$port"
				break
			fi
			port=$((port + 1))
		done

		if [ -z "$host_port" ]; then
			echo "sandbox_allocate_ports: no free port at or above $guest_port (scanned up to $SANDBOX_FORWARD_PORT_SCAN_MAX)" >&2
			return 1
		fi

		echo "$guest_port:$host_port"
		used_ports="$(printf '%s\n%s' "$used_ports" "$host_port")"
	done
}

# sandbox_port_forwards_yaml MAPPINGS [TEMPLATE_FRAGMENT]
#
# MAPPINGS is sandbox_allocate_ports' own output (one "guestPort:hostPort"
# pair per line, or empty). TEMPLATE_FRAGMENT (issue 013) is an optional
# raw Lima portForwards-list fragment path -- a directory-shaped --base
# template's port_forwards.yaml (sandbox_base_template_port_forwards_path,
# base_template.sh), most commonly an `ignore: true` rule suppressing
# Lima's own built-in "forward every guest port on 127.0.0.1" catch-all
# for a port the template's own service already listens on (e.g. redis;
# see lima-vm/lima#2901) -- unrelated to `--ports`' dynamic mappings, but
# spliced into the exact same `portForwards:` list, since YAML can't merge
# two top-level keys of the same name.
#
# Prints a top-level `portForwards:` YAML block (one list item per
# mapping, then TEMPLATE_FRAGMENT's raw content appended verbatim) for
# splicing into a rendered Lima config at the `__SANDBOX_PORT_FORWARDS__`
# placeholder (see sandbox_render_lima_config). Prints nothing when both
# MAPPINGS and TEMPLATE_FRAGMENT are empty/absent, so omitting `--ports`
# with no template contribution either still renders no `portForwards` key
# at all -- unchanged, SSH-only forwarding.
sandbox_port_forwards_yaml() {
	mappings="$1"
	template_fragment="${2:-}"

	has_fragment=false
	if [ -n "$template_fragment" ] && [ -s "$template_fragment" ]; then
		has_fragment=true
	fi

	if [ -z "$mappings" ] && ! $has_fragment; then
		return 0
	fi

	echo "portForwards:"

	if [ -n "$mappings" ]; then
		echo "$mappings" | while IFS=':' read -r guest_port host_port; do
			[ -z "$guest_port" ] && continue
			printf -- '- guestPort: %s\n  hostPort: %s\n' "$guest_port" "$host_port"
		done
	fi

	if $has_fragment; then
		cat "$template_fragment"
	fi
}

# sandbox_render_lima_config TEMPLATE SSH_PORT WORKTREE_PATH [AWS_PROFILE] [DOTFILES_PATH] [REPO_GITDIR] [BASE_TEMPLATE] [PORT_FORWARD_MAPPINGS] [BASE_MOUNTS]
#
# Renders a per-task Lima YAML config to stdout: substitutes the SSH port,
# worktree path, this dotfiles repo's own path, and the spawning repo's
# real git directory placeholders in TEMPLATE, splices BASE_TEMPLATE's
# provisioning in at the `__SANDBOX_BASE_PROVISION__` placeholder (see
# below), BASE_MOUNTS' raw mounts-list fragment in at the
# `__SANDBOX_BASE_MOUNTS__` placeholder (see further below), and
# PORT_FORWARD_MAPPINGS' rendered YAML in at the
# `__SANDBOX_PORT_FORWARDS__` placeholder (see further below), then appends
# a guest `env: AWS_PROFILE: ...` passthrough stanza -- but only when
# AWS_PROFILE is non-empty. Lima has no native passthrough of arbitrary
# host env vars (only a few proxy vars), so this bakes the host's current
# value in at render time. Omitting the stanza when empty matters: an empty
# guest AWS_PROFILE makes the AWS CLI look for a profile literally named ""
# instead of falling back to its default profile.
#
# REPO_GITDIR must be the spawning repo's real (common) git directory --
# `git -C REPO_ROOT rev-parse --git-common-dir`, resolved to an absolute
# path -- not REPO_ROOT itself. A linked worktree's `.git` is a *file*
# containing `gitdir: <absolute-host-path>/.git/worktrees/<name>`, and
# every git operation inside the worktree needs that exact absolute path
# to resolve (confirmed directly: git inside a spawned VM failed outright
# without this, since /workspace alone can't satisfy that reference --
# see the mount this substitutes into in lima-template.yaml).
#
# BASE_TEMPLATE is the file resolved by sandbox_base_template_path for the
# spawn's `--base <name>` value (base_template.sh): a `provision:` list
# item (e.g. `- mode: system` / `script: |` ...) inserted right where
# TEMPLATE's own `__SANDBOX_BASE_PROVISION__` placeholder line sits, via
# sed's `r`/`d` idiom, so the two provision stanzas concatenate into one
# valid YAML list rather than needing a second top-level `provision:` key
# (which YAML can't merge with the first). `--base none` resolves to an
# empty file, so this cleanly removes the placeholder line with nothing
# inserted -- exactly today's bare-VM provisioning. When BASE_TEMPLATE is
# omitted entirely (existing callers/tests predating issue 003), the
# placeholder is likewise just deleted, since `sed -e '/pat/r ""'`'s
# empty-filename behavior differs across sed implementations (confirmed:
# BSD sed on this Mac errors on it) and isn't worth relying on.
#
# BASE_MOUNTS (issue 010) is the raw mounts-list fragment resolved by
# sandbox_base_template_mounts_path for a directory-shaped `--base`
# template: one or more `- location: ...` / `mountPoint: ...` /
# `writable: ...` list items, inserted at TEMPLATE's own
# `__SANDBOX_BASE_MOUNTS__` placeholder line the same `r`/`d` way
# BASE_TEMPLATE is, so they become additional entries in the same
# `mounts:` list already in TEMPLATE rather than a second, YAML-illegal
# `mounts:` key. Empty/omitted (a flat-file template, or a directory
# template with no `mounts.yaml`) just deletes the placeholder with
# nothing inserted.
#
# BASE_PORT_FORWARDS (issue 013) is the raw portForwards-list fragment
# resolved by sandbox_base_template_port_forwards_path for a
# directory-shaped `--base` template -- combined with
# PORT_FORWARD_MAPPINGS by sandbox_port_forwards_yaml into the one
# `portForwards:` block spliced at `__SANDBOX_PORT_FORWARDS__` below, so a
# template can contribute rules (typically an `ignore: true` for a port
# its own service listens on) independently of whether `--ports` was ever
# passed.
sandbox_render_lima_config() {
	template="$1"
	ssh_port="$2"
	worktree_path="$3"
	aws_profile="${4:-}"
	dotfiles_path="${5:-}"
	repo_gitdir="${6:-}"
	base_template="${7:-}"
	port_forward_mappings="${8:-}"
	base_mounts="${9:-}"
	base_port_forwards="${10:-}"

	port_forwards_file="$(mktemp)"
	sandbox_port_forwards_yaml "$port_forward_mappings" "$base_port_forwards" > "$port_forwards_file"

	sed \
		-e "s|__SANDBOX_SSH_PORT__|$ssh_port|" \
		-e "s|__SANDBOX_WORKTREE_PATH__|$worktree_path|" \
		-e "s|__SANDBOX_DOTFILES_PATH__|$dotfiles_path|" \
		-e "s|__SANDBOX_REPO_GITDIR__|$repo_gitdir|" \
		"$template" | {
			if [ -n "$base_template" ]; then
				sed -e "/^__SANDBOX_BASE_PROVISION__\$/r $base_template" -e "/^__SANDBOX_BASE_PROVISION__\$/d"
			else
				sed -e "/^__SANDBOX_BASE_PROVISION__\$/d"
			fi
		} | {
			if [ -n "$base_mounts" ]; then
				sed -e "/^__SANDBOX_BASE_MOUNTS__\$/r $base_mounts" -e "/^__SANDBOX_BASE_MOUNTS__\$/d"
			else
				sed -e "/^__SANDBOX_BASE_MOUNTS__\$/d"
			fi
		} | {
			if [ -s "$port_forwards_file" ]; then
				sed -e "/^__SANDBOX_PORT_FORWARDS__\$/r $port_forwards_file" -e "/^__SANDBOX_PORT_FORWARDS__\$/d"
			else
				sed -e "/^__SANDBOX_PORT_FORWARDS__\$/d"
			fi
		}

	rm -f "$port_forwards_file"

	if [ -n "$aws_profile" ]; then
		printf 'env:\n  AWS_PROFILE: "%s"\n' "$aws_profile"
	fi
}
