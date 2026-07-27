# devcontainer.sh
#
# devcontainer.json discovery for `pj-sandbox-spawn` (issue 008): the
# PRD's "devcontainer-or-bare, no generic fallback" runtime-provisioning
# decision hinges on detecting whether the task's project defines one, at
# either of the devcontainer CLI's two conventional discovery locations.
# Meant to be sourced, not executed directly.

# sandbox_devcontainer_config_path WORKTREE_PATH
#
# Prints the devcontainer.json path for WORKTREE_PATH and returns 0 if one
# exists, checking `.devcontainer/devcontainer.json` before
# `.devcontainer.json` at the project root (the devcontainer CLI's own
# discovery precedence). Prints nothing and returns 1 if neither exists.
sandbox_devcontainer_config_path() {
	worktree_path="$1"

	if [ -f "$worktree_path/.devcontainer/devcontainer.json" ]; then
		echo "$worktree_path/.devcontainer/devcontainer.json"
		return 0
	fi

	if [ -f "$worktree_path/.devcontainer.json" ]; then
		echo "$worktree_path/.devcontainer.json"
		return 0
	fi

	return 1
}
