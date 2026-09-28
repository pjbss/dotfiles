# post_create.sh
#
# Path-vs-command resolution for `pj-sbx-spawn`'s `--post-create` flag
# (issue 014, see issues/prd-post-create.md): given the flag's raw value
# and the repo root, decides whether it names an existing script file
# (relative to the repo root, or absolute) or should run verbatim as a
# shell command -- "Path-vs-command disambiguation, not a separate flag for
# each" per the PRD's Implementation Decisions. Meant to be sourced, not
# executed directly.

# sandbox_post_create_resolve VALUE REPO_ROOT
#
# If VALUE names an existing file, prints its current content (read fresh,
# at call time -- so a script edited between spawns always runs its latest
# version) and returns 0: pj-sbx-spawn should run that content as a script.
# Otherwise prints VALUE unchanged and returns 1: pj-sbx-spawn should run
# VALUE itself verbatim as a shell command.
#
# A relative VALUE resolves against REPO_ROOT; one starting with `/` is an
# absolute host path, used as-is. The absolute form is there because a
# post-create script needn't live in the repo being spawned at all -- one
# shared across several projects belongs in this dotfiles checkout (e.g.
# local/sandbox/post-create/), which nothing relative to some other repo's
# root can reach. Without it such a value wouldn't error, it would quietly
# fall through to the verbatim-command branch and surface only as the guest
# failing to run a path as a command.
sandbox_post_create_resolve() {
	value="$1"
	repo_root="$2"
	case "$value" in
		/*) candidate="$value" ;;
		*) candidate="$repo_root/$value" ;;
	esac

	if [ -f "$candidate" ]; then
		cat "$candidate"
		return 0
	fi

	echo "$value"
	return 1
}
