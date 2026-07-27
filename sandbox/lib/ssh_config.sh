# ssh_config.sh
#
# VS Code Remote-SSH config generation for `pj-sandbox-spawn`
# (issue 005): renders a friendly `Host <task-name>` alias from the
# per-instance ssh.config Lima itself already writes at `limactl start`
# time, and maintains a dotfiles-managed include file so `~/.ssh/config`
# itself is never hand-edited. Meant to be sourced, not executed directly.

# sandbox_ssh_render_host_block INSTANCE LIMA_SSH_CONFIG_FILE
#
# Prints an ssh_config Host block using INSTANCE as the Host alias (so
# `ssh <task-name>` works, matching the task name used everywhere else --
# issue 002/003), reusing every option line from Lima's own
# LIMA_SSH_CONFIG_FILE verbatim (StrictHostKeyChecking, ControlMaster,
# etc. -- confirmed against Lima's pkg/hostagent/hostagent.go and
# pkg/sshutil/format.go: it always writes a few comment lines, then
# exactly one `Host lima-<instance>` line, then indented option lines).
# Copying those lines instead of reimplementing them means this stays
# correct across Lima versions without duplicating its SSH-safety
# decisions for ephemeral localhost VMs.
sandbox_ssh_render_host_block() {
	instance="$1"
	lima_ssh_config="$2"

	{
		printf 'Host %s\n' "$instance"
		sed -n '/^Host /,$p' "$lima_ssh_config" | tail -n +2
	}
}

# _sandbox_ssh_without_host_block FILE INSTANCE
#
# Prints FILE's content with the "Host INSTANCE" stanza (the lines from
# that Host line up to the next blank line/EOF) removed, leaving every
# other stanza untouched. Prints nothing if FILE doesn't exist. Internal
# helper shared by sandbox_ssh_write_entry and sandbox_ssh_remove_entry.
_sandbox_ssh_without_host_block() {
	file="$1"
	instance="$2"

	[ -f "$file" ] || return 0

	awk -v host="Host $instance" '
		BEGIN { skip = 0 }
		$0 == host { skip = 1; next }
		skip && NF == 0 { skip = 0; next }
		skip { next }
		{ print }
	' "$file"
}

# sandbox_ssh_write_entry INCLUDE_FILE INSTANCE BLOCK
#
# Idempotently writes BLOCK (as produced by sandbox_ssh_render_host_block)
# into INCLUDE_FILE, replacing any existing "Host INSTANCE" stanza so
# re-spawning the same task name updates its entry in place, while every
# other task's stanza is left untouched -- the "doesn't clobber the first"
# acceptance criterion. Creates INCLUDE_FILE (and its parent dir) if it
# doesn't exist yet.
sandbox_ssh_write_entry() {
	include_file="$1"
	instance="$2"
	new_block="$3"

	existing="$(_sandbox_ssh_without_host_block "$include_file" "$instance")"

	mkdir -p "$(dirname "$include_file")"

	tmp="$(mktemp)"
	if [ -n "$existing" ]; then
		printf '%s\n\n' "$existing" > "$tmp"
	fi
	printf '%s\n' "$new_block" >> "$tmp"
	mv "$tmp" "$include_file"
	chmod 600 "$include_file"
}

# sandbox_ssh_remove_entry INCLUDE_FILE INSTANCE
#
# Removes the "Host INSTANCE" stanza from INCLUDE_FILE (issue 007's
# teardown, undoing what sandbox_ssh_write_entry added at spawn time),
# leaving every other task's stanza untouched. No-op if INCLUDE_FILE
# doesn't exist or has no such stanza -- teardown must not fail just
# because the ssh entry was already gone.
sandbox_ssh_remove_entry() {
	include_file="$1"
	instance="$2"

	[ -f "$include_file" ] || return 0

	remaining="$(_sandbox_ssh_without_host_block "$include_file" "$instance")"

	tmp="$(mktemp)"
	if [ -n "$remaining" ]; then
		printf '%s\n' "$remaining" > "$tmp"
	fi
	mv "$tmp" "$include_file"
	chmod 600 "$include_file"
}

# sandbox_ssh_ensure_include INCLUDE_FILE SSH_CONFIG_FILE
#
# Idempotently prepends "Include INCLUDE_FILE" as the very first line of
# SSH_CONFIG_FILE (ssh_config's Include directive only takes effect for
# Host blocks that come after it, so it must lead the file rather than
# trail it) unless that exact line is already present, in which case
# nothing is changed. All pre-existing content in SSH_CONFIG_FILE --
# anything hand-written by the user -- is preserved below it. Creates
# SSH_CONFIG_FILE (and ~/.ssh, mode 700) if it doesn't exist yet.
sandbox_ssh_ensure_include() {
	include_file="$1"
	ssh_config_file="$2"

	include_line="Include $include_file"

	if [ -f "$ssh_config_file" ] && grep -qxF "$include_line" "$ssh_config_file"; then
		return 0
	fi

	mkdir -p -m 700 "$(dirname "$ssh_config_file")"

	tmp="$(mktemp)"
	printf '%s\n\n' "$include_line" > "$tmp"
	[ -f "$ssh_config_file" ] && cat "$ssh_config_file" >> "$tmp"
	mv "$tmp" "$ssh_config_file"
	chmod 600 "$ssh_config_file"
}
