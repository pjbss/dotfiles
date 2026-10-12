# git_transport.sh
#
# How a task's code reaches the VM without sharing the host .git: the host
# makes or reuses the branch <task>, bundles it into the task's state dir, and
# the guest clones the bundle onto its own disk. Every host git command here
# runs in the host repo; nothing runs in a guest-controlled directory. Meant
# to be sourced, not executed.

# pj_sandbox_git_valid_branch TASK
#
# The task name is used as-is for the host branch and for
# refs/sandbox/<task>/<task>, so it has to be a valid branch name.
pj_sandbox_git_valid_branch() {
	if ! git check-ref-format --branch "$1" >/dev/null 2>&1; then
		echo "pj-sandbox: task '$1' is not a valid git branch name" >&2
		return 1
	fi
}

# pj_sandbox_git_repo
#
# Prints the top level of the git repo the current directory is in.
pj_sandbox_git_repo() {
	if ! git rev-parse --show-toplevel 2>/dev/null; then
		echo "pj-sandbox: spawn must be run inside a git repo" >&2
		return 1
	fi
}

# pj_sandbox_git_start_point REPO BRANCH FROM
#
# Prints the commit a new BRANCH would start from: FROM if given, else
# refs/sandbox/BRANCH/BRANCH if a previous sandbox's work was fetched there,
# else HEAD. Fails if that doesn't resolve to a commit.
pj_sandbox_git_start_point() {
	start="$3"
	if [ -z "$start" ]; then
		if git -C "$1" rev-parse --verify --quiet "refs/sandbox/$2/$2^{commit}" >/dev/null; then
			start="refs/sandbox/$2/$2"
		else
			start=HEAD
		fi
	fi
	if ! git -C "$1" rev-parse --verify --quiet "$start^{commit}"; then
		echo "pj-sandbox: '$start' is not a commit in $1" >&2
		return 1
	fi
}

# pj_sandbox_git_prepare_branch REPO BRANCH FROM
#
# Makes sure REPO has refs/heads/BRANCH. An existing branch is reused as it
# is (FROM is then ignored, with a note); a new one starts from
# pj_sandbox_git_start_point.
pj_sandbox_git_prepare_branch() {
	if git -C "$1" rev-parse --verify --quiet "refs/heads/$2" >/dev/null; then
		if [ -n "$3" ]; then
			echo "pj-sandbox: branch '$2' already exists; using it as it is and ignoring --from" >&2
		fi
		return 0
	fi
	commit="$(pj_sandbox_git_start_point "$1" "$2" "$3")" || return 1
	git -C "$1" branch --no-track "$2" "$commit" >/dev/null
}

# pj_sandbox_git_bundle REPO BRANCH OUT
#
# Writes a bundle of refs/heads/BRANCH and its full history to OUT.
pj_sandbox_git_bundle() {
	git -C "$1" bundle create "$3" "refs/heads/$2" 2>/dev/null
}

# pj_sandbox_git_guest_script
#
# Prints the script the guest runs (as `sh -s -- BUNDLE WORKSPACE BRANCH`) to
# clone the bundle. Its git hardening is ported from bin/pj-sbx-spawn and only
# guards against accidents, since the guest user has sudo:
#
#   core.hooksPath      -> an empty directory, so guest git never runs a hook.
#   protocol.ext.allow  -> never, so an `ext::<command>` url can't be fetched.
#
# The bundle remote is removed after the clone, leaving origin unset for the
# gh profile to set.
pj_sandbox_git_guest_script() {
	cat <<'SCRIPT'
set -eu
bundle="$1"
workspace="$2"
branch="$3"

mkdir -p "$HOME/.config/git/empty-hooks"
git config --global core.hooksPath "$HOME/.config/git/empty-hooks"
git config --global protocol.ext.allow never

if ! mkdir -p "$workspace" 2>/dev/null; then
	sudo mkdir -p "$workspace"
	sudo chown "$(id -u):$(id -g)" "$workspace"
fi
git clone --quiet --branch "$branch" "$bundle" "$workspace"
git -C "$workspace" remote remove origin
rm -f "$bundle"
SCRIPT
}

# pj_sandbox_git_fetch REPO INSTANCE TASK
#
# Fetches every branch of INSTANCE:/workspace, over the instance's ssh Host
# entry, into REPO's refs/sandbox/TASK/*. Nothing under refs/heads/* is
# touched and nothing is checked out. The guest controls what it serves, so
# the fetch runs in REPO with no hooks (core.hooksPath=/dev/null), no
# fsmonitor (core.fsmonitor=false) and no `ext::` transport
# (protocol.ext.allow=never), whatever REPO's or the user's config says.
pj_sandbox_git_fetch() {
	git -C "$1" -c core.hooksPath=/dev/null -c core.fsmonitor=false -c protocol.ext.allow=never \
		fetch "$2:/workspace" "+refs/heads/*:refs/sandbox/$3/*"
}
