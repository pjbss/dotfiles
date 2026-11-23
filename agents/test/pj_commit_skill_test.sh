#!/bin/bash
# pj_commit_skill_test.sh
#
# Checks agents/skills/pj-commit/SKILL.md's one exception to "one issue, one
# commit": a fix the whole-stack review asked for is an extra commit on an
# existing stack layer, with a `Review:` trailer naming the stack review in
# place of `Issue:`. The loop's fix phase asks for exactly that trailer, so
# the skill has to say how to write it.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
DOTFILES_HOME="$(cd -P "$TEST_DIR/../.." && pwd)"

. "$DOTFILES_HOME/test/assert.sh"
. "$TEST_DIR/skill_doc.sh"

skill="$DOTFILES_HOME/agents/skills/pj-commit/SKILL.md"
flat="$(flatten "$(cat "$skill")")"

assert_contains "$flat" "One issue, one commit" "the rule itself stays"
assert_contains "$flat" "The one exception is a stack-review fix" "the skill names its single exception"
assert_contains "$flat" "an additional commit on an existing stack layer" "a stack-review fix is an extra commit on an existing layer"
assert_contains "$flat" 'a `Review:` trailer naming the stack review instead of `Issue:`' "it carries a Review: trailer instead of Issue:"
assert_ok "the skill shows the Review: trailer's form" grep -q -x -F "Review: issues/reviews/stack.md" "$skill"
assert_contains "$flat" "Everything else in this skill applies to it unchanged" "the rest of the skill still applies"

assert_report
