# render.sh
#
# Renders lima/template.yaml into one task's Lima config. Ported from
# sandbox_render_lima_config and sandbox_port_forwards_yaml in
# sandbox/lib/task.sh, minus every mount placeholder: a pj-sandbox VM has no
# host mounts to fill in. Meant to be sourced, not executed.

# pj_sandbox_port_forwards_yaml MAPPINGS
#
# MAPPINGS is one "guestPort:hostPort" pair per line (pj_sandbox_allocate_ports'
# output), or empty. Prints a top-level portForwards: block with one item per
# pair, each bound to 127.0.0.1 so a forwarded service is never reachable from
# the LAN. Prints nothing for empty MAPPINGS, so no portForwards key is
# rendered at all.
pj_sandbox_port_forwards_yaml() {
	[ -n "$1" ] || return 0

	echo "portForwards:"
	printf '%s\n' "$1" | while IFS=':' read -r guest_port host_port; do
		[ -n "$guest_port" ] || continue
		printf -- '- guestPort: %s\n  hostPort: %s\n  hostIP: 127.0.0.1\n' "$guest_port" "$host_port"
	done
}

# pj_sandbox_render_lima_config TEMPLATE SSH_PORT [MAPPINGS] [PROVISION_FILE]
#
# Prints TEMPLATE with SSH_PORT substituted and MAPPINGS' portForwards: block
# (see above) in place of the __PJ_SANDBOX_PORT_FORWARDS__ line, or that line
# simply dropped when there are none. PROVISION_FILE holds raw provision list
# items (a base template's fragment plus its copied-in files); when non-empty
# it's rendered as a top-level provision: block in place of the
# __PJ_SANDBOX_BASE_PROVISION__ line, which is otherwise dropped.
pj_sandbox_render_lima_config() {
	template="$1"
	ssh_port="$2"
	mappings="${3:-}"
	provision_file="${4:-}"

	forwards="$(mktemp)" || return 1
	pj_sandbox_port_forwards_yaml "$mappings" > "$forwards"
	provision="$(mktemp)" || {
		rm -f "$forwards"
		return 1
	}
	if [ -n "$provision_file" ] && [ -s "$provision_file" ]; then
		{ echo "provision:" && cat "$provision_file"; } > "$provision"
	fi

	sed -e "s|__PJ_SANDBOX_SSH_PORT__|$ssh_port|" \
		-e "/^__PJ_SANDBOX_PORT_FORWARDS__\$/r $forwards" \
		-e "/^__PJ_SANDBOX_PORT_FORWARDS__\$/d" \
		-e "/^__PJ_SANDBOX_BASE_PROVISION__\$/r $provision" \
		-e "/^__PJ_SANDBOX_BASE_PROVISION__\$/d" \
		"$template"
	rc=$?

	rm -f "$forwards" "$provision"
	return "$rc"
}
