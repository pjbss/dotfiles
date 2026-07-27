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

# sandbox_allocate_port
#
# Prints the first free SSH port in [$SANDBOX_SSH_PORT_MIN,
# $SANDBOX_SSH_PORT_MAX] not already claimed by a running Lima instance,
# per `limactl list --json`'s per-instance `sshLocalPort` field (confirmed
# against a real Lima instance's JSON output). Errors if the range is
# exhausted.
sandbox_allocate_port() {
	# `|| true`: under `set -e`, a caller invoking this from /bin/sh (bash
	# 3.2 in POSIX mode) treats a no-match grep in this assignment's
	# pipeline as a fatal error, aborting before the search loop below even
	# runs -- confirmed by reproducing it directly (a plain interactive
	# bash shell does not have this failure mode, only posix-mode sh).
	used_ports="$(limactl list --json 2>/dev/null | grep -Eo '"sshLocalPort":[0-9]+' | grep -Eo '[0-9]+$' || true)"

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

# sandbox_render_lima_config TEMPLATE SSH_PORT WORKTREE_PATH [AWS_PROFILE] [DOTFILES_PATH]
#
# Renders a per-task Lima YAML config to stdout: substitutes the SSH port,
# worktree path, and this dotfiles repo's own path placeholders in
# TEMPLATE, then appends a guest `env: AWS_PROFILE: ...` passthrough
# stanza -- but only when AWS_PROFILE is non-empty. Lima has no native
# passthrough of arbitrary host env vars (only a few proxy vars), so this
# bakes the host's current value in at render time. Omitting the stanza
# when empty matters: an empty guest AWS_PROFILE makes the AWS CLI look
# for a profile literally named "" instead of falling back to its default
# profile.
sandbox_render_lima_config() {
	template="$1"
	ssh_port="$2"
	worktree_path="$3"
	aws_profile="${4:-}"
	dotfiles_path="${5:-}"

	sed \
		-e "s|__SANDBOX_SSH_PORT__|$ssh_port|" \
		-e "s|__SANDBOX_WORKTREE_PATH__|$worktree_path|" \
		-e "s|__SANDBOX_DOTFILES_PATH__|$dotfiles_path|" \
		"$template"

	if [ -n "$aws_profile" ]; then
		printf 'env:\n  AWS_PROFILE: "%s"\n' "$aws_profile"
	fi
}
