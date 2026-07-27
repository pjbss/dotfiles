# list.sh
#
# Sandbox discovery/listing logic for `pj-sandbox-list`: enumerates
# sandboxes known to this tooling (rendered per-task Lima configs under a
# sandbox root, written by pj-sandbox-spawn/issue 003) and
# correlates them with `limactl list --json` for live status. Meant to be
# sourced, not executed directly.

# sandbox_list_entries ROOT
#
# For every "<root>/<repo>/lima-configs/<instance>.yaml" found, prints one
# tab-separated line: "<instance>\t<worktree-path>\t<status>", where
# worktree-path is "<root>/<repo>/worktrees/<instance>" (the layout
# pj-sandbox-spawn writes, issue 003) and status is whatever
# `limactl list --json` reports for that instance name, or "stopped" if
# limactl has no record of it (e.g. the VM was torn down but the render
# artifact and worktree still exist -- issue 007 decides whether that
# artifact is removed on teardown; while it isn't, entries linger here as
# "stopped" rather than disappearing outright). Prints nothing if no
# sandboxes are known under ROOT.
sandbox_list_entries() {
	root="$1"

	# One `limactl list --json` call, parsed into "name status" pairs --
	# cheaper than shelling out per instance. Each JSON object is its own
	# line (confirmed against real `limactl list --json` output, matching
	# the fixtures in task_test.sh); name/status are pulled independently
	# so field order in the JSON doesn't matter.
	live_status="$(limactl list --json 2>/dev/null | while IFS= read -r line; do
		name="$(echo "$line" | grep -Eo '"name":"[^"]*"' | sed -E 's/.*:"(.*)"/\1/')"
		status="$(echo "$line" | grep -Eo '"status":"[^"]*"' | sed -E 's/.*:"(.*)"/\1/')"
		[ -n "$name" ] && printf '%s %s\n' "$name" "$status"
	done)"

	for config in "$root"/*/lima-configs/*.yaml; do
		[ -e "$config" ] || continue

		instance="$(basename "$config" .yaml)"
		repo_dir="$(dirname "$(dirname "$config")")"
		worktree_path="$repo_dir/worktrees/$instance"

		status="$(echo "$live_status" | awk -v n="$instance" '$1 == n { print $2 }')"
		status="${status:-stopped}"

		printf '%s\t%s\t%s\n' "$instance" "$worktree_path" "$status"
	done
}
