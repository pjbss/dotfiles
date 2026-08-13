# base_template.sh
#
# `--base <name>` resolution for `pj-sbx-spawn` (issue 003): each valid
# name is a file under sandbox/templates/, so adding a new one is a
# one-file change with no lookup table to keep in sync. Extended by issue
# 009 to also search a second, gitignored `local/sandbox/templates/`
# directory (see the PRD at issues/prd-local-templates.md), mirroring the
# existing `local/skills/` + `agents/skills/` merge convention: a name
# present in both directories resolves to the local one. Extended by issue
# 010 so a name may resolve to a directory instead of a flat file, for
# templates needing more than a provisioning script (see
# sandbox_base_template_provision_path/sandbox_base_template_mounts_path
# below). Meant to be sourced, not executed directly.

# sandbox_base_template_path CHECKED_IN_DIR LOCAL_DIR NAME
#
# Prints the resolved template path for NAME (a file, today's shape, or a
# directory, issue 010's shape) and returns 0 if it exists, meaning NAME is
# a valid `--base` value. LOCAL_DIR is checked first, so a NAME present in
# both directories resolves to LOCAL_DIR's entry ("local wins on a name
# collision"). Neither directory needs to exist -- a missing LOCAL_DIR (the
# common case: no local overrides configured) is silently treated as
# contributing no names, not an error. Prints nothing and returns 1 if NAME
# isn't found in either directory -- this also covers a comma-separated/
# multi-value NAME (e.g. "python3.12,node20"), since no template file or
# directory is ever named that: exactly one template applies per sandbox,
# by construction rather than extra parsing.
sandbox_base_template_path() {
	checked_in_dir="$1"
	local_dir="$2"
	name="$3"

	local_candidate="$local_dir/$name"
	if [ -e "$local_candidate" ]; then
		echo "$local_candidate"
		return 0
	fi

	checked_in_candidate="$checked_in_dir/$name"
	if [ -e "$checked_in_candidate" ]; then
		echo "$checked_in_candidate"
		return 0
	fi

	return 1
}

# sandbox_base_template_provision_path TEMPLATE_PATH
#
# Given a path already resolved by sandbox_base_template_path, prints the
# provisioning-script fragment to splice at lima-template.yaml's
# `__SANDBOX_BASE_PROVISION__` placeholder. If TEMPLATE_PATH is a plain
# file (today's flat-file template shape), prints TEMPLATE_PATH itself
# unchanged. If TEMPLATE_PATH is a directory (issue 010's shape), prints
# TEMPLATE_PATH/provision.yaml when that file exists, or nothing if it
# doesn't -- a directory template isn't required to provision anything
# (e.g. one that only adds mounts).
sandbox_base_template_provision_path() {
	template_path="$1"

	if [ -f "$template_path" ]; then
		echo "$template_path"
		return 0
	fi

	if [ -d "$template_path" ]; then
		candidate="$template_path/provision.yaml"
		if [ -f "$candidate" ]; then
			echo "$candidate"
		fi
	fi
}

# sandbox_base_template_mounts_path TEMPLATE_PATH
#
# Given a path already resolved by sandbox_base_template_path, prints the
# raw Lima mounts-list fragment to splice at lima-template.yaml's
# `__SANDBOX_BASE_MOUNTS__` placeholder (issue 010). Only a directory
# template can supply one: prints TEMPLATE_PATH/mounts.yaml when
# TEMPLATE_PATH is a directory containing that file, or nothing otherwise
# -- including when TEMPLATE_PATH is a plain file, since today's flat-file
# templates have no mechanism for declaring extra mounts.
sandbox_base_template_mounts_path() {
	template_path="$1"

	if [ -d "$template_path" ]; then
		candidate="$template_path/mounts.yaml"
		if [ -f "$candidate" ]; then
			echo "$candidate"
		fi
	fi
}

# sandbox_base_template_port_forwards_path TEMPLATE_PATH
#
# Given a path already resolved by sandbox_base_template_path, prints the
# raw Lima portForwards-list fragment to combine (via
# sandbox_port_forwards_yaml, task.sh) with `--ports`' own dynamic
# mappings at lima-template.yaml's `__SANDBOX_PORT_FORWARDS__` placeholder
# (issue 013) -- most commonly an `ignore: true` rule suppressing Lima's
# own built-in "forward every guest port on 127.0.0.1" catch-all for a
# port the template's own service already listens on (see
# lima-vm/lima#2901). Only a directory template can supply one: prints
# TEMPLATE_PATH/port_forwards.yaml when TEMPLATE_PATH is a directory
# containing that file, or nothing otherwise -- including when
# TEMPLATE_PATH is a plain file, since today's flat-file templates have no
# mechanism for declaring extra port-forward rules.
sandbox_base_template_port_forwards_path() {
	template_path="$1"

	if [ -d "$template_path" ]; then
		candidate="$template_path/port_forwards.yaml"
		if [ -f "$candidate" ]; then
			echo "$candidate"
		fi
	fi
}

# sandbox_base_template_files_path TEMPLATE_PATH
#
# Given a path already resolved by sandbox_base_template_path, prints the
# `files` manifest to pass to sandbox_base_template_files_provision_yaml
# below (issue 012). Only a directory template can supply one: prints
# TEMPLATE_PATH/files when TEMPLATE_PATH is a directory containing that
# file, or nothing otherwise -- including when TEMPLATE_PATH is a plain
# file, since today's flat-file templates have no mechanism for injecting
# individual host files.
sandbox_base_template_files_path() {
	template_path="$1"

	if [ -d "$template_path" ]; then
		candidate="$template_path/files"
		if [ -f "$candidate" ]; then
			echo "$candidate"
		fi
	fi
}

# sandbox_base_template_files_provision_yaml MANIFEST_PATH
#
# MANIFEST_PATH (from sandbox_base_template_files_path) is a plain-text
# list of `HOST_PATH:GUEST_PATH` pairs, one per line -- not raw YAML like
# mounts.yaml, because getting an individual host file's *content* into
# the guest requires reading it fresh right now, at render time (Lima's
# `mounts:` only accepts directories, and its only per-file provisioning
# primitive, `mode: data`, reads its source once at VM-config-render time,
# never live afterward -- confirmed against a real `limactl start` failure
# spawning issue 011's webtools template: `field mounts[N].location refers
# to a non-directory path`), which a static fragment can't express.
#
# For each pair, prints a Lima `mode: data` provision list item (`- mode:
# data` / `path: "GUEST_PATH"` / `content: |` followed by HOST_PATH's exact
# current byte content, indented to nest under that key) -- a snapshot of
# HOST_PATH taken right now, refreshed only by a later call (i.e. a later
# `pj-sbx-spawn`), not a live view of it afterward. A leading `~/` in
# HOST_PATH expands against the real `$HOME`, the same shorthand
# mounts.yaml's `location:` entries already use. `{{.User}}` (Lima's own
# template variable, substituted by Lima itself, the same way
# lima-template.yaml's static mounts/provisioning already use it) owns the
# written file, mode 0600, so the guest login user -- not root -- can read
# it. Prints nothing for an empty or nonexistent MANIFEST_PATH.
sandbox_base_template_files_provision_yaml() {
	manifest_path="$1"

	[ -z "$manifest_path" ] && return 0
	[ -f "$manifest_path" ] || return 0

	while IFS=: read -r host_path guest_path || [ -n "$host_path" ]; do
		[ -z "$host_path" ] && continue

		case "$host_path" in
			"~/"*) expanded_host_path="$HOME/${host_path#\~/}" ;;
			*) expanded_host_path="$host_path" ;;
		esac

		echo "- mode: data"
		echo "  path: \"$guest_path\""
		echo "  owner: \"{{.User}}:{{.User}}\""
		echo "  permissions: \"0600\""
		echo "  content: |"
		sed 's/^/    /' "$expanded_host_path"
	done < "$manifest_path"
}

# sandbox_base_template_list CHECKED_IN_DIR LOCAL_DIR
#
# Prints every valid `--base` name across both directories, one per line,
# sorted by name. Derived straight from each directory's contents (issue
# 004's `--base list`), so dropping in a new template file needs no other
# code change to show up here. A name present in LOCAL_DIR is tagged with
# a trailing " (local)" (and suppresses CHECKED_IN_DIR's entry of the same
# name, since it loses the collision per sandbox_base_template_path
# above); a name present in only CHECKED_IN_DIR is printed bare. Neither
# directory needs to exist. The "(local)" tag itself is wrapped in
# $C_YELLOW/$C_RESET if already set (see sandbox/lib/color.sh) -- the name
# before it is left uncolored, and `sort -k1,1` below still sorts correctly
# by name either way, since the tag (colored or not) only ever follows the
# first whitespace-delimited field.
sandbox_base_template_list() {
	checked_in_dir="$1"
	local_dir="$2"

	local_names=""
	if [ -d "$local_dir" ]; then
		local_names="$(ls -1 "$local_dir")"
	fi

	{
		if [ -n "$local_names" ]; then
			printf '%s\n' "$local_names" | sed "s/\$/ ${C_YELLOW:-}(local)${C_RESET:-}/"
		fi

		if [ -d "$checked_in_dir" ]; then
			ls -1 "$checked_in_dir" | while IFS= read -r name; do
				if ! printf '%s\n' "$local_names" | grep -qxF "$name"; then
					echo "$name"
				fi
			done
		fi
	} | sort -k1,1
}

# sandbox_base_template_names_block CHECKED_IN_DIR LOCAL_DIR
#
# Prints a human-readable "Available --base names:" header followed by
# sandbox_base_template_list's sorted, tagged names, each indented two
# spaces -- the exact block `--help` and every `--base`-related usage/
# error message in pj-sbx-spawn share, so this output only needs
# describing (and coloring) in one place. Wraps the header in
# $C_CYAN/$C_RESET if already set in the environment (see
# sandbox/lib/color.sh, sourced by pj-sbx-spawn before this is called),
# degrading to a plain header if unset -- e.g. when this file is sourced
# standalone, as in this library's own tests.
sandbox_base_template_names_block() {
	checked_in_dir="$1"
	local_dir="$2"

	printf '%sAvailable --base names:%s\n' "${C_CYAN:-}" "${C_RESET:-}"
	sandbox_base_template_list "$checked_in_dir" "$local_dir" | sed 's/^/  /'
}
