# list.sh
#
# Sandbox discovery/listing logic for `pj-sbx-list`: enumerates
# sandboxes known to this tooling (rendered per-task Lima configs under a
# sandbox root, written by pj-sbx-spawn/issue 003) and
# correlates them with `limactl list --json` for live status. Meant to be
# sourced, not executed directly.

# sandbox_port_mapping CONFIG_FILE
#
# Reads a rendered per-task Lima config (sandbox_render_lima_config's
# output, written by pj-sbx-spawn -- issue 005) and prints its `--ports`
# host<->guest mapping as a single comma-separated "hostPort:guestPort,..."
# string (e.g. "60100:8000,60101:5432"), in the same order the
# `portForwards:` block lists them. Prints nothing (empty string) if
# CONFIG_FILE has no `portForwards:` block at all -- the sandbox was
# spawned without `--ports`, not an error. Parses the file directly with
# awk rather than via `limactl list --json`: the mapping is baked into the
# config at spawn time and doesn't change while the VM runs, and reading
# it straight from the artifact this tooling already discovers sandboxes
# from works identically whether the instance is running or stopped.
sandbox_port_mapping() {
	config_file="$1"

	awk '
		/guestPort:/ { gsub(/[^0-9]/, "", $0); g = $0 }
		/hostPort:/ { gsub(/[^0-9]/, "", $0); h = $0; printf "%s%s:%s", (n++ ? "," : ""), h, g }
	' "$config_file"
}

# sandbox_list_entries ROOT
#
# For every "<root>/<repo>/lima-configs/<instance>.yaml" found, prints one
# tab-separated line: "<instance>\t<worktree-path>\t<status>\t<port-mapping>",
# where worktree-path is "<root>/<repo>/worktrees/<instance>" (the layout
# pj-sbx-spawn writes, issue 003), status is whatever
# `limactl list --json` reports for that instance name, or "stopped" if
# limactl has no record of it (e.g. the VM was torn down but the render
# artifact and worktree still exist -- issue 007 decides whether that
# artifact is removed on teardown; while it isn't, entries linger here as
# "stopped" rather than disappearing outright), and port-mapping is
# sandbox_port_mapping's output for that instance's rendered config (empty
# for a sandbox spawned without `--ports`, issue 006). Prints nothing if no
# sandboxes are known under ROOT.
sandbox_list_entries() {
	root="$1"

	# One `limactl list --json` call, parsed into "name status" pairs --
	# cheaper than shelling out per instance. Each JSON object is its own
	# line (confirmed against real `limactl list --json` output, matching
	# the fixtures in task_test.sh); name/status are pulled independently
	# so field order in the JSON doesn't matter.
	# `head -1`: each JSON object's *first* "name"/"status" match is always
	# the instance's own top-level field. Without it, Lima's nested
	# `config.user.name` (the guest username, unrelated to the instance
	# name) is a second "name":"..." match on the same line -- confirmed
	# against a real spawned sandbox, where that extra match broke the
	# name/status pairing below and caused a running instance to be
	# misreported as stopped.
	live_status="$(limactl list --json 2>/dev/null | while IFS= read -r line; do
		name="$(echo "$line" | grep -Eo '"name":"[^"]*"' | head -1 | sed -E 's/.*:"(.*)"/\1/')"
		status="$(echo "$line" | grep -Eo '"status":"[^"]*"' | head -1 | sed -E 's/.*:"(.*)"/\1/')"
		[ -n "$name" ] && printf '%s %s\n' "$name" "$status"
	done)"

	for config in "$root"/*/lima-configs/*.yaml; do
		[ -e "$config" ] || continue

		instance="$(basename "$config" .yaml)"
		repo_dir="$(dirname "$(dirname "$config")")"
		worktree_path="$repo_dir/worktrees/$instance"

		status="$(echo "$live_status" | awk -v n="$instance" '$1 == n { print $2 }')"
		status="${status:-stopped}"

		port_mapping="$(sandbox_port_mapping "$config")"

		printf '%s\t%s\t%s\t%s\n' "$instance" "$worktree_path" "$status" "$port_mapping"
	done
}
