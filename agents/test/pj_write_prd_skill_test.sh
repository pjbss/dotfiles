#!/bin/bash
# pj_write_prd_skill_test.sh
#
# Checks the parts of agents/skills/pj-write-prd/SKILL.md that other tooling
# reads, not its prose. The `Status:` line is a convention pj-write-plan and
# the loop grep for, and the `US-n`/`AC-n.k` IDs are what plans, issues and
# the test plan cite -- so a reword that drops either breaks things
# downstream without any other test noticing.
#
# Prose assertions match against the file with line breaks folded into
# spaces, so rewrapping a paragraph doesn't fail the test.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
DOTFILES_HOME="$(cd -P "$TEST_DIR/../.." && pwd)"

. "$DOTFILES_HOME/test/assert.sh"

skill="$DOTFILES_HOME/agents/skills/pj-write-prd/SKILL.md"

# The PRD template: everything inside the ```markdown fence.
template="$(awk '/^```markdown$/ { inside = 1; next } inside && /^```$/ { exit } inside' "$skill")"
# The rest of the skill: its process and output sections.
process="$(awk '/^```markdown$/ { inside = 1; next } inside && /^```$/ { inside = 0; next } !inside' "$skill")"

flatten() { printf '%s' "$1" | tr '\n' ' ' | tr -s ' '; }
process_flat="$(flatten "$process")"
template_flat="$(flatten "$template")"

# heading_line HEADING -- line number of an exact heading in the template, or empty.
heading_line() { printf '%s\n' "$template" | { grep -n -x -F "$1" || true; } | cut -d: -f1; }

# --- Status line ---

assert_eq "Status: draft | approved (YYYY-MM-DD)" "$(printf '%s\n' "$template" | sed -n 1p)" \
	"the template begins with the Status line"
assert_contains "$process_flat" 'writes `Status: draft`' \
	"the process says the skill writes a draft"
assert_contains "$process_flat" '`Status: approved (<today>)` only after the human explicitly approves' \
	"the process switches to approved only on explicit human approval"
assert_contains "$process_flat" 'Editing an approved PRD sets it back to `Status: draft`' \
	"the process returns an edited approved PRD to draft"

# --- story and criterion IDs ---

assert_ok "the template numbers stories US-n" \
	grep -q -E '^- \*\*US-1\*\*: As a' <<<"$template"
assert_ok "the template nests AC-n.k criteria under their story" \
	grep -q -E '^  - \*\*AC-1\.1\*\*: ' <<<"$template"
assert_contains "$template_flat" "append, don't renumber" \
	"the template keeps the append-only numbering rule"
assert_contains "$template_flat" 'both `US-n` and `AC-n.k`' \
	"the append-only rule covers criteria as well as stories"

# --- section order ---

stories="$(heading_line '## User Stories')"
nfr="$(heading_line '## Non-functional Requirements')"
decisions="$(heading_line '## Implementation Decisions')"
assert_ok "the template has a Non-functional Requirements section" test -n "$nfr"
assert_ok "Non-functional Requirements comes after User Stories" test "${nfr:-0}" -gt "${stories:-0}"
assert_ok "Non-functional Requirements comes before Implementation Decisions" test "${nfr:-999999}" -lt "${decisions:-0}"

# --- naming ---

assert_contains "$process_flat" '`issues/prd-<name>.md`' \
	"the process names a second PRD issues/prd-<name>.md"
assert_not_ok "the process no longer offers a dated PRD file" \
	grep -q -w "dated" <<<"$process"

# --- README planning step ---

readme_step="$(grep -F '/pj-write-prd' "$DOTFILES_HOME/README")"
assert_contains "$readme_step" "approve" \
	"README step 3 describes the PRD as something the human approves"

assert_report
