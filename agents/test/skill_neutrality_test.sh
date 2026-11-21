#!/bin/bash
# skill_neutrality_test.sh
#
# Keeps the tool-neutral skills tool-neutral. Everything under agents/skills/
# is rendered for GitHub Copilot CLI as well as Claude Code (agents/README.md,
# "Rendering"), so a skill that names a Claude-only subagent or leans on a
# Claude-only mechanism works in one tool and silently misleads the other.
#
# The denylist is derived from agents/claude-only/ rather than hard-coded, so
# adding a subagent, workflow or command extends the check with no edit here.
# The scan runs first against fixture trees, to prove it catches violations
# and lets clean prose through, then against the real agents/skills/.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
DOTFILES_HOME="$(cd -P "$TEST_DIR/../.." && pwd)"

. "$DOTFILES_HOME/test/assert.sh"

# Claude-specific mechanisms no neutral skill may rely on, whatever
# agents/claude-only/ happens to contain.
FIXED_DENYLIST=(
	"claude -p"
	"/code-review"
	"/simplify"
	"AskUserQuestion"
	"subagent_type"
)

# skill_neutrality_denylist CLAUDE_ONLY_DIR
#
# Prints the denylist, one term per line: the fixed mechanisms above plus the
# name (basename without extension) of every entry under the subagents/,
# workflows/ and commands/ directories of CLAUDE_ONLY_DIR. A missing directory
# contributes nothing, and neither do dotfiles such as workflows/.gitkeep --
# stripped of its extension that would be an empty term, matching every line.
skill_neutrality_denylist() {
	local kind entry name
	printf '%s\n' "${FIXED_DENYLIST[@]}"
	for kind in subagents workflows commands; do
		[ -d "$1/$kind" ] || continue
		# The glob skips dotfiles; the -e test covers an empty directory, where
		# the unmatched pattern comes back literally.
		for entry in "$1/$kind"/*; do
			[ -e "$entry" ] || continue
			name="$(basename "$entry")"
			name="${name%.*}"
			[ -n "$name" ] && printf '%s\n' "$name"
		done
	done
}

# skill_neutrality_scan SKILLS_DIR CLAUDE_ONLY_DIR
#
# Scans every file under SKILLS_DIR (supporting files too, not just SKILL.md,
# since they are rendered as well) for the denylist from CLAUDE_ONLY_DIR.
# Prints `path:line: term` for each hit and returns 1 if there were any.
#
# A term matches only as a whole word, where a word character is a letter,
# digit, `_` or `-`. So `pj-review` doesn't match a denylisted `pj-reviewer`,
# and `pj-reviewer` doesn't match inside a longer name like
# `pj-reviewer-notes` -- which plain `grep -w` would allow, since it treats
# `-` as a boundary.
skill_neutrality_scan() {
	local skills_dir="$1" claude_only_dir="$2"
	local term escaped pattern match path rest hits=0

	if [ ! -d "$skills_dir" ]; then
		echo "skill_neutrality_scan: no such directory: $skills_dir" >&2
		return 2
	fi

	while IFS= read -r term; do
		escaped="$(printf '%s' "$term" | sed 's/[][\.*^$+?(){}|]/\\&/g')"
		pattern="(^|[^A-Za-z0-9_-])${escaped}(\$|[^A-Za-z0-9_-])"
		while IFS= read -r match; do
			path="${match%%:*}"
			rest="${match#*:}"
			printf '%s:%s: %s\n' "$path" "${rest%%:*}" "$term"
			hits=1
		done < <(grep -rnI -E -e "$pattern" "$skills_dir" || true)
	done < <(skill_neutrality_denylist "$claude_only_dir")

	[ "$hits" -eq 0 ]
}

fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

# make_fixture NAME -- an empty skills/ + claude-only/ pair; prints its root.
make_fixture() {
	mkdir -p "$fixture_root/$1/skills/demo" "$fixture_root/$1/claude-only/subagents"
	printf '%s\n' "$fixture_root/$1"
}

# scan FIXTURE_ROOT -- runs the scan from inside the fixture, so reported
# paths are relative (skills/demo/SKILL.md), and sets $out and $rc.
scan() {
	if out="$(cd "$1" && skill_neutrality_scan skills claude-only 2>&1)"; then rc=0; else rc=$?; fi
}

# --- a subagent from claude-only/ is denied by name ---

f="$(make_fixture subagent)"
printf -- '---\nname: helper-bot\n---\n' > "$f/claude-only/subagents/helper-bot.md"
printf '# Demo\n\nFirst line.\nHand the diff to helper-bot for a second look.\n' > "$f/skills/demo/SKILL.md"
scan "$f"
assert_exit_code 1 "$rc" "a skill naming a claude-only subagent fails the scan"
assert_contains "$out" "skills/demo/SKILL.md:4: helper-bot" "the failure names the file, line and term"

# --- each fixed Claude-specific mechanism is denied ---

n=0
for term in "${FIXED_DENYLIST[@]}"; do
	n=$((n + 1))
	f="$(make_fixture "fixed-$n")"
	printf '# Demo\n\nThen use %s here.\n' "$term" > "$f/skills/demo/SKILL.md"
	scan "$f"
	assert_exit_code 1 "$rc" "a skill using '$term' fails the scan"
	assert_contains "$out" "skills/demo/SKILL.md:3: $term" "the '$term' failure names the file, line and term"
done

# --- whole-word matching, and the generic idea of a sub-agent ---

f="$(make_fixture clean)"
printf -- '---\nname: pj-reviewer\n---\n' > "$f/claude-only/subagents/pj-reviewer.md"
mkdir -p "$f/claude-only/workflows"
: > "$f/claude-only/workflows/.gitkeep"
printf '# Demo\n\nRun pj-review afterwards. Sub-agents and subagents are fine to mention.\n' > "$f/skills/demo/SKILL.md"
scan "$f"
assert_exit_code 0 "$rc" "pj-review, sub-agents and a .gitkeep don't trip a pj-reviewer denylist"
assert_eq "" "$out" "a clean scan prints nothing"

# The fixture above can't fail under substring or `grep -w` matching, since
# `pj-reviewer` never appears in its text at all. These can: a denylisted
# name as the start of a longer word, and a dotted name whose `.` would match
# any character if it reached grep unescaped.
f="$(make_fixture prefix)"
printf -- '---\nname: helper-bot\n---\n' > "$f/claude-only/subagents/helper-bot.md"
printf -- '---\nname: helper.bot\n---\n' > "$f/claude-only/subagents/helper.bot.md"
printf '# Demo\n\nSome helper-bots.\nSee helper-bot-notes.\nNot a helperXbot.\n' > "$f/skills/demo/SKILL.md"
scan "$f"
assert_exit_code 0 "$rc" "a denylisted name inside a longer word, or a dotted name's regex reading, passes${out:+: $out}"

f="$(make_fixture dotted)"
printf -- '---\nname: helper.bot\n---\n' > "$f/claude-only/subagents/helper.bot.md"
printf '# Demo\n\nAsk `helper.bot`.\n' > "$f/skills/demo/SKILL.md"
scan "$f"
assert_exit_code 1 "$rc" "a dotted subagent name is still denied, literally"
assert_contains "$out" "skills/demo/SKILL.md:3: helper.bot" "the dotted-name failure names the file, line and term"

# --- workflows and commands contribute their names too ---

f="$(make_fixture layers)"
mkdir -p "$f/claude-only/workflows" "$f/claude-only/commands"
: > "$f/claude-only/workflows/review-sweep.js"
: > "$f/claude-only/commands/ship-it.md"
printf '# Demo\n\nStart review-sweep.\nThen ship-it.\n' > "$f/skills/demo/SKILL.md"
scan "$f"
assert_exit_code 1 "$rc" "names from workflows/ and commands/ are denied too"
assert_contains "$out" "skills/demo/SKILL.md:3: review-sweep" "a workflow name is reported"
assert_contains "$out" "skills/demo/SKILL.md:4: ship-it" "a command name is reported"

# --- supporting files are scanned, not just SKILL.md ---

f="$(make_fixture supporting)"
printf '# Demo\n\nNothing to see.\n' > "$f/skills/demo/SKILL.md"
mkdir -p "$f/skills/demo/reference"
printf 'Notes.\nAsk with AskUserQuestion.\n' > "$f/skills/demo/reference/notes.md"
scan "$f"
assert_exit_code 1 "$rc" "a denylisted term in a supporting file fails the scan"
assert_contains "$out" "skills/demo/reference/notes.md:2: AskUserQuestion" "the supporting-file failure names its path"

# --- the real tree ---

if out="$(cd "$DOTFILES_HOME" && skill_neutrality_scan agents/skills agents/claude-only 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "the real agents/skills/ tree is tool-neutral${out:+: $out}"

assert_report
