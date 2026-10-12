# ssh_config.sh
#
# The ssh Host entry for each task, kept in PJ_SANDBOX_SSH_INCLUDE_FILE and
# pulled into the user's ssh config with one Include line, so ~/.ssh/config
# itself is never otherwise edited. Copied from sandbox/lib/ssh_config.sh
# rather than sourced, so the two can change independently. Meant to be
# sourced, not executed.

# pj_sandbox_ssh_render_host_block INSTANCE LIMA_SSH_CONFIG_FILE
#
# Prints a "Host INSTANCE" block reusing every option line of Lima's own
# per-instance ssh.config, which is a few comment lines, one
# "Host lima-<instance>" line, then indented options. Copying Lima's options
# keeps this right across Lima versions without second-guessing them.
pj_sandbox_ssh_render_host_block() {
	printf 'Host %s\n' "$1"
	sed -n '/^Host /,$p' "$2" | tail -n +2
}

# _pj_sandbox_ssh_without_host_block FILE INSTANCE
#
# Prints FILE minus its "Host INSTANCE" stanza (that line up to the next blank
# line or EOF). Prints nothing if FILE doesn't exist.
_pj_sandbox_ssh_without_host_block() {
	[ -f "$1" ] || return 0

	awk -v host="Host $2" '
		$0 == host { skip = 1; next }
		skip && NF == 0 { skip = 0; next }
		skip { next }
		{ print }
	' "$1"
}

# pj_sandbox_ssh_write_entry INCLUDE_FILE INSTANCE BLOCK
#
# Writes BLOCK into INCLUDE_FILE, replacing any existing "Host INSTANCE"
# stanza and leaving every other one alone. Creates the file if needed.
pj_sandbox_ssh_write_entry() {
	existing="$(_pj_sandbox_ssh_without_host_block "$1" "$2")"

	mkdir -p -m 700 "$(dirname "$1")" || return 1

	tmp="$(mktemp "$1.XXXXXX")" || return 1
	{
		[ -z "$existing" ] || printf '%s\n\n' "$existing"
		printf '%s\n' "$3"
	} > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$1" || {
		rm -f "$tmp"
		return 1
	}
}

# pj_sandbox_ssh_ensure_include INCLUDE_FILE SSH_CONFIG_FILE
#
# Puts "Include INCLUDE_FILE" as the first line of SSH_CONFIG_FILE unless that
# exact line is already there. It has to lead the file: an Include only
# applies to Host blocks after it. Everything already in the file is kept
# below it. Creates the file (and its dir, mode 700) if needed.
pj_sandbox_ssh_ensure_include() {
	include_line="Include $1"

	if [ -f "$2" ] && grep -qxF "$include_line" "$2"; then
		return 0
	fi

	mkdir -p -m 700 "$(dirname "$2")" || return 1

	tmp="$(mktemp "$2.XXXXXX")" || return 1
	{
		printf '%s\n\n' "$include_line"
		[ ! -f "$2" ] || cat "$2"
	} > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$2" || {
		rm -f "$tmp"
		return 1
	}
}

# pj_sandbox_ssh_remove_entry INCLUDE_FILE INSTANCE
#
# Removes INCLUDE_FILE's "Host INSTANCE" stanza, leaving every other one
# alone. Nothing to do if the file or the stanza doesn't exist.
pj_sandbox_ssh_remove_entry() {
	[ -f "$1" ] || return 0
	grep -qxF "Host $2" "$1" || return 0

	_pjsr_kept="$(_pj_sandbox_ssh_without_host_block "$1" "$2")"
	_pjsr_tmp="$(mktemp "$1.XXXXXX")" || return 1
	{
		[ -z "$_pjsr_kept" ] || printf '%s\n' "$_pjsr_kept"
	} > "$_pjsr_tmp" && chmod 600 "$_pjsr_tmp" && mv -f "$_pjsr_tmp" "$1" || {
		rm -f "$_pjsr_tmp"
		return 1
	}
}

# pj_sandbox_ssh_hosts INCLUDE_FILE
#
# Prints the name on every "Host NAME" line of INCLUDE_FILE, one per line.
pj_sandbox_ssh_hosts() {
	[ -f "$1" ] || return 0
	sed -n 's/^Host //p' "$1"
}
