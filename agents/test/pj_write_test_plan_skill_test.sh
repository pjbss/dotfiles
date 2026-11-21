#!/bin/bash
# pj_write_test_plan_skill_test.sh
#
# Checks agents/skills/pj-write-test-plan/SKILL.md -- the QA test plan's
# template, its draft and finalize modes, and finalize's rule that test
# locations come only from what the reviews recorded -- plus the rewiring
# that makes the test plan the one place human-only checks go for planned
# work: pj-tdd files them there, and pj-review looks for them there.
#
# Prose assertions match against text with line breaks folded into spaces,
# so rewrapping a paragraph doesn't fail the test.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
DOTFILES_HOME="$(cd -P "$TEST_DIR/../.." && pwd)"

. "$DOTFILES_HOME/test/assert.sh"
. "$TEST_DIR/skill_doc.sh"

skills="$DOTFILES_HOME/agents/skills"
skill_dir="$skills/pj-write-test-plan"
skill="$skill_dir/SKILL.md"

if [ ! -f "$skill" ]; then
	echo "FAIL: $skill exists"
	echo "1 failure(s)"
	exit 1
fi

template="$(skill_template "$skill")"
process_flat="$(flatten "$(skill_prose "$skill")")"

template_line() { exact_line_number "$template" "$1"; }

# --- frontmatter, rendering, modes ---

assert_eq "---" "$(sed -n 1p "$skill")" "the skill opens with frontmatter"
assert_eq "name: pj-write-test-plan" "$(sed -n 2p "$skill")" "the frontmatter names the skill"
assert_ok "the frontmatter has a description" grep -q -E '^description: .{20,}' "$skill"
assert_eq "tags: [workflow, planning]" "$(sed -n 4p "$skill")" "the frontmatter tags it like the other planning skills"
assert_ok "dotfiles-sync-agents renders the skill for Claude Code and Copilot CLI" skill_renders "$skill_dir"
assert_ok "the skill has a Draft mode section" grep -q -x -F "## Draft mode" "$skill"
assert_ok "the skill has a Finalize mode section" grep -q -x -F "## Finalize mode" "$skill"

# --- draft mode ---

assert_contains "$process_flat" 'Its `Test plan:` header names the file' "draft writes the file the plan's header names"
assert_contains "$process_flat" 'writes it with `Status: draft`' "draft writes Status: draft"
assert_contains "$process_flat" 'every `AC-n.k` in the PRD has a row' "draft gives every criterion a Traceability row"
assert_contains "$process_flat" "a planned automated test or a manual case" "each criterion is covered by a planned test or a manual case"
assert_contains "$process_flat" 'one charter per `## Review focus` item' "charters are seeded from the plan's Review focus"

# --- finalize mode ---

assert_contains "$process_flat" 'only from the "tested by `file:line`" entries' \
	"finalize takes automated-test locations only from the reviews' tested-by entries"
assert_contains "$process_flat" '`issues/reviews/NNN-slug.md`' "finalize reads the per-layer review files"
assert_contains "$process_flat" '`git rev-parse <branch>` for every branch in the plan'"'"'s `## Stack` table' \
	"finalize records layer commits from git rev-parse of the plan's branches"
assert_contains "$process_flat" "Never invent a test location" "finalize never guesses a test location"
assert_contains "$process_flat" "stays blank and is listed under Known limitations" \
	"a criterion with no recorded test is listed under Known limitations"
assert_contains "$process_flat" '`Status: final (<today>)`' "finalize sets Status: final"
assert_contains "$process_flat" "If a branch doesn't resolve, don't finalize" \
	"finalize leaves the plan in draft when a layer branch doesn't resolve"
assert_contains "$process_flat" "no recorded test and no manual case stays blank" \
	"a manually covered criterion isn't listed as a limitation"

# --- template ---

assert_eq "# Test plan — <feature>" "$(printf '%s\n' "$template" | sed -n 1p)" "the template opens with its title"
for header in "Status: draft | final (YYYY-MM-DD)" "Plan: <path>" "Stack: <trunk> ← <layer branches…>"; do
	assert_ok "the template has the header line '$header'" test -n "$(template_line "$header")"
done

previous=0
for heading in "## 1. Scope" "## 2. Environment & preconditions" "## 3. Traceability" \
	"## 4. Manual test cases" "## 5. Exploratory charters" "## 6. Known limitations / not tested" \
	"## 7. Sign-off"; do
	line="$(template_line "$heading")"
	assert_ok "the template has '$heading' after the section before it" test "${line:-0}" -gt "$previous"
	previous="${line:-$previous}"
done

assert_ok "the Traceability table has the exact columns" \
	test -n "$(template_line "| Story | Criterion | Automated test | Manual |")"
assert_ok "manual cases are headed '### MT-n — <name>'" test -n "$(template_line "### MT-1 — <name>")"
assert_ok "a manual case names its source story and layer branch" grep -q -E '^Source: US-[0-9n]+ · Layer: ' <<<"$template"
assert_ok "a manual case has preconditions" grep -q -E '^Preconditions: ' <<<"$template"
assert_ok "a manual case has a step table" test -n "$(template_line "| # | Step | Expected |")"
assert_ok "a manual case has a result line" test -n "$(template_line "Result: ☐ pass ☐ fail · Notes:")"
assert_ok "charters are headed '### EC-n — Explore <area> with <resources> to discover <risk>'" \
	test -n "$(template_line "### EC-1 — Explore <area> with <resources> to discover <risk>")"
for field in "From: " "Timebox: " "Findings:"; do
	assert_ok "a charter has '$field'" grep -q -F -e "$field" <<<"$template"
done
assert_contains "$process_flat" '`MT-n` and `EC-n` numbering is per test plan, starting at 1 and append-only' \
	"MT/EC numbering is per test plan and append-only"

# --- rewiring: pj-tdd and pj-review agree on where a human-only check goes ---

tdd_flat="$(flatten "$(cat "$skills/pj-tdd/SKILL.md")")"
review_flat="$(flatten "$(cat "$skills/pj-review/SKILL.md")")"
rule='If the issue has a `## Plan section`, that is the test plan named by the `Test plan:` header of the plan it points at'
fallback='with no `## Plan section`, it is `issues/manual-tests.md`'
assert_contains "$tdd_flat" "$rule" "pj-tdd sends a human-only criterion to the issue's plan's test plan"
assert_contains "$tdd_flat" "$fallback" "pj-tdd falls back to issues/manual-tests.md without a plan"
assert_contains "$review_flat" "$rule" "pj-review looks for a moved criterion in the plan's test plan"
assert_contains "$review_flat" "$fallback" "pj-review looks in issues/manual-tests.md without a plan"

# --- README step 3 ---

readme_flat="$(flatten "$(cat "$DOTFILES_HOME/README")")"
assert_contains "$readme_flat" "collected in the test plan" "README step 3 collects human-only checks in the test plan"
assert_contains "$readme_flat" "the test plan is the checklist for step 5" "README step 3 makes the test plan step 5's checklist"

assert_report
