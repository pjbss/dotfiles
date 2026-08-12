# worktree.sh
#
# Worktree create/attach/resume decision for `pj-sbx-spawn`
# (issue 003, amended by issue 010's end-to-end validation pass): the
# PRD's "teardown destroys the VM only" decision means a task's
# worktree/branch can already exist on disk at spawn time -- left behind
# by a prior `pj-sbx-teardown` -- and spawn must resume it
# rather than erroring out or trying to re-create it. Separately, a
# branch can exist with no worktree checked out for it (e.g. the worktree
# directory was removed by hand, or `git worktree remove` was run without
# deleting the branch), which needs attaching a new worktree to the
# existing branch rather than `-b` creating a duplicate. Meant to be
# sourced, not executed directly.

# sandbox_resolve_worktree_action REPO_ROOT WORKTREE_PATH BRANCH_NAME
#
# Prints "resume" if WORKTREE_PATH already exists and is a registered git
# worktree of REPO_ROOT per `git worktree list --porcelain` -- spawn should
# skip worktree/branch creation and start a fresh VM directly against it.
# Prints nothing and returns 1 if WORKTREE_PATH exists but isn't a worktree
# of this repo at all (e.g. a stray directory) -- spawn must refuse rather
# than silently reusing or corrupting it.
#
# Otherwise WORKTREE_PATH doesn't exist yet, so the decision hinges on
# BRANCH_NAME: prints "attach" if that branch already exists (e.g. its
# worktree was removed by hand while the branch survived) -- spawn should
# run `git worktree add` against the existing branch rather than trying to
# `-b` create it again. Prints "create" if BRANCH_NAME doesn't exist
# either -- spawn should run `git worktree add -b`.
sandbox_resolve_worktree_action() {
	repo_root="$1"
	worktree_path="$2"
	branch_name="$3"

	if [ -e "$worktree_path" ]; then
		if git -C "$repo_root" worktree list --porcelain | grep -qxF "worktree $worktree_path"; then
			echo "resume"
			return 0
		fi
		return 1
	fi

	if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch_name"; then
		echo "attach"
		return 0
	fi

	echo "create"
	return 0
}
