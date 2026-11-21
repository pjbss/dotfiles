#!/bin/bash
# pj_write_plan_skill_test.sh
#
# Checks agents/skills/pj-write-plan/SKILL.md: the plan template's header
# lines and headings (pj-plan-issues and the loop parse `Status:`, `Trunk:`,
# `Test plan:`, the `## Stack` table and `## Layer N` sections), the approval
# gate, the naming rule, and the self-checks the skill promises to run. Also
# that the skill renders like any other.
#
# Prose assertions match against the file with line breaks folded into
# spaces, so rewrapping a paragraph doesn't fail the test.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
DOTFILES_HOME="$(cd -P "$TEST_DIR/../.." && pwd)"

. "$DOTFILES_HOME/test/assert.sh"

skill_dir="$DOTFILES_HOME/agents/skills/pj-write-plan"
skill="$skill_dir/SKILL.md"

if [ ! -f "$skill" ]; then
	echo "FAIL: $skill exists"
	echo "1 failure(s)"
	exit 1
fi

# The plan template: everything inside the ```markdown fence.
template="$(awk '/^```markdown$/ { inside = 1; next } inside && /^```$/ { exit } inside' "$skill")"
# The rest of the skill: frontmatter, process, self-checks, output.
process="$(awk '/^```markdown$/ { inside = 1; next } inside && /^```$/ { inside = 0; next } !inside' "$skill")"

flatten() { printf '%s' "$1" | tr '\n' ' ' | tr -s ' '; }
process_flat="$(flatten "$process")"

# template_line TEXT -- line number of an exact line in the template, or empty.
template_line() { printf '%s\n' "$template" | { grep -n -x -F "$1" || true; } | head -1 | cut -d: -f1; }

# --- frontmatter, and rendering ---

assert_eq "---" "$(sed -n 1p "$skill")" "the skill opens with frontmatter"
assert_eq "name: pj-write-plan" "$(sed -n 2p "$skill")" "the frontmatter names the skill"
assert_ok "the frontmatter has a description" grep -q -E '^description: .{20,}' "$skill"
assert_eq "tags: [workflow, planning]" "$(sed -n 4p "$skill")" "the frontmatter tags it like the other planning skills"

fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT
mkdir -p "$fixture_root/dotfiles/bin" "$fixture_root/dotfiles/agents/skills" "$fixture_root/home/.claude"
cp "$DOTFILES_HOME/bin/dotfiles-sync-agents" "$fixture_root/dotfiles/bin/"
cp -R "$skill_dir" "$fixture_root/dotfiles/agents/skills/"
if HOME="$fixture_root/home" COPILOT_HOME="$fixture_root/home/.copilot" \
	"$fixture_root/dotfiles/bin/dotfiles-sync-agents" >/dev/null 2>&1; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "dotfiles-sync-agents renders the skill"
assert_ok "the skill is rendered for Claude Code" test -f "$fixture_root/home/.claude/skills/pj-write-plan/SKILL.md"
assert_ok "the skill is rendered for Copilot CLI" test -f "$fixture_root/home/.copilot/skills/pj-write-plan/SKILL.md"

# --- input and approval gate ---

assert_contains "$process_flat" 'else `issues/prd.md`' "the PRD defaults to issues/prd.md"
assert_contains "$process_flat" 'Unless it says `approved`, refuse' "the process refuses a PRD that isn't approved"
assert_contains "$process_flat" 'writes `Status: draft`' "the process writes a draft plan"
assert_contains "$process_flat" '`Status: approved (<today>)` only after the human explicitly approves' \
	"the process approves the plan only on explicit human approval"
assert_contains "$process_flat" 'Editing an approved plan sets it back to `Status: draft`' \
	"the process returns an edited approved plan to draft"

# --- naming ---

assert_contains "$process_flat" '`prd.md` → `issues/plan.md`' "prd.md gives issues/plan.md"
assert_contains "$process_flat" '`prd-<name>.md` → `issues/plan-<name>.md`' "prd-<name>.md gives issues/plan-<name>.md"
assert_contains "$process_flat" '`issues/test-plan.md`' "the test plan is issues/test-plan.md for prd.md"
assert_contains "$process_flat" '`issues/test-plan-<name>.md`' "the test plan is issues/test-plan-<name>.md for prd-<name>.md"
assert_contains "$process_flat" "read it and ask before replacing it" "an existing plan isn't silently replaced"
assert_contains "$process_flat" 'Suggest `pj-plan-issues` as the next step' "the next step is pj-plan-issues"

# --- template: header lines ---

for header in \
	"Status: draft | approved (YYYY-MM-DD)" \
	"PRD: <path>" \
	"Test plan: <path>" \
	"Trunk: <branch>" \
	"Branch prefix: <prefix>/"; do
	assert_ok "the template has the header line '$header'" test -n "$(template_line "$header")"
done
assert_contains "$process_flat" "with a bare value, no backticks" \
	"header values are bare, so the loop can compare Trunk: to a branch name"

# --- template: sections, in order ---

previous=0
for heading in "## Goal" "## Architecture" "## Interfaces" "## Data models" "## Data flow" \
	"## Global constraints" "## Review focus" "## Stack" "## Layer 1 — <name>"; do
	line="$(template_line "$heading")"
	assert_ok "the template has '$heading' after the section before it" test "${line:-0}" -gt "$previous"
	previous="${line:-$previous}"
done

# --- template: Stack table and layer blocks ---

assert_ok "the Stack table has the exact columns" \
	test -n "$(template_line "| # | Branch | Delivers | Depends on | ~non-test lines |")"
assert_ok "Stack row 1 has a bare branch, US/AC IDs, and depends on trunk" \
	grep -q -E '^\| 1 \| <prefix>/01-<slug> \| US-[0-9]+ \(AC-[0-9]+\.[0-9]+.*\) \| trunk \| [0-9]+ \|$' <<<"$template"
assert_ok "Stack row 2 depends on layer 1" \
	grep -q -E '^\| 2 \| <prefix>/02-<slug> \| .* \| 1 \| [0-9]+' <<<"$template"
assert_ok "the layer block's Branch: line matches its Stack row" \
	test -n "$(template_line "Branch: <prefix>/01-<slug>")"
for field in "Stands alone because:" "Files:" "- Create:" "- Modify:" "- Test:" "Interfaces:" \
	"Data touched:" "Tests (exact assertions):" "New pattern" "Done when: AC-" "Manual: "; do
	assert_ok "the layer block has '$field'" grep -q -F -e "$field" <<<"$template"
done

# --- self-checks ---

assert_contains "$process_flat" "names the new pattern it demonstrates" "self-check: every snippet names its new pattern"
assert_contains "$process_flat" "replace it with a \`file:line\` reference" "self-check: otherwise cite the existing example"
assert_contains "$process_flat" "Layer N depends only on layer N−1" "self-check: the dependency chain is linear"
assert_contains "$process_flat" "pass the test suite on its own" "self-check: each layer passes the suite alone"
assert_contains "$process_flat" "smallest unit with its own test cycle" "self-check: layer granularity"
assert_contains "$process_flat" "~400 changed non-test lines" "self-check: the size threshold"
assert_contains "$process_flat" "a flag, not a refusal" "self-check: an oversized layer is flagged, not refused"
assert_contains "$process_flat" "shared foundations sit at the bottom" "self-check: foundations first"
assert_contains "$process_flat" "Setup, scaffolding and docs fold into the layer that needs them" \
	"self-check: setup and docs don't get layers of their own"
assert_contains "$process_flat" "in the summary given to the human" "self-check: an oversized layer is named in the summary"
assert_contains "$process_flat" "name any layer flagged as oversized" "the approval step names oversized layers"
assert_contains "$process_flat" "most of the document" "self-check: a code-heavy plan is cut back"
assert_contains "$process_flat" "replace bodies with signatures and assertions" "self-check: ... to signatures and assertions"

# --- README planning step ---

readme="$DOTFILES_HOME/README"
prd_line="$({ grep -n -F '/pj-write-prd ' "$readme" || true; } | head -1 | cut -d: -f1)"
plan_line="$({ grep -n -F '/pj-write-plan ' "$readme" || true; } | head -1 | cut -d: -f1)"
issues_line="$({ grep -n -F '/pj-plan-issues ' "$readme" || true; } | head -1 | cut -d: -f1)"
assert_ok "README step 3 lists /pj-write-plan after /pj-write-prd" test "${plan_line:-0}" -gt "${prd_line:-0}"
assert_ok "README step 3 lists /pj-write-plan before /pj-plan-issues" test "${plan_line:-999999}" -lt "${issues_line:-0}"

assert_report
