#!/bin/sh
# pj-hook-guard-bash.sh
#
# PreToolUse hook. Refuses tool calls that reach outside the work the agent was
# actually asked to do. Exit 2 blocks the call and hands the message on stderr
# back to the model, so it gets a chance to do the right thing instead.
#
# This is defense in depth, and it is important to be honest about where it
# sits. Inside a sandbox the guest has passwordless sudo, so anything running
# in there could disable this hook outright -- which is precisely why the load
# bearing control is the *host-side* integrity check (sandbox/lib/gitdir_guard.
# sh, `pj-sbx-verify`) that runs where the guest cannot reach it. What this
# buys is that the accidental path -- a confused agent, or a prompt injection
# sitting in a file it was told to read -- stops being one command wide.
#
# Two enforcement levels, because a rule that makes ordinary host work
# impossible gets switched off and then protects nothing:
#
#   Everywhere, including the host:
#     - running install.sh without overriding $HOME (it symlinks into the home
#       directory; it must only ever be exercised against a scratch one)
#     - rm -rf against $HOME or /
#
#   Inside a sandbox only (/etc/pj-sandbox present, written at spawn time):
#     - writing anywhere outside /workspace
#     - any write under the mounted host git directory -- files there run on
#       the *host* (hooks/, core.hooksPath, filter.*.clean, ext:: remotes)
#     - git push, and git remote add/set-url
#     - sudo
#     - piping a download straight into a shell
#
# Reads the hook payload as JSON on stdin; python3 is already a hard dependency
# of the guest bootstrap and of sandbox/lib/workspace.sh, so parsing with it
# rather than assuming `jq` is installed costs nothing.

set -eu

payload="$(cat)"

extract() {
	printf '%s' "$payload" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
field = sys.argv[1]
if field == "tool_name":
    print(data.get("tool_name", ""))
else:
    print(data.get("tool_input", {}).get(field, "") or "")
' "$1"
}

tool_name="$(extract tool_name)"

deny() {
	echo "pj-hook-guard-bash: $1" >&2
	exit 2
}

# The marker path is overridable so both rule sets can actually be tested --
# /etc/pj-sandbox can't be created in a unit test, and a guard whose strict
# half is untestable is a guard nobody can trust.
in_sandbox() {
	[ -f "${PJ_SANDBOX_MARKER:-/etc/pj-sandbox}" ]
}

case "$tool_name" in
	Bash)
		command_text="$(extract command)"

		# install.sh symlinks into $HOME and backs up whatever it displaces.
		# Running it against a real home directory to "see if it works" is how
		# you lose a hand-written config; it must be pointed at a scratch HOME
		# (or run via dotfiles-test-install, which containerises one).
		case "$command_text" in
			*install.sh*)
				case "$command_text" in
					HOME=*|*" HOME="*|*dotfiles-test-install*|*docker*) ;;
					*) deny "refusing to run install.sh without an explicit HOME= override -- it symlinks into the home directory. Use 'HOME=<scratch> ./install.sh', or dotfiles-test-install for a containerised run." ;;
				esac
				;;
		esac

		case "$command_text" in
			*"rm -rf /"|*"rm -rf / "*|*"rm -rf ~"*|*"rm -rf \$HOME"*|*'rm -rf "$HOME"'*)
				deny "refusing a recursive delete of the home directory or filesystem root."
				;;
		esac

		in_sandbox || exit 0

		case "$command_text" in
			*"git push"*)
				deny "refusing 'git push' from inside a sandbox. Sandboxes deliberately hold no push credentials; commit here and push from the host after reviewing."
				;;
			*"git remote add"*|*"git remote set-url"*)
				deny "refusing to change git remotes from inside a sandbox -- a remote url is an execution primitive (see ext::)."
				;;
			sudo\ *|*" sudo "*|*"|sudo "*)
				deny "refusing 'sudo' from inside a sandbox. Everything the task needs is reachable as the regular user; if it genuinely isn't, that belongs in the --base provisioning template, not in an agent's shell command."
				;;
			*curl*"| sh"*|*curl*"|sh"*|*wget*"| sh"*|*wget*"|sh"*|*curl*"| bash"*|*wget*"| bash"*)
				deny "refusing to pipe a download straight into a shell. Fetch it, read it, then run it."
				;;
		esac
		;;

	Write | Edit | NotebookEdit)
		file_path="$(extract file_path)"
		[ -n "$file_path" ] || exit 0

		in_sandbox || exit 0

		# Checked before the general rule below. The host git directory is
		# mounted at its identical absolute host path, so it's already outside
		# /workspace and the general rule would catch it -- but this is the one
		# path where a write becomes *host* code execution, and saying so is
		# the difference between the model understanding the boundary and
		# trying a slightly different way round it.
		case "$file_path" in
			*/.git/hooks/* | */.git/config | */config.worktree | */hooks/pre-commit | */hooks/post-commit)
				deny "refusing to write to a git directory's hooks or config (tried: $file_path). That directory is a host mount, and files in it run on the host, as the host user, on the next host-side git command."
				;;
		esac

		case "$file_path" in
			/workspace/*) ;;
			/tmp/* | /var/folders/*) ;;
			*)
				deny "refusing to write outside /workspace (tried: $file_path). A sandbox's job is the worktree mounted there; everything else it can see is either a host mount or throwaway VM state."
				;;
		esac
		;;
esac

exit 0
