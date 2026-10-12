# cmd_fetch.sh
#
# pj-sandbox fetch <task>
#
# Fetches every branch of the task's guest /workspace into the host repo's
# refs/sandbox/<task>/* (lib/git_transport.sh), then prints those refs and
# `git log --oneline <branch>..refs/sandbox/<task>/<branch>` for review, and
# records the fetch time as fetched= in the state record. Host branches are
# never moved and nothing is checked out; merging is left to the user.

. "$PJ_SANDBOX_HOME/lib/namespace.sh"
. "$PJ_SANDBOX_HOME/lib/state.sh"
. "$PJ_SANDBOX_HOME/lib/git_transport.sh"

cmd_fetch() {
	if [ "$#" -ne 1 ] || [ -z "$1" ]; then
		echo "Usage: pj-sandbox fetch <task>" >&2
		return 1
	fi
	task="$1"

	if ! pj_sandbox_state_exists "$task"; then
		echo "pj-sandbox: fetch: no sandbox task '$task' (see 'pj-sandbox list')" >&2
		return 1
	fi
	repo="$(pj_sandbox_state_get "$task" repo)"
	instance="$(pj_sandbox_state_get "$task" instance)"
	branch="$(pj_sandbox_state_get "$task" branch)"
	if [ -z "$repo" ] || [ -z "$instance" ] || [ -z "$branch" ]; then
		echo "pj-sandbox: fetch: the record for '$task' lacks its repo, instance or branch" >&2
		return 1
	fi

	if ! pj_sandbox_git_fetch "$repo" "$instance" "$task"; then
		echo "pj-sandbox: fetch: fetching $instance:/workspace into $repo failed" >&2
		return 1
	fi
	pj_sandbox_state_update "$task" "fetched=$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1

	echo "Fetched into refs/sandbox/$task/:"
	git -C "$repo" for-each-ref --format='  %(objectname:short) %(refname)' "refs/sandbox/$task/"

	sandbox_ref="refs/sandbox/$task/$branch"
	if ! git -C "$repo" rev-parse --verify --quiet "$sandbox_ref^{commit}" >/dev/null; then
		echo "The guest has no branch '$branch'."
	elif ! git -C "$repo" rev-parse --verify --quiet "refs/heads/$branch^{commit}" >/dev/null; then
		echo "The host has no branch '$branch'; to review: git log $sandbox_ref"
	else
		echo "Commits in $sandbox_ref not on $branch:"
		git -C "$repo" log --oneline "refs/heads/$branch..$sandbox_ref"
	fi
}
