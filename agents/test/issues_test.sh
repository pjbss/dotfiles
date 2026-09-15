#!/bin/bash
# issues_test.sh
#
# Unit tests for agents/lib/issues.sh -- the queryable view of the local
# `issues/` tree. Builds throwaway issue trees under a tmpdir rather than
# reading any real one: `issues/` is gitignored working state that may not
# exist at all in a given checkout, and the interesting cases here (a dangling
# blocker, a dependency cycle, a duplicate number) are exactly the ones a
# healthy real tree never contains.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
DOTFILES_HOME="$(cd -P "$TEST_DIR/../.." && pwd)"

. "$DOTFILES_HOME/test/assert.sh"
. "$DOTFILES_HOME/agents/lib/issues.sh"

fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

# write_issue DIR NAME BLOCKED_BY_BODY [CRITERIA_BODY]
#
# Writes an issue file in exactly the shape pj-plan-issues' template produces,
# so the parser is exercised against the real format rather than a simplified
# stand-in.
write_issue() {
	mkdir -p "$1"
	cat > "$1/$2" <<-EOF
		## Parent PRD

		\`issues/prd.md\`

		## What to build

		Something specific.

		## Acceptance criteria

		${4:-- [ ] It works}

		## Blocked by

		$3

		## User stories addressed

		- User story 1
	EOF
}

# --- number / issue-file recognition ---

assert_eq "007" "$(pj_issues_number "issues/007-do-a-thing.md")" "pj_issues_number reads the number out of an issue filename"
assert_eq "" "$(pj_issues_number "issues/prd.md")" "pj_issues_number ignores a PRD"
assert_eq "" "$(pj_issues_number "issues/prd-post-create.md")" "pj_issues_number ignores a named PRD"
assert_ok "pj_issues_is_issue_file accepts NNN-slug.md" pj_issues_is_issue_file "issues/012-x.md"
assert_not_ok "pj_issues_is_issue_file rejects a PRD" pj_issues_is_issue_file "issues/prd.md"

# --- blockers ---

tree="$fixture_root/basic"
write_issue "$tree" "001-first.md" "None - can start immediately"
write_issue "$tree" "002-second.md" "- Blocked by \`issues/001-first.md\`"
write_issue "$tree" "003-third.md" "$(printf -- '- Blocked by `issues/001-first.md`\n- Blocked by `issues/002-second.md`')"
write_issue "$tree" "prd.md" "None - can start immediately"

assert_eq "" "$(pj_issues_blockers "$tree/001-first.md")" "an unblocked issue reports no blockers"
assert_eq "001-first.md" "$(pj_issues_blockers "$tree/002-second.md")" "a single blocker is read out of the Blocked by section"
assert_eq "001-first.md 002-second.md" "$(pj_issues_blockers "$tree/003-third.md" | tr '\n' ' ' | sed 's/ $//')" "multiple blockers are all read"

# --- scanning excludes PRDs ---

assert_eq "001-first.md 002-second.md 003-third.md" \
	"$(pj_issues_scan "$tree" | xargs -n1 basename | tr '\n' ' ' | sed 's/ $//')" \
	"pj_issues_scan lists issue files in number order and excludes the PRD"

# --- state and readiness ---

assert_eq "ready" "$(pj_issues_state "$tree/001-first.md" "$tree")" "an issue with no blockers is ready"
assert_eq "blocked" "$(pj_issues_state "$tree/002-second.md" "$tree")" "an issue whose blocker is still open is blocked"
assert_eq "$tree/001-first.md" "$(pj_issues_next "$tree")" "next picks the lowest-numbered ready issue"

mkdir -p "$tree/done"
mv "$tree/001-first.md" "$tree/done/001-first.md"

assert_eq "done" "$(pj_issues_state "$tree/done/001-first.md" "$tree")" "an issue under done/ reports done"
assert_eq "ready" "$(pj_issues_state "$tree/002-second.md" "$tree")" "an issue becomes ready once its blocker is moved into done/"
assert_eq "blocked" "$(pj_issues_state "$tree/003-third.md" "$tree")" "an issue with one of two blockers done is still blocked"
assert_eq "$tree/002-second.md" "$(pj_issues_next "$tree")" "next advances as blockers are completed"

mv "$tree/002-second.md" "$tree/done/002-second.md"
assert_eq "$tree/003-third.md" "$(pj_issues_next "$tree")" "next reaches an issue once every blocker is done"

mv "$tree/003-third.md" "$tree/done/003-third.md"
assert_not_ok "pj_issues_next returns non-zero when nothing is ready" pj_issues_next "$tree"

# --- a blocker that names a file that doesn't exist ---

dangling="$fixture_root/dangling"
write_issue "$dangling" "001-only.md" "- Blocked by \`issues/099-nonexistent.md\`"

assert_eq "blocked" "$(pj_issues_state "$dangling/001-only.md" "$dangling")" "a blocker naming a nonexistent file leaves the issue blocked, not silently ready"
assert_not_ok "validate rejects a blocker pointing at a nonexistent issue" pj_issues_validate_file "$dangling/001-only.md" "$dangling"
assert_contains "$(pj_issues_validate_file "$dangling/001-only.md" "$dangling" || true)" \
	"doesn't exist" "validate says which blocker is missing"
assert_eq "" "$(pj_issues_find_cycle "$dangling")" "a dangling blocker is reported as a bad reference, not as a cycle"

# --- cycles ---

cyclic="$fixture_root/cyclic"
write_issue "$cyclic" "001-a.md" "- Blocked by \`issues/002-b.md\`"
write_issue "$cyclic" "002-b.md" "- Blocked by \`issues/001-a.md\`"
write_issue "$cyclic" "003-free.md" "None - can start immediately"

assert_eq "001-a.md 002-b.md" "$(pj_issues_find_cycle "$cyclic" | sort | tr '\n' ' ' | sed 's/ $//')" "both members of a two-issue cycle are reported"
assert_eq "$cyclic/003-free.md" "$(pj_issues_next "$cyclic")" "an unrelated issue stays workable alongside a cycle"

# --- structural validation ---

malformed="$fixture_root/malformed"
mkdir -p "$malformed"
printf '## What to build\n\nNo criteria, no blockers section.\n' > "$malformed/001-thin.md"

assert_not_ok "validate rejects an issue missing required sections" pj_issues_validate_file "$malformed/001-thin.md" "$malformed"
problems="$(pj_issues_validate_file "$malformed/001-thin.md" "$malformed" || true)"
assert_contains "$problems" "missing '## Acceptance criteria' section" "validate names the missing acceptance criteria section"
assert_contains "$problems" "missing '## Blocked by' section" "validate names the missing blocked-by section"

write_issue "$malformed" "002-no-criteria.md" "None - can start immediately" "(none yet)"
assert_contains "$(pj_issues_validate_file "$malformed/002-no-criteria.md" "$malformed" || true)" \
	"no acceptance criteria" "validate rejects an issue with an empty criteria list"

# --- unchecked criteria on a done issue ---

sloppy="$fixture_root/sloppy"
write_issue "$sloppy/done" "001-half.md" "None - can start immediately" "$(printf -- '- [x] Did this\n- [ ] Never did this')"

assert_eq "Never did this" "$(pj_issues_unchecked_criteria "$sloppy/done/001-half.md")" "unchecked criteria are listed"
assert_not_ok "validate rejects a done issue with unchecked criteria" pj_issues_validate_file "$sloppy/done/001-half.md" "$sloppy"

# --- a well-formed tree validates clean ---

clean="$fixture_root/clean"
write_issue "$clean" "001-a.md" "None - can start immediately" "- [ ] Works"
write_issue "$clean" "002-b.md" "- Blocked by \`issues/001-a.md\`" "- [ ] Also works"
assert_ok "validate accepts a well-formed issue" pj_issues_validate_file "$clean/001-a.md" "$clean"
assert_ok "validate accepts an issue whose blocker exists and is still open" pj_issues_validate_file "$clean/002-b.md" "$clean"
assert_eq "" "$(pj_issues_find_cycle "$clean")" "a well-formed tree has no cycle"

assert_report
