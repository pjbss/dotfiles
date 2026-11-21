# skill_doc.sh
#
# Helpers for the tests that check a workflow skill's SKILL.md text
# (pj_write_*_skill_test.sh). Those skills define document templates that
# other skills and the issue loop parse, so their tests pin the template's
# exact lines and the process's key sentences. Meant to be sourced, after
# test/assert.sh. Not a test itself: test/run.sh only runs `*_test.sh`.

# skill_template FILE
#
# Prints the body of the skill's ```markdown fence: the document template.
skill_template() {
	awk '/^```markdown$/ { inside = 1; next } inside && /^```$/ { exit } inside' "$1"
}

# skill_prose FILE
#
# Prints everything outside that fence: frontmatter, process, output.
skill_prose() {
	awk '/^```markdown$/ { inside = 1; next } inside && /^```$/ { inside = 0; next } !inside' "$1"
}

# flatten TEXT
#
# Folds line breaks and runs of spaces into single spaces, so a prose
# assertion survives the paragraph being rewrapped.
flatten() {
	printf '%s' "$1" | tr '\n' ' ' | tr -s ' '
}

# exact_line_number TEXT LINE
#
# Prints the number of the first line of TEXT that is exactly LINE, or
# nothing. Never fails, so it is safe in `$(...)` under `set -e`.
exact_line_number() {
	printf '%s\n' "$1" | { grep -n -x -F -e "$2" || true; } | head -1 | cut -d: -f1
}

# skill_renders SKILL_DIR
#
# Copies SKILL_DIR and bin/dotfiles-sync-agents into a throwaway dotfiles
# tree, renders into a throwaway $HOME, and succeeds only if the skill came
# out for both Claude Code and Copilot CLI. The real $HOME is never touched.
skill_renders() {
	local root name rc=0
	root="$(mktemp -d)"
	name="$(basename "$1")"
	mkdir -p "$root/dotfiles/bin" "$root/dotfiles/agents/skills" "$root/home/.claude"
	cp "$DOTFILES_HOME/bin/dotfiles-sync-agents" "$root/dotfiles/bin/"
	cp -R "$1" "$root/dotfiles/agents/skills/"
	HOME="$root/home" COPILOT_HOME="$root/home/.copilot" \
		"$root/dotfiles/bin/dotfiles-sync-agents" >/dev/null 2>&1 || rc=1
	[ -f "$root/home/.claude/skills/$name/SKILL.md" ] || rc=1
	[ -f "$root/home/.copilot/skills/$name/SKILL.md" ] || rc=1
	rm -rf "$root"
	return "$rc"
}
