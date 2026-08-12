# help.sh
#
# Shared `--help`/`-h` text extraction for the `pj-*` sandbox commands
# (issue 007) and `pj-help` (issue 008): every script's own leading
# header comment is its documentation, so this reads that instead of a
# separately hand-maintained usage string that could drift out of sync.
# Meant to be sourced, not executed directly.

# sandbox_script_help SCRIPT_PATH
#
# Prints SCRIPT_PATH's leading `#`-prefixed header comment block, stripping
# each line's leading `#` marker (plus one following space, if present).
# Skips a `#!` shebang line first, if line 1 is one. Stops at the first
# line that isn't a comment (blank or code), so it never bleeds into the
# script body below the header. Prints nothing -- not an error -- for a
# script with no header comment at all (e.g. a shebang immediately
# followed by code).
sandbox_script_help() {
	script_path="$1"

	awk '
		NR == 1 && /^#!/ { next }
		/^#/ { sub(/^# ?/, ""); print; next }
		{ exit }
	' "$script_path"
}

# sandbox_comment_block_above FILE LINE_PREFIX
#
# Prints the contiguous `#`-prefixed comment block immediately preceding
# the first line in FILE that starts with the literal string LINE_PREFIX
# (a plain substring match, not a regex -- avoids the caller ever needing
# to escape regex metacharacters for something like a literal
# `funcname() {`), stripping each line's leading `#` marker the same way
# sandbox_script_help does. For doc comments that sit directly above a
# function definition rather than at the top of a script (e.g.
# `pj-sbx-ssh` in zsh/modules/sandbox.zsh, which has no `bin/`
# counterpart -- issue 008). Prints nothing -- not an error -- if
# LINE_PREFIX never matches, or if the matching line has no comment block
# immediately above it (any intervening blank/code line resets the
# block).
sandbox_comment_block_above() {
	file_path="$1"
	line_prefix="$2"

	awk -v prefix="$line_prefix" '
		index($0, prefix) == 1 { print buf; exit }
		/^#/ { line = $0; sub(/^# ?/, "", line); buf = (buf == "" ? line : buf "\n" line); next }
		{ buf = "" }
	' "$file_path"
}

# sandbox_help_summary HEADER_TEXT
#
# Given a header comment block already stripped of its `#` markers (as
# printed by sandbox_script_help or sandbox_comment_block_above),
# extracts the command name -- the title line's first whitespace-
# delimited token, so `pj-sbx-ssh <task-name>` collapses to just
# `pj-sbx-ssh` -- and its one-line description -- the first non-blank
# line after the title. Prints "name\tdescription" (issue 008's `pj-help`
# index format). Prints nothing for an empty/malformed header.
sandbox_help_summary() {
	header_text="$1"

	printf '%s\n' "$header_text" | awk '
		NR == 1 { split($0, parts, /[ \t]/); name = parts[1]; next }
		NF == 0 { next }
		{ print name "\t" $0; exit }
	'
}
