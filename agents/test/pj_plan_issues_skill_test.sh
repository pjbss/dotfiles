#!/bin/bash
# pj_plan_issues_skill_test.sh
#
# Checks agents/skills/pj-plan-issues/SKILL.md now that it slices from an
# approved plan rather than a PRD: the approval gate, one issue per layer
# blocked only by the layer below, the `## Branch` / `## Plan section` forms
# that `pj-issues validate` and the loop's stack mode parse, and that
# human-only checks go to the plan's test plan instead of manual-tests.md.
#
# Prose assertions match against text with line breaks folded into spaces,
# so rewrapping a paragraph doesn't fail the test.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
DOTFILES_HOME="$(cd -P "$TEST_DIR/../.." && pwd)"

. "$DOTFILES_HOME/test/assert.sh"
. "$TEST_DIR/skill_doc.sh"

skill="$DOTFILES_HOME/agents/skills/pj-plan-issues/SKILL.md"

template="$(skill_template "$skill")"
process_flat="$(flatten "$(skill_prose "$skill")")"
whole_flat="$(flatten "$(cat "$skill")")"

template_line() { exact_line_number "$template" "$1"; }

# --- input: an approved plan, not a PRD ---

assert_contains "$process_flat" 'else `issues/plan.md`' "the plan defaults to issues/plan.md"
assert_contains "$process_flat" 'Unless it says `approved`, refuse' "the process refuses a plan that isn't approved"
assert_not_contains "$whole_flat" "Decompose the PRD" "the process no longer slices directly from a PRD"
assert_not_contains "$whole_flat" "Decomposes issues/prd.md" "the description no longer says it slices a PRD"

# --- one issue per layer, blocked only by the layer below ---

assert_contains "$process_flat" 'exactly one issue per `## Layer N` section' "the process cuts one issue per plan layer"
assert_contains "$process_flat" "numbered in layer order" "issues are numbered in layer order"
assert_contains "$process_flat" "names only the previous layer's issue" "Blocked by names only the layer below"

# --- template: Branch and Plan section after Parent PRD ---

parent="$(template_line "## Parent PRD")"
branch="$(template_line "## Branch")"
section="$(template_line "## Plan section")"
what="$(template_line "## What to build")"
assert_ok "the template has ## Branch after ## Parent PRD" test "${branch:-0}" -gt "${parent:-0}"
assert_ok "the template has ## Plan section after ## Branch" test "${section:-0}" -gt "${branch:-0}"
assert_ok "both come before ## What to build" test "${section:-999999}" -lt "${what:-0}"
assert_ok "the Branch section holds a bare branch name" test -n "$(template_line "<prefix>/NN-<slug>")"
assert_ok "the Plan section is '\`issues/plan[-name].md\` Layer N'" \
	test -n "$(template_line '`issues/plan.md` Layer N')"
assert_ok "acceptance criteria cite AC-n.k IDs" grep -q -E '^- \[ \] AC-[0-9n]+\.[0-9k]+' <<<"$template"
assert_ok "user stories addressed cite US-n" grep -q -E '^- US-[0-9nN]+' <<<"$template"

# --- human-only checks ---

assert_contains "$process_flat" 'the plan'"'"'s test plan' "human-only checks go to the plan's test plan"
assert_contains "$process_flat" '`pj-write-test-plan`' "the skill points at pj-write-test-plan"
assert_not_contains "$whole_flat" "manual-tests.md" "no issues/manual-tests.md instruction is left"
assert_not_contains "$whole_flat" "# Manual test plan" "the manual-tests template is gone"

# --- summary ---

assert_contains "$process_flat" "issue number, branch, slug" "the summary table has a Branch column"

# --- pj-write-prd now hands off to pj-write-plan ---

prd_flat="$(flatten "$(skill_prose "$DOTFILES_HOME/agents/skills/pj-write-prd/SKILL.md")")"
assert_contains "$prd_flat" 'Suggest `pj-write-plan` as the next step' "pj-write-prd suggests pj-write-plan next"

assert_report
