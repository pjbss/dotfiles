# gitdir_guard.sh
#
# Integrity manifest for the one host directory a sandbox VM can write to that
# it has no business writing to: the spawning repo's real git directory.
#
# lima-template.yaml mounts that directory read-write, at its identical
# absolute host path, because a linked worktree's `.git` is a file containing
# `gitdir: <absolute host path>/worktrees/<name>` -- without the mount, every
# git command inside /workspace fails outright. It has to be writable, since
# commits made in the guest write objects and refs into that shared store.
#
# That makes it a host code-execution channel. Anything written to `hooks/`
# there runs on the *host*, as the host user, the next time a host-side git
# command touches the repo -- and `config` can redirect core.hooksPath, install
# a filter.*.clean/smudge command, or point a remote's url at an `ext::`
# transport, each of which also ends in host command execution. No legitimate
# agent activity touches hooks/, and committing, branching, fetching and merging
# write only to objects/ and refs/. The exception is config's per-branch
# bookkeeping (upstream tracking, editor metadata), which is written all the
# time and is filtered out before hashing -- see _sandbox_gitdir_config_sha.
#
# So rather than trying to make the mount read-only (which would break git) or
# relying on a guest-side rule (which an agent with root in the VM can simply
# remove), this records a hash manifest on the host at spawn time and re-checks
# it on the host later. The check runs entirely outside the guest's reach.
#
# Objects and refs growing is expected and deliberately not covered -- that's
# the work the sandbox exists to do.
#
# Meant to be sourced, not executed directly.

# _sandbox_gitdir_sha FILE
#
# Echoes a file's SHA-256, using whichever tool this platform ships:
# `shasum -a 256` on macOS, `sha256sum` on Linux. The host is macOS today, but
# this lib is also reachable from inside a guest, so it can't assume either.
_sandbox_gitdir_sha() {
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | awk '{print $1}'
	else
		sha256sum "$1" | awk '{print $1}'
	fi
}

# _sandbox_gitdir_sha_batch < NUL_SEPARATED_FILE_LIST
#
# Hashes every path on stdin in as few processes as possible, emitting the
# hashing tool's native `<sha>  <path>` lines.
#
# Batched rather than one call per file because this runs on every spawn,
# teardown and dispatch: a default hooks/ directory holds around fifteen
# .sample files, so a call per file spent fifteen process spawns per manifest.
#
# Input MUST be NUL-separated (`find -print0`), and `xargs -0` is not optional:
# with newline-separated input, xargs splits on whitespace, so a repo living
# under a path with a space in it (`~/My Repos/thing`) hashes nothing at all.
# The manifest then silently contains only `config`, and verification reports
# *clean* no matter what was planted in hooks/ -- a false all-clear from a
# check whose entire job is detecting tampering.
_sandbox_gitdir_sha_batch() {
	if command -v shasum >/dev/null 2>&1; then
		xargs -0 shasum -a 256
	else
		xargs -0 sha256sum
	fi
}

# _sandbox_gitdir_config_sha CONFIG_FILE
#
# Echoes the SHA-256 of CONFIG_FILE's *security-relevant* content, rather than
# of its raw bytes.
#
# Hashing the raw file made the guard fail on nearly every teardown for no
# reason: editors rewrite per-branch keys in the shared config constantly --
# VS Code's git and GitHub PR extensions set branch.<name>.vscode-merge-base
# and branch.<name>.github-pr-* on every checkout, and `git push -u` from
# inside the guest sets branch.<name>.remote/merge. A real repo's config was
# seen at 1,200+ lines, almost all of them exactly those keys. None of them can
# make git run anything, so they're filtered out before hashing:
#
#   branch.*.merge, branch.*.description, branch.*.vscode-*, branch.*.github-pr-*
#   branch.*.remote / pushremote -- only when the value is a plain remote name.
#     A URL there (`ext::sh -c ...`) is fetched from directly, so any value
#     containing `:` or `/` stays covered.
#
# Everything else -- core.*, filter.*, remote.*, include*, alias.*, and any
# branch.* key not listed above -- is hashed in file order, so adding,
# changing or removing it still fails verification.
#
# Parsed with `git config --file ... --list`, which only reads (nothing in a
# config file executes on read). If git can't parse the file at all, the raw
# bytes are hashed instead, so a malformed config registers as a change rather
# than as an empty -- and therefore matching -- view.
_sandbox_gitdir_config_sha() {
	if listing="$(git config --file "$1" --list 2>/dev/null)"; then
		printf '%s\n' "$listing" | awk '
			{
				eq = index($0, "=")
				if (eq > 0 && substr($0, 1, 7) == "branch.") {
					key = substr($0, 1, eq - 1)
					value = substr($0, eq + 1)
					n = split(key, parts, ".")
					var = parts[n]
					if (var == "merge" || var == "description" || var ~ /^vscode-/ || var ~ /^github-pr-/)
						next
					if ((var == "remote" || var == "pushremote") && value ~ /^[A-Za-z0-9._-]+$/)
						next
				}
				print
			}
		' | _sandbox_gitdir_sha_stdin
	else
		_sandbox_gitdir_sha "$1"
	fi
}

_sandbox_gitdir_sha_stdin() {
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 | awk '{print $1}'
	else
		sha256sum | awk '{print $1}'
	fi
}

# sandbox_gitdir_manifest GITDIR
#
# Prints the manifest for GITDIR: one `<sha256>  <relative path>` line per
# covered file, sorted by path so the output is stable across runs and
# filesystems.
#
# Covered: `config`, every file under `hooks/`, and every per-worktree
# `config.worktree` (a worktree-scoped config override is just as good a place
# to hide a filter command as the main one). Both config kinds are hashed
# through _sandbox_gitdir_config_sha, not byte-for-byte. A file's *absence* is recorded too
# -- as an `absent` line -- so that deleting `config` registers as a change
# rather than as a shorter, quietly-matching manifest.
sandbox_gitdir_manifest() {
	gitdir="$1"
	file_list="$(mktemp)"

	{
		if [ -f "$gitdir/config" ]; then
			printf '%s  %s\n' "$(_sandbox_gitdir_config_sha "$gitdir/config")" config
		else
			printf 'absent  %s\n' config
		fi

		# The `|| true` on each find is load-bearing under `set -o pipefail`:
		# a find over a directory that doesn't exist yet (no `worktrees/` until
		# the first `git worktree add`) exits non-zero, which would otherwise
		# make this whole function report failure on a perfectly healthy repo.
		if [ -d "$gitdir/hooks" ]; then
			{ find "$gitdir/hooks" -type f -print0 2>/dev/null || true; } > "$file_list"

			# Split on $0, not $NF: the hashing tools print `<sha>  <path>`,
			# and a gitdir under a directory with a space in its name (common
			# enough on macOS) splits into more fields than expected. The text
			# after the final "/" is the basename either way.
			if [ -s "$file_list" ]; then
				_sandbox_gitdir_sha_batch < "$file_list" |
					awk '{ n = split($0, parts, "/"); print $1 "  hooks/" parts[n] }'
			else
				printf 'absent  hooks/\n'
			fi
		else
			printf 'absent  hooks/\n'
		fi

		# One process per file here, unlike hooks/ above, because each one is
		# normalized the same way as the main config -- with
		# extensions.worktreeConfig set, per-branch keys land here too. There's
		# one of these per worktree that has one, not fifteen.
		{ find "$gitdir/worktrees" -mindepth 2 -maxdepth 2 -name config.worktree -type f 2>/dev/null || true; } |
		while IFS= read -r worktree_config; do
			worktree_name="$(basename "$(dirname "$worktree_config")")"
			printf '%s  %s\n' "$(_sandbox_gitdir_config_sha "$worktree_config")" "worktrees/$worktree_name/config.worktree"
		done
	} | sort -k2

	rm -f "$file_list"
}

# sandbox_gitdir_manifest_write GITDIR MANIFEST_PATH
sandbox_gitdir_manifest_write() {
	mkdir -p "$(dirname "$2")"
	sandbox_gitdir_manifest "$1" > "$2"
}

# sandbox_gitdir_verify GITDIR MANIFEST_PATH
#
# Re-derives the manifest and compares it with the recorded one. Prints one
# human-readable line per difference (added / removed / modified, named by
# path) and returns non-zero if there were any; prints nothing and returns 0
# when they match.
#
# Returns non-zero with an explanation if the manifest file itself is missing,
# rather than treating "nothing recorded" as "nothing changed" -- a sandbox
# spawned before this guard existed must not silently read as verified.
sandbox_gitdir_verify() {
	gitdir="$1"
	manifest_path="$2"

	if [ ! -f "$manifest_path" ]; then
		echo "no integrity manifest recorded at $manifest_path -- cannot verify this sandbox"
		return 1
	fi

	current="$(mktemp)"
	sandbox_gitdir_manifest "$gitdir" > "$current"

	# One awk pass over both manifests, rather than comm plus a lookup per
	# path. Reported by name ("hooks/post-commit appeared") rather than as a
	# hash diff, because the path is the part a person acts on.
	differences_text="$(awk '
		NR == FNR { recorded[$2] = $1; next }
		{ current[$2] = $1 }
		END {
			for (path in current)
				if (!(path in recorded))
					print "APPEARED: " path
			for (path in recorded)
				if (!(path in current))
					print "REMOVED:  " path
			for (path in current)
				if ((path in recorded) && recorded[path] != current[path])
					print "MODIFIED: " path
		}
	' "$manifest_path" "$current" | sort)"

	rm -f "$current"

	if [ -n "$differences_text" ]; then
		printf '%s\n' "$differences_text"
		differences=1
	else
		differences=0
	fi

	[ "$differences" -eq 0 ]
}
