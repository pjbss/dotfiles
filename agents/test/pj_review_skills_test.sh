#!/bin/bash
# pj_review_skills_test.sh
#
# Checks the two review lenses: agents/skills/pj-review/SKILL.md (spec and
# correctness) and agents/skills/pj-review-quality/SKILL.md (code quality).
# The loop parses both verdict files' first line, so that line and the output
# paths are pinned; so is the triage that decides it -- defined once, in
# pj-review, and referred to by pj-review-quality rather than restated, so
# the two can't drift apart.
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
review="$skills/pj-review/SKILL.md"
quality_dir="$skills/pj-review-quality"
quality="$quality_dir/SKILL.md"

if [ ! -f "$quality" ]; then
	echo "FAIL: $quality exists"
	echo "1 failure(s)"
	exit 1
fi

review_flat="$(flatten "$(cat "$review")")"
review_template="$(skill_template "$review")"
quality_flat="$(flatten "$(cat "$quality")")"
quality_template="$(skill_template "$quality")"

# --- pj-review-quality: frontmatter, inputs, checklist ---

assert_eq "---" "$(sed -n 1p "$quality")" "pj-review-quality opens with frontmatter"
assert_eq "name: pj-review-quality" "$(sed -n 2p "$quality")" "the frontmatter names the skill"
assert_ok "the frontmatter has a description" grep -q -E '^description: .{20,}' "$quality"
assert_eq "tags: [workflow, review]" "$(sed -n 4p "$quality")" "the frontmatter tags it like pj-review"
assert_ok "dotfiles-sync-agents renders pj-review-quality for both tools" skill_renders "$quality_dir"

assert_contains "$quality_flat" '`git diff --cached`' "the staged change is an input"
assert_contains "$quality_flat" "a given commit range" "a commit range is an input"
assert_contains "$quality_flat" "Read the code around the change, not just the diff" "the reviewer reads the surrounding code"
for item in "Readability" "Simplicity" "Reuse" "Consistency" "Dead code and debug leftovers" "Test readability"; do
	assert_contains "$quality_flat" "**$item**" "the checklist covers $item"
done
assert_contains "$quality_flat" '`has_test_target`' "the reuse item names the model case"
assert_contains "$quality_flat" "Every finding names the concrete simpler alternative" "every finding must name a simpler alternative"
assert_contains "$quality_flat" "Don't propose new abstractions" "the reviewer doesn't propose abstractions"
assert_contains "$quality_flat" '"No findings" is a valid and expected outcome' "no findings is an expected outcome"

# --- pj-review-quality: output ---

assert_contains "$quality_flat" '`issues/reviews/NNN-slug.quality.md`' "the quality verdict file is NNN-slug.quality.md"
assert_ok "the quality output starts with the same Verdict: approved line" grep -q -x -F "Verdict: approved" "$quality"
assert_ok "... or Verdict: changes-requested" grep -q -x -F "Verdict: changes-requested" "$quality"
assert_ok "the quality template has ## Reviewed" test -n "$(exact_line_number "$quality_template" "## Reviewed")"
assert_ok "the quality template has ## Findings" test -n "$(exact_line_number "$quality_template" "## Findings")"

# --- triage: defined once, in pj-review ---

for severity in blocking note pre-existing; do
	assert_contains "$review_flat" "- **\`[$severity]\`**" "pj-review defines the [$severity] severity"
done
assert_contains "$review_flat" 'The verdict is `changes-requested` exactly when at least one finding is `[blocking]`' \
	"pj-review states the changes-requested-iff-blocking rule"
assert_contains "$review_flat" 'a failing or unrun `make test`' "an unrun suite still blocks, as before triage"
assert_contains "$review_flat" "A problem this change caused is never \`[pre-existing]\`" "a problem the change caused is never pre-existing"
assert_contains "$quality_flat" 'severities defined in `pj-review`' "pj-review-quality refers to pj-review's severities"
assert_not_contains "$quality_flat" "real but minor" "pj-review-quality doesn't restate the note definition"
assert_not_contains "$quality_flat" "not caused by this change" "pj-review-quality doesn't restate the pre-existing definition"

# --- both output templates show the [severity] label ---

assert_ok "pj-review's template shows a [severity] label" \
	grep -q -E '^1\. \*\*\[(blocking|note|pre-existing)\] ' <<<"$review_template"
assert_ok "pj-review-quality's template shows a [severity] label" \
	grep -q -E '^1\. \*\*\[(blocking|note|pre-existing)\] ' <<<"$quality_template"

# --- pj-review: Fit moves out, the revert check comes in ---

assert_not_contains "$review_flat" "**Fit**" "pj-review no longer has the Fit bullet"
assert_not_contains "$review_flat" "Style preferences alone" "pj-review no longer has the style-preferences paragraph"
assert_not_contains "$review_flat" 'Use `changes-requested` for:' "the old changes-requested list is replaced by triage"
assert_contains "$review_flat" "would it fail if the implementation were reverted?" "pj-review asks whether each test would fail on a revert"
assert_contains "$review_flat" "break the implementation in a scratch copy, run the test" "pj-review demonstrates it where cheap and safe"

assert_report
