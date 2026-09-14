# post_create.sh
#
# Path-vs-command resolution for `pj-sbx-spawn`'s `--post-create` flag
# (issue 014, see issues/prd-post-create.md): given the flag's raw value
# and the repo root, decides whether it names an existing script file
# (relative to the repo root) or should run verbatim as a shell command --
# "Path-vs-command disambiguation, not a separate flag for each" per the
# PRD's Implementation Decisions. Meant to be sourced, not executed
# directly.

# sandbox_post_create_resolve VALUE REPO_ROOT
#
# If REPO_ROOT/VALUE exists as a file, prints its current content (read
# fresh, at call time -- so a script edited between spawns always runs its
# latest version) and returns 0: pj-sbx-spawn should run that content as a
# script. Otherwise prints VALUE unchanged and returns 1: pj-sbx-spawn
# should run VALUE itself verbatim as a shell command.
sandbox_post_create_resolve() {
	value="$1"
	repo_root="$2"
	candidate="$repo_root/$value"

	if [ -f "$candidate" ]; then
		cat "$candidate"
		return 0
	fi

	echo "$value"
	return 1
}
