# base_template.sh
#
# `--base <name>` resolution for `pj-sandbox spawn`. Ported from
# sandbox/lib/base_template.sh; the template format is unchanged. A name is a
# flat provision fragment or a directory holding provision.yaml, mounts.yaml
# and/or a files manifest, found under pj-sandbox/templates/ or the gitignored
# local/pj-sandbox/templates/, where local wins a name collision. Unlike the
# original, spawn refuses any template with a mounts.yaml (no host mounts),
# and template port_forwards.yaml isn't ported, so every forward stays on
# 127.0.0.1. Meant to be sourced, not executed.

# pj_sandbox_base_template_path CHECKED_IN_DIR LOCAL_DIR NAME
#
# Prints NAME's template path, LOCAL_DIR's entry first, and returns 0; prints
# nothing and returns 1 if neither directory has it. Either directory may be
# missing. A comma-separated NAME never matches, so exactly one template
# applies per sandbox.
pj_sandbox_base_template_path() {
	[ -n "$3" ] || return 1
	for candidate in "$2/$3" "$1/$3"; do
		if [ -e "$candidate" ]; then
			echo "$candidate"
			return 0
		fi
	done
	return 1
}

# pj_sandbox_base_template_provision_path TEMPLATE_PATH
#
# Prints the provision-list fragment for a resolved template: a flat file is
# its own fragment; a directory's is its provision.yaml, or nothing.
pj_sandbox_base_template_provision_path() {
	if [ -f "$1" ]; then
		echo "$1"
	elif [ -f "$1/provision.yaml" ]; then
		echo "$1/provision.yaml"
	fi
}

# pj_sandbox_base_template_mounts_path TEMPLATE_PATH
#
# Prints a directory template's mounts.yaml, or nothing. pj-sandbox never
# renders it: spawn uses it only to refuse the template.
pj_sandbox_base_template_mounts_path() {
	if [ -d "$1" ] && [ -f "$1/mounts.yaml" ]; then
		echo "$1/mounts.yaml"
	fi
}

# pj_sandbox_base_template_files_path TEMPLATE_PATH
#
# Prints a directory template's `files` manifest, or nothing.
pj_sandbox_base_template_files_path() {
	if [ -d "$1" ] && [ -f "$1/files" ]; then
		echo "$1/files"
	fi
}

# pj_sandbox_base_template_files_provision_yaml MANIFEST_PATH
#
# MANIFEST_PATH lists HOST_PATH:GUEST_PATH pairs, one per line (blank lines
# skipped, a leading ~/ in HOST_PATH expanded against $HOME). For each, prints
# a Lima `mode: data` provision item writing a snapshot of HOST_PATH's current
# content to GUEST_PATH, owned by the guest user, mode 0600 -- the copy-in
# that replaces a host mount. Prints nothing for an empty or missing
# MANIFEST_PATH; fails if a listed host file can't be read.
pj_sandbox_base_template_files_provision_yaml() {
	[ -n "$1" ] && [ -f "$1" ] || return 0

	while IFS=: read -r host_path guest_path || [ -n "$host_path" ]; do
		[ -n "$host_path" ] || continue

		case "$host_path" in
			"~/"*) host_path="$HOME/${host_path#\~/}" ;;
		esac
		if [ ! -r "$host_path" ] || [ -d "$host_path" ]; then
			echo "pj-sandbox: template file '$host_path' isn't a readable file" >&2
			return 1
		fi

		echo "- mode: data"
		echo "  path: \"$guest_path\""
		echo "  owner: \"{{.User}}:{{.User}}\""
		echo "  permissions: \"0600\""
		echo "  content: |"
		sed 's/^/    /' "$host_path" || return 1
	done < "$1"
}

# pj_sandbox_base_template_list CHECKED_IN_DIR LOCAL_DIR
#
# Prints every valid --base name across both directories, one per line,
# sorted. A LOCAL_DIR name is tagged " (local)" (in $C_YELLOW, if set) and
# hides the CHECKED_IN_DIR entry it overrides. Either directory may be
# missing.
pj_sandbox_base_template_list() {
	local_names=""
	if [ -d "$2" ]; then
		local_names="$(ls -1 "$2")"
	fi

	{
		if [ -n "$local_names" ]; then
			printf '%s\n' "$local_names" | sed "s/\$/ ${C_YELLOW:-}(local)${C_RESET:-}/"
		fi
		if [ -d "$1" ]; then
			ls -1 "$1" | while IFS= read -r name; do
				printf '%s\n' "$local_names" | grep -qxF "$name" || echo "$name"
			done
		fi
	} | sort -k1,1
}

# pj_sandbox_base_template_names_block CHECKED_IN_DIR LOCAL_DIR
#
# The "Available --base names:" block that --help and every --base error
# share: a header, then the listing indented two spaces.
pj_sandbox_base_template_names_block() {
	printf '%sAvailable --base names:%s\n' "${C_CYAN:-}" "${C_RESET:-}"
	pj_sandbox_base_template_list "$1" "$2" | sed 's/^/  /'
}
