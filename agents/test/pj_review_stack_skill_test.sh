#!/bin/bash
# pj_review_stack_skill_test.sh
#
# Checks agents/skills/pj-review-stack/SKILL.md, the whole-stack review the
# loop runs once a stacked run has drained its queue. The loop parses its
# verdict file's first line and name, and issue 041's fix pass reads each
# finding's `Layer:` line to know which branch to fix -- so those are pinned,
# along with the inputs, the five checks per-layer review can't make, and the
# rule that every carried-over note is accounted for.
#
# Prose assertions match against text with line breaks folded into spaces,
# so rewrapping a paragraph doesn't fail the test.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
DOTFILES_HOME="$(cd -P "$TEST_DIR/../.." && pwd)"

. "$DOTFILES_HOME/test/assert.sh"
. "$TEST_DIR/skill_doc.sh"

skill_dir="$DOTFILES_HOME/agents/skills/pj-review-stack"
skill="$skill_dir/SKILL.md"

if [ ! -f "$skill" ]; then
	echo "FAIL: $skill exists"
	echo "1 failure(s)"
	exit 1
fi

flat="$(flatten "$(cat "$skill")")"
template="$(skill_template "$skill")"

# --- frontmatter ---

assert_eq "---" "$(sed -n 1p "$skill")" "the skill opens with frontmatter"
assert_eq "name: pj-review-stack" "$(sed -n 2p "$skill")" "the frontmatter names the skill"
assert_ok "the frontmatter has a description" grep -q -E '^description: .{20,}' "$skill"
assert_eq "tags: [workflow, review]" "$(sed -n 4p "$skill")" "the frontmatter tags it like the other review skills"
assert_ok "dotfiles-sync-agents renders the skill for both tools" skill_renders "$skill_dir"

# --- inputs ---

for input in "the PRD" '`## Review focus`' '`## Interfaces`' "the draft test plan" \
	'`.quality.md`' '`[note]` findings' '`git diff <trunk>...<top>`' '`git log`'; do
	assert_contains "$flat" "$input" "the inputs include $input"
done

# --- the five checks ---

for check in "**Cross-layer correctness**" "**Whole-diff simplicity**" "**Layer integrity**" \
	"**Carried-over notes**" "**PRD decisions and Out of Scope**"; do
	assert_contains "$flat" "$check" "the skill makes the check $check"
done
assert_contains "$flat" "interfaces honoured at the seams" "cross-layer correctness checks the plan's interfaces at the seams"
assert_contains "$flat" "duplication across layers" "simplicity looks across layers"
assert_contains "$flat" "makes sense as its own pull request" "layer integrity asks whether each layer stands alone"

# --- output ---

assert_contains "$flat" '`issues/reviews/stack.md`' "the verdict file is issues/reviews/stack.md for plan.md"
assert_contains "$flat" '`issues/reviews/stack-<name>.md`' "and stack-<name>.md for plan-<name>.md"
assert_ok "the output starts with Verdict: approved" grep -q -x -F "Verdict: approved" "$skill"
assert_ok "... or Verdict: changes-requested" grep -q -x -F "Verdict: changes-requested" "$skill"
assert_contains "$flat" 'severities defined in `pj-review`' "findings use pj-review's severities"
assert_contains "$flat" '`changes-requested` exactly when at least one finding is `[blocking]`' "the verdict follows the blocking rule"
assert_ok "every finding in the template has a severity label" grep -q -E '^1\. \*\*\[(blocking|note|pre-existing)\] ' <<<"$template"
assert_ok "every finding in the template names its owning layer" grep -q -E '^   Layer: <prefix>/NN-<slug>$' <<<"$template"
assert_contains "$flat" 'a `Layer: <branch>` line' "the skill requires the Layer: line on every finding"
assert_contains "$flat" 'exactly `Layer: <branch>`: the bare branch name from the Stack table, without backticks, on the line after the finding'"'"'s label' \
	"the Layer: line's exact form is pinned, since the fix pass parses it"

# --- carried-over notes ---

assert_contains "$flat" 'every carried-over `[note]`' "every carried-over note must be accounted for"
assert_ok "the template reports a note as fixed" grep -q -F -e "fixed" <<<"$template"
assert_ok "the template reports a note as accepted with a reason" grep -q -F -e "accepted: <reason>" <<<"$template"

assert_report
