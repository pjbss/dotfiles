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
# Writes an unstacked issue file: the shape pj-plan-issues' template produced
# before issues were cut from plans (no `## Branch`), which must keep
# validating exactly as before. The stacked shape is `write_layer` below.
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

# --- document Status: and header lines (PRDs, plans, test plans) ---

docs="$fixture_root/docs"
mkdir -p "$docs"
printf 'Status: draft\n\n## Problem Statement\n' > "$docs/prd.md"
cat > "$docs/plan.md" <<-'PLAN'
	# Plan — widgets

	Status: approved (2026-11-20)
	PRD: issues/prd.md
	Test plan: issues/test-plan.md
	Trunk: main
	Branch prefix: widgets/

	## Goal

	Trunk: a later line with the same key, which must not win

	| 7 | not/the-stack | a table outside ## Stack | trunk | 1 |

	## Stack

	| # | Branch | Delivers | Depends on | ~non-test lines |
	|---|---|---|---|---|
	| 1 | widgets/01-parse | US-1 (AC-1.1) | trunk | 120 |
	| 2 | widgets/02-apply | US-2 (AC-2.1) | 1 | 520 (over ~400) |
	| 10 | widgets/10-late | US-3 | 2 | 40 |

	## Layer 1 — Parse

	Branch: widgets/01-parse
PLAN
printf '# Test plan — widgets\n\nStatus: final (2026-11-21)\nPlan: issues/plan.md\n' > "$docs/test-plan.md"
printf '## Problem Statement\n\nNo status line here.\n' > "$docs/untracked.md"

assert_eq "draft" "$(pj_issues_doc_status "$docs/prd.md")" "pj_issues_doc_status reads a PRD's line-1 Status"
assert_eq "approved" "$(pj_issues_doc_status "$docs/plan.md")" "pj_issues_doc_status finds a plan's Status below its title"
assert_eq "final" "$(pj_issues_doc_status "$docs/test-plan.md")" "pj_issues_doc_status reads a final test plan"
assert_eq "" "$(pj_issues_doc_status "$docs/untracked.md")" "pj_issues_doc_status is empty without a Status line"
assert_eq "main" "$(pj_issues_doc_header "$docs/plan.md" "Trunk")" "pj_issues_doc_header reads the first Trunk: line"
assert_eq "issues/test-plan.md" "$(pj_issues_doc_header "$docs/plan.md" "Test plan")" "pj_issues_doc_header reads a key containing a space"
assert_eq "" "$(pj_issues_doc_header "$docs/plan.md" "Owner")" "pj_issues_doc_header is empty for an absent key"
assert_eq "widgets/01-parse" "$(pj_issues_plan_layer_branch "$docs/plan.md" 1)" "pj_issues_plan_layer_branch reads row 1's branch"
assert_eq "widgets/02-apply" "$(pj_issues_plan_layer_branch "$docs/plan.md" 2)" "pj_issues_plan_layer_branch ignores an oversize note in another cell"
assert_eq "widgets/10-late" "$(pj_issues_plan_layer_branch "$docs/plan.md" 10)" "pj_issues_plan_layer_branch matches the whole layer number"
assert_eq "" "$(pj_issues_plan_layer_branch "$docs/plan.md" 3)" "pj_issues_plan_layer_branch is empty for a missing row"
assert_eq "" "$(pj_issues_plan_layer_branch "$docs/plan.md" 7)" "pj_issues_plan_layer_branch only reads the ## Stack table"

# --- an issue's stack fields ---

# write_layer DIR NAME BRANCH PLAN_REF LAYER BLOCKED_BY_BODY
#
# Writes an issue in the shape pj-plan-issues produces from a plan: the
# unstacked template plus `## Branch` and `## Plan section`.
write_layer() {
	mkdir -p "$1"
	cat > "$1/$2" <<-LAYER
		## Parent PRD

		\`issues/prd.md\`

		## Branch

		$3

		## Plan section

		\`$4\` Layer $5

		## What to build

		See the plan section.

		## Acceptance criteria

		- [ ] AC-$5.1 holds

		## Blocked by

		$6

		## User stories addressed

		- US-$5
	LAYER
}

fields="$fixture_root/fields"
write_layer "$fields" "004-parse.md" "w/01-parse" "issues/plan-widgets.md" 1 "None - can start immediately"
assert_eq "w/01-parse" "$(pj_issues_branch "$fields/004-parse.md")" "pj_issues_branch reads the bare branch"
assert_eq "issues/plan-widgets.md" "$(pj_issues_plan_ref "$fields/004-parse.md")" "pj_issues_plan_ref reads the plan path"
assert_eq "1" "$(pj_issues_plan_layer "$fields/004-parse.md")" "pj_issues_plan_layer reads the layer number"
assert_eq "" "$(pj_issues_branch "$clean/001-a.md")" "pj_issues_branch is empty for an unstacked issue"
assert_eq "" "$(pj_issues_plan_ref "$clean/001-a.md")" "pj_issues_plan_ref is empty for an unstacked issue"

# --- stack validation ---

# write_plan DIR NAME BRANCH... -- an approved plan whose Stack rows are the
# given branches, layer 1 first.
write_plan() {
	plan_dir="$1"
	plan_name="$2"
	shift 2
	mkdir -p "$plan_dir"
	{
		printf '# Plan — x\n\nStatus: approved (2026-11-20)\nTrunk: main\n\n## Stack\n\n'
		printf '| # | Branch | Delivers | Depends on | ~non-test lines |\n|---|---|---|---|---|\n'
		row=1
		for branch in "$@"; do
			depends=trunk
			[ "$row" -gt 1 ] && depends=$((row - 1))
			printf '| %s | %s | US-%s | %s | 100 |\n' "$row" "$branch" "$row" "$depends"
			row=$((row + 1))
		done
	} > "$plan_dir/$plan_name"
}

# stack_tree NAME -- a well-formed three-layer stack: plan plus issues
# 010/011/012 for layers 1/2/3, each blocked by the one below. Prints its dir.
stack_tree() {
	dir="$fixture_root/$1"
	write_plan "$dir" "plan.md" "w/01-a" "w/02-b" "w/03-c"
	write_layer "$dir" "010-a.md" "w/01-a" "issues/plan.md" 1 "None - can start immediately"
	write_layer "$dir" "011-b.md" "w/02-b" "issues/plan.md" 2 "- Blocked by \`issues/010-a.md\`"
	write_layer "$dir" "012-c.md" "w/03-c" "issues/plan.md" 3 "- Blocked by \`issues/011-b.md\`"
	printf '%s\n' "$dir"
}

# validate_stack DIR -- sets $out and $rc.
validate_stack() {
	if out="$(pj_issues_validate_stack "$1")"; then rc=0; else rc=$?; fi
}

validate_stack "$clean"
assert_exit_code 0 "$rc" "an unstacked tree passes stack validation untouched"
assert_eq "" "$out" "an unstacked tree gets no stack output"

tree="$(stack_tree stacked-ok)"
validate_stack "$tree"
assert_exit_code 0 "$rc" "a well-formed three-layer stack passes${out:+: $out}"

mkdir -p "$tree/done"
mv "$tree/010-a.md" "$tree/done/"
validate_stack "$tree"
assert_exit_code 0 "$rc" "a stack whose first layer is already done passes${out:+: $out}"

tree="$(stack_tree mixed)"
write_issue "$tree" "013-loose.md" "- Blocked by \`issues/012-c.md\`"
validate_stack "$tree"
assert_exit_code 1 "$rc" "an open issue with no branch beside stacked ones fails"
assert_contains "$out" "$tree/013-loose.md: no '## Branch'" "the unbranched issue is named"

tree="$(stack_tree two-plans)"
write_plan "$tree" "plan-other.md" "w/01-a" "w/02-b" "w/03-c"
write_layer "$tree" "012-c.md" "w/03-c" "issues/plan-other.md" 3 "- Blocked by \`issues/011-b.md\`"
validate_stack "$tree"
assert_exit_code 1 "$rc" "open issues naming two different plans fail"
assert_contains "$out" "$tree/012-c.md: names plan 'issues/plan-other.md'" "the issue naming the odd plan is named"

tree="$(stack_tree missing-plan)"
rm "$tree/plan.md"
validate_stack "$tree"
assert_exit_code 1 "$rc" "a stack whose plan doesn't exist fails"
assert_contains "$out" "$tree/010-a.md: plan 'issues/plan.md' doesn't exist" "the missing plan is reported against an issue"

tree="$(stack_tree duplicate-branch)"
write_plan "$tree" "plan.md" "w/01-a" "w/02-b" "w/02-b"
write_layer "$tree" "012-c.md" "w/02-b" "issues/plan.md" 3 "- Blocked by \`issues/011-b.md\`"
validate_stack "$tree"
assert_exit_code 1 "$rc" "a duplicate branch name fails"
assert_contains "$out" "$tree/012-c.md: branch 'w/02-b' is also used by $tree/011-b.md" "the duplicate is named with both issues"

tree="$(stack_tree done-duplicate)"
mkdir -p "$tree/done"
mv "$tree/010-a.md" "$tree/done/"
write_layer "$tree" "012-c.md" "w/01-a" "issues/plan.md" 3 "- Blocked by \`issues/011-b.md\`"
validate_stack "$tree"
assert_contains "$out" "branch 'w/01-a' is also used by $tree/done/010-a.md" "branch uniqueness spans the plan's done issues too"

tree="$(stack_tree two-blockers)"
write_layer "$tree" "012-c.md" "w/03-c" "issues/plan.md" 3 "$(printf -- '- Blocked by `issues/010-a.md`\n- Blocked by `issues/011-b.md`')"
validate_stack "$tree"
assert_exit_code 1 "$rc" "a stacked issue with two blockers fails"
assert_contains "$out" "$tree/012-c.md: blocked by 2 issues" "the issue with two blockers is named"

tree="$(stack_tree shared-blocker)"
write_layer "$tree" "012-c.md" "w/03-c" "issues/plan.md" 3 "- Blocked by \`issues/010-a.md\`"
validate_stack "$tree"
assert_exit_code 1 "$rc" "two stacked issues sharing a blocker fail"
assert_contains "$out" "$tree/012-c.md: shares its blocker '010-a.md' with $tree/011-b.md" "the shared blocker is named"

tree="$(stack_tree unblocked-middle)"
write_layer "$tree" "012-c.md" "w/03-c" "issues/plan.md" 3 "None - can start immediately"
validate_stack "$tree"
assert_exit_code 1 "$rc" "an unblocked issue above the lowest open layer fails"
assert_contains "$out" "$tree/012-c.md: only the lowest open layer" "the unblocked upper layer is named"

tree="$(stack_tree reversed-chain)"
write_layer "$tree" "011-b.md" "w/02-b" "issues/plan.md" 2 "- Blocked by \`issues/012-c.md\`"
write_layer "$tree" "012-c.md" "w/03-c" "issues/plan.md" 3 "- Blocked by \`issues/010-a.md\`"
validate_stack "$tree"
assert_exit_code 1 "$rc" "a chain that skips the layer below fails, even with no shared blocker"
assert_contains "$out" "$tree/012-c.md: blocked by '010-a.md', but the layer below it is '011-b.md'" "the out-of-order blocker is named"

tree="$(stack_tree branch-mismatch)"
write_layer "$tree" "011-b.md" "w/02-renamed" "issues/plan.md" 2 "- Blocked by \`issues/010-a.md\`"
validate_stack "$tree"
assert_exit_code 1 "$rc" "an issue branch that differs from its plan row fails"
assert_contains "$out" "$tree/011-b.md: branch 'w/02-renamed' differs from the plan's Stack row 2 ('w/02-b')" "the mismatch names both branches"

tree="$(stack_tree layer-order)"
write_layer "$tree" "011-b.md" "w/03-c" "issues/plan.md" 3 "- Blocked by \`issues/010-a.md\`"
write_layer "$tree" "012-c.md" "w/02-b" "issues/plan.md" 2 "- Blocked by \`issues/011-b.md\`"
validate_stack "$tree"
assert_exit_code 1 "$rc" "issue order disagreeing with layer order fails"
assert_contains "$out" "$tree/012-c.md: Layer 2 comes after Layer 3" "the out-of-order issue is named"

tree="$(stack_tree replanned)"
mkdir -p "$tree/done"
mv "$tree/010-a.md" "$tree/011-b.md" "$tree/012-c.md" "$tree/done/"
write_plan "$tree" "plan.md" "v/01-x" "v/02-y"
write_layer "$tree" "020-x.md" "v/01-x" "issues/plan.md" 1 "None - can start immediately"
write_layer "$tree" "021-y.md" "v/02-y" "issues/plan.md" 2 "- Blocked by \`issues/020-x.md\`"
validate_stack "$tree"
assert_exit_code 0 "$rc" "a plan replaced in place validates its new stack, whatever its done issues said${out:+: $out}"
write_layer "$tree" "021-y.md" "w/02-b" "issues/plan.md" 2 "- Blocked by \`issues/020-x.md\`"
write_plan "$tree" "plan.md" "v/01-x" "w/02-b"
validate_stack "$tree"
assert_contains "$out" "$tree/021-y.md: branch 'w/02-b' is also used by $tree/done/011-b.md" \
	"a replanned stack still can't reuse a done issue's branch, which already exists in git"

assert_eq "$fields/plan-widgets.md" "$(pj_issues_plan_file "$fields" "$fields/004-parse.md")" \
	"pj_issues_plan_file resolves an issue's plan to a path under the issues dir"
assert_eq "" "$(pj_issues_plan_file "$clean" "$clean/001-a.md")" "pj_issues_plan_file is empty for an unstacked issue"

tree="$(stack_tree missing-row)"
write_layer "$tree" "012-c.md" "w/04-d" "issues/plan.md" 4 "- Blocked by \`issues/011-b.md\`"
validate_stack "$tree"
assert_contains "$out" "$tree/012-c.md: the plan has no Stack row 4" "a layer with no Stack row is named"

assert_report
