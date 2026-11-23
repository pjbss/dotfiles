#!/bin/bash
# pj_run_issues_test.sh
#
# End-to-end tests for bin/pj-run-issues, the autonomous loop, with `claude`
# replaced by a stub on PATH. That substitution is what makes the orchestration
# testable at all: the loop's job is deciding what to run, when to stop, and
# what state to leave behind, and none of that needs a real model.
#
# The refusals get as much attention as the happy path. An unattended loop that
# keeps going after something went wrong is worse than one that never ran --
# it buries the failure under later commits.
#
# Everything happens in a throwaway git repo under a tmpdir; $HOME is untouched
# and $PJ_SANDBOX_MARKER stands in for /etc/pj-sandbox.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
DOTFILES_HOME="$(cd -P "$TEST_DIR/../.." && pwd)"

. "$DOTFILES_HOME/test/assert.sh"

# The loop exports PJ_RUN_ISSUES=1 to its children, and the tests below assert
# that. Inherited from an outer loop (this suite runs as the gate of one), it
# would make those assertions pass whether or not this loop exported it.
unset PJ_RUN_ISSUES

RUN_ISSUES="$DOTFILES_HOME/bin/pj-run-issues"

fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

marker="$fixture_root/sandbox-marker"
printf 'marker\n' > "$marker"

stub_bin="$fixture_root/stub-bin"
mkdir -p "$stub_bin"

# A stub `claude` that performs the mechanical part of what each prompt asks
# for. $STUB_MODE steers it so each scenario below can be driven without a
# model: "normal" completes the issue, "partial" leaves it in issues/ the way
# pj-tdd does for a human-only criterion, "nochanges" closes the issue without
# touching anything, and "eagercommit" commits despite being told not to.
cat > "$stub_bin/claude" <<'STUB'
#!/bin/sh
set -eu
prompt=""
stream=""
while [ $# -gt 0 ]; do
	case "$1" in
		-p) prompt="${2:-}"; shift 2 ;;
		--output-format)
			[ "${2:-}" = "stream-json" ] && stream=1
			shift 2 ;;
		*) shift ;;
	esac
done

# say_stub TEXT -- one unit of output in whichever format the loop asked for.
#
# The streaming form is a real, if minimal, stream-json transcript: session
# noise the renderer must drop, a tool call, a subagent's nested tool call, the
# agent's own words, and a result. Emitting the real shape is what makes these
# tests exercise the renderer rather than route around it.
say_stub() {
	if [ -z "$stream" ]; then
		printf '%s\n' "$1"
		return
	fi
	printf '%s\n' '{"type":"system","subtype":"init","cwd":"/workspace"}'
	printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_stub","name":"Bash","input":{"command":"make test"}}]},"parent_tool_use_id":null}'
	printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_nested","name":"Read","input":{"file_path":"issues/prd.md"}}]},"parent_tool_use_id":"toolu_stub"}'
	printf '{"type":"assistant","message":{"content":[{"type":"text","text":"%s"}]},"parent_tool_use_id":null}\n' "$1"
	printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":1234,"total_cost_usd":0.01}'
}

# Matched on the bare NNN-slug.md, not on a leading `issues/`, because the
# prompts refer to the same issue by several paths: issues/NNN-x.md when
# implementing, issues/done/NNN-x.md when reviewing.
issue_name="$(printf '%s' "$prompt" | grep -o '[0-9][0-9][0-9]-[A-Za-z0-9._-]*\.md' | head -1)"
issue_file="issues/$issue_name"

# One line per invocation, whatever it was asked to do, when a test wants to
# check that every call path -- not just the implementing one -- got the same
# environment. Kept outside the repo so it never becomes part of the work.
if [ -n "${STUB_ENV_LOG:-}" ]; then
	case "$prompt" in
		*"pj-review-stack skill"*) call=stack ;;
		*"requested changes in stack layer"*) call=stackfix ;;
		*"pj-review-quality skill"*) call=quality ;;
		*"pj-review skill"*) call=review ;;
		*"pj-commit skill"*) call=commit ;;
		*"requested changes to your"*) call=remediate ;;
		*"pj-tdd skill"*) call=tdd ;;
		*) call=other ;;
	esac
	printf '%s PJ_TEST_DIR=%s PJ_TEST_CMD=%s PJ_PROJECT_ROOT=%s PJ_RUN_ISSUES=%s\n' "$call" \
		"${PJ_TEST_DIR:-unset}" "${PJ_TEST_CMD:-unset}" "${PJ_PROJECT_ROOT:-unset}" "${PJ_RUN_ISSUES:-unset}" \
		>> "$STUB_ENV_LOG"
fi

# Every prompt, in full, for a test that wants to check what none of them say.
if [ -n "${STUB_PROMPT_LOG:-}" ]; then
	printf '%s\n' "$prompt" >> "$STUB_PROMPT_LOG"
fi

# next_verdict KIND LIST -- the Nth word of LIST on this run's Nth KIND
# review, and the last word once the list runs out, so a test can script how
# successive attempts go. Counted in the repo's git dir: outside the work, and
# fresh for every test's new repo.
next_verdict() {
	count_file="$(git rev-parse --absolute-git-dir)/stub-$1.count"
	n=$(($(cat "$count_file" 2>/dev/null || echo 0) + 1))
	echo "$n" > "$count_file"
	set -- $2
	[ "$n" -le $# ] || n=$#
	eval "printf '%s' \"\${$n}\""
}

case "$prompt" in
	*"pj-review-stack skill"*)
		stack_file="$(printf '%s' "$prompt" | grep -o 'issues/reviews/stack[A-Za-z0-9._-]*\.md' | head -1)"
		verdict="$(next_verdict stack "${STUB_STACK_VERDICTS:-${STUB_STACK_VERDICT:-approved}}")"
		# The findings' shape. By default a blocking finding for each of
		# layers 2 and 1 -- layer 2 listed first, so a fix order that followed
		# the file instead of the stack would show -- plus a note. nolayer and
		# unknown add a bad-owner blocking finding beside a valid layer-1 one,
		# so skipping the owner check would visibly fix layer 1 anyway. none:
		# changes requested with no blocking finding at all. notes: an approval
		# carrying only a note.
		layer1='STUB_FIX_LAYER1** -- `src/stub.sh:9`
   Layer: w/01-slice
   STUB_DETAIL_LAYER1'
		case "$verdict:${STUB_STACK_FINDINGS:-}" in
			approved:notes) findings='1. **[note] STUB_STACK_NOTE** -- `src/stub.sh:3`
   Layer: w/02-slice
   a note, not a blocker' ;;
			approved:*) findings='None.' ;;
			*:nolayer) findings="1. **[blocking] STUB_ORPHAN_FINDING** -- \`src/stub.sh:5\`
   no owner named
2. **[blocking] $layer1" ;;
			*:unknown) findings="1. **[blocking] STUB_UNKNOWN_LAYER** -- \`src/stub.sh:5\`
   Layer: w/99-missing
   names a branch the stack does not have
2. **[blocking] $layer1" ;;
			*:none) findings='1. **[note] STUB_STACK_NOTE** -- `src/stub.sh:3`
   Layer: w/02-slice
   a note, not a blocker' ;;
			*) findings="1. **[blocking] STUB_FIX_LAYER2** -- \`src/stub.sh:12\`
   Layer: w/02-slice
   STUB_DETAIL_LAYER2
2. **[note] STUB_STACK_NOTE** -- \`src/stub.sh:3\`
   Layer: w/02-slice
   a note, not a blocker
3. **[blocking] $layer1" ;;
		esac
		if [ "${STUB_STACK_MODE:-}" != nofile ]; then
			mkdir -p issues/reviews
			cat > "$stack_file" <<VERDICT
Verdict: $verdict

## Reviewed

stub stack review

## Findings

$findings

## Carried-over notes

None.
VERDICT
		fi
		say_stub "stub: reviewed the stack -> $verdict"
		;;

	*"requested changes in stack layer"*)
		branch="$(printf '%s' "$prompt" | grep -o 'w/[0-9][0-9]-[a-z-]*' | head -1)"
		if [ -n "${STUB_FIX_LOG_DIR:-}" ]; then
			printf '%s\n' "$prompt" > "$STUB_FIX_LOG_DIR/$(printf '%s' "$branch" | tr / _).prompt"
			printf '%s\n' "$branch" >> "$STUB_FIX_LOG_DIR/order"
		fi
		# conflict: layer 1's fix writes the file layer 2's own commit adds,
		# so rebasing layer 2 onto it conflicts for real.
		if [ "${STUB_FIX_MODE:-}" = conflict ] && [ "$branch" = w/01-slice ]; then
			echo "a conflicting fix" > stub-work-002-slice.txt
		else
			echo "fixed" >> "stub-fix-$(printf '%s' "$branch" | tr / _).txt"
		fi
		# eagercommit: the fixer commits despite being told not to.
		if [ "${STUB_FIX_MODE:-}" = eagercommit ]; then
			git add -A
			git commit -q -m "Premature fix on $branch"
		fi
		say_stub "stub: fixed $branch"
		;;

	*"pj-review-quality skill"*)
		verdict="$(next_verdict quality "${STUB_QUALITY_VERDICTS:-approved}")"
		# nofile never writes the verdict; firstonly writes it on the first
		# quality review only, so a later attempt finds just the stale one.
		quality_call="$(cat "$(git rev-parse --absolute-git-dir)/stub-quality.count")"
		case "${STUB_QUALITY_MODE:-}" in
			nofile) write_quality="" ;;
			firstonly) write_quality="$([ "$quality_call" -eq 1 ] && echo 1 || true)" ;;
			*) write_quality=1 ;;
		esac
		if [ -n "$write_quality" ]; then
			mkdir -p issues/reviews
			cat > "issues/reviews/${issue_name%.md}.quality.md" <<VERDICT
Verdict: $verdict

## Reviewed

\`issues/$issue_name\`

## Findings

1. **[blocking] STUB_QUALITY_FINDING_LABEL** -- \`src/stub.sh:7\`
   STUB_QUALITY_FINDING_DETAIL
VERDICT
		fi
		say_stub "stub: quality-reviewed $issue_name -> $verdict"
		;;

	*"pj-review skill"*)
		verdict="$(next_verdict spec "${STUB_VERDICTS:-${STUB_VERDICT:-approved}}")"
		mkdir -p issues/reviews
		# Both sections, in the shape pj-review's SKILL.md specifies, so the
		# tests can tell which of them the loop puts on the console.
		cat > "issues/reviews/${issue_name%.md}.md" <<VERDICT
Verdict: $verdict

## Reviewed

\`issues/$issue_name\`, \`make test\`: STUB_SUITE_PASSED

## Findings

1. **STUB_FINDING_LABEL** -- \`src/stub.sh:41\`
   STUB_FINDING_DETAIL
VERDICT
		say_stub "stub: reviewed $issue_name -> $verdict"
		;;

	*"pj-commit skill"*)
		git add -A
		case "$prompt" in
			*"stack-review fix"*)
				review="$(printf '%s' "$prompt" | grep -o 'issues/reviews/stack[A-Za-z0-9._-]*\.md' | head -1)"
				git commit -q -m "Fix stack review findings

Stub fix.

Review: $review"
				say_stub "stub: committed a stack-review fix"
				;;
			*)
				git commit -q -m "Implement ${issue_name%.md}

Stub implementation.

Issue: issues/$issue_name"
				say_stub "stub: committed $issue_name"
				;;
		esac
		;;

	*"requested changes to your"*)
		[ -z "${STUB_REMEDIATE_LOG:-}" ] || printf '%s\n' "$prompt" >> "$STUB_REMEDIATE_LOG"
		echo "remediated" >> "stub-work-${issue_name%.md}.txt"
		say_stub "stub: remediated $issue_name"
		;;

	*"pj-tdd skill"*)
		case "${STUB_MODE:-normal}" in
			partial)
				say_stub "stub: left $issue_name in issues/ for a human"
				exit 0
				;;
			nochanges)
				mkdir -p issues/done
				mv "$issue_file" "issues/done/$issue_name"
				say_stub "stub: closed $issue_name without changing anything"
				exit 0
				;;
			eagercommit)
				# An implementation that commits despite being told not to.
				# The loop rewinds it rather than stranding the work.
				echo "did work" >> "stub-work-${issue_name%.md}.txt"
				mkdir -p issues/done
				mv "$issue_file" "issues/done/$issue_name"
				git add -A
				git commit -q -m "Premature ${issue_name%.md}"
				say_stub "stub: committed $issue_name despite being asked not to"
				exit 0
				;;
		esac

		# What the loop handed this invocation, so the tests can assert on
		# the environment and prompt a real agent would have received.
		{
			echo "PJ_TEST_DIR=${PJ_TEST_DIR:-unset}"
			echo "PJ_TEST_CMD=${PJ_TEST_CMD:-unset}"
			echo "PJ_PROJECT_ROOT=${PJ_PROJECT_ROOT:-unset}"
			echo "$prompt"
		} > "stub-call-${issue_name%.md}.txt"

		echo "did work" >> "stub-work-${issue_name%.md}.txt"
		mkdir -p issues/done
		mv "$issue_file" "issues/done/$issue_name"
		say_stub "stub: implemented $issue_name, left uncommitted"
		;;
esac
STUB
chmod +x "$stub_bin/claude"

# make_repo NAME ISSUE_COUNT [PROJECT_SUBDIR] [MAKEFILE_SUBDIR] -> echoes the
# project path (what the loop is run from, which is not always the repo root)
#
# PROJECT_SUBDIR puts the project -- issues/ and the work -- below the git root,
# the shape of a monorepo package. MAKEFILE_SUBDIR puts the `make test` gate
# below the project, the shape of a repo whose PRD and issues sit at the top
# while the suite belongs to one subproject.
make_repo() {
	local repo="$fixture_root/$1"
	local project="$repo${3:+/$3}"
	local makefile_dir="$project${4:+/$4}"

	mkdir -p "$project/issues" "$makefile_dir"
	git -C "$repo" init -q
	git -C "$repo" config user.email test@example.com
	git -C "$repo" config user.name test

	printf 'test:\n\t@true\n' > "$makefile_dir/Makefile"
	# Only issues/ is ignored -- the stub's work file has to be a *tracked*
	# change, or its `git add -A && git commit` stages nothing and quietly
	# produces no commit.
	printf 'issues/\n' > "$repo/.gitignore"

	local n=1
	while [ "$n" -le "$2" ]; do
		local number
		number="$(printf '%03d' "$n")"
		local blocked="None - can start immediately"
		if [ "$n" -gt 1 ]; then
			blocked="- Blocked by \`issues/$(printf '%03d' $((n - 1)))-slice.md\`"
		fi
		cat > "$project/issues/$number-slice.md" <<-ISSUE
			## Parent PRD

			\`issues/prd.md\`

			## What to build

			Slice $n.

			## Acceptance criteria

			- [ ] Slice $n works

			## Blocked by

			$blocked

			## User stories addressed

			- User story 1
		ISSUE
		n=$((n + 1))
	done

	git -C "$repo" add -A
	git -C "$repo" commit -q -m "init"
	echo "$project"
}

# run_loop PROJECT_DIR [ARGS...]
#
# The loop's stdin is a regular file, not /dev/null: a test asserting that the
# loop gives each gh call </dev/null must not pass merely because the suite
# itself was started with stdin from /dev/null, as it is under an agent.
run_loop() {
	local repo="$1"
	shift
	if out="$(cd "$repo" && PATH="$stub_bin:${STUB_GH_DIR:+$STUB_GH_DIR:}$PATH" \
		PJ_SANDBOX_MARKER="$marker" \
		STUB_MODE="${STUB_MODE:-normal}" STUB_VERDICT="${STUB_VERDICT:-approved}" \
		NO_COLOR=1 "$RUN_ISSUES" "$@" <"$marker" 2>&1)"; then
		rc=0
	else
		rc=$?
	fi
}

# === refusals ===============================================================

repo="$(make_repo refusals 1)"

if out="$(cd "$repo" && PATH="$stub_bin:$PATH" PJ_SANDBOX_MARKER="$fixture_root/absent" \
	NO_COLOR=1 "$RUN_ISSUES" 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "refuses to run outside a sandbox"
assert_contains "$out" "not inside a sandbox" "the refusal says why"
assert_contains "$out" "--force" "the refusal names the escape hatch"

echo "dirty" > "$repo/untracked-change.txt"
git -C "$repo" add -A
run_loop "$repo"
assert_exit_code 1 "$rc" "refuses to start on a dirty working tree"
assert_contains "$out" "exactly one reviewable commit" "the dirty-tree refusal explains why it matters"
git -C "$repo" reset -q --hard HEAD
rm -f "$repo/untracked-change.txt"

mv "$repo/Makefile" "$repo/Makefile.hidden"
run_loop "$repo"
assert_exit_code 1 "$rc" "refuses when the project has no Makefile"
assert_contains "$out" "make test" "the missing-Makefile refusal names the contract it needs"
assert_contains "$out" "executable .pj/test" "the missing-Makefile refusal names .pj/test as a way to supply a gate"
assert_ok "and names it before the flag" \
	sh -c 'case "$1" in *.pj/test*--test-cmd*) exit 0 ;; *) exit 1 ;; esac' _ "$out"
mv "$repo/Makefile.hidden" "$repo/Makefile"

python3 - "$repo/issues/001-slice.md" <<'PYEOF'
import sys
path = sys.argv[1]
text = open(path).read()
open(path, "w").write(
    text.replace("None - can start immediately", "- Blocked by `issues/099-ghost.md`"))
PYEOF
run_loop "$repo"
assert_exit_code 1 "$rc" "refuses to start when the issue tree doesn't validate"
assert_contains "$out" "validate" "the invalid-tree refusal points at pj-issues validate"
git -C "$repo" checkout -q -- . 2>/dev/null || true

# === dry run ================================================================

repo="$(make_repo dryrun 2)"
run_loop "$repo" --dry-run
assert_exit_code 0 "$rc" "--dry-run exits 0"
assert_contains "$out" "001-slice.md" "--dry-run lists the queue"
assert_not_ok "--dry-run makes no commits" test -f "$repo/stub-work-001-slice.txt"
assert_not_ok "--dry-run creates no run log" test -d "$repo/issues/runs"

# === happy path =============================================================

repo="$(make_repo happy 3)"
run_loop "$repo"
assert_exit_code 0 "$rc" "a clean run over three dependent issues exits 0"
assert_contains "$out" "queue drained" "a completed run says the queue is drained"

commit_subjects="$(git -C "$repo" log --format=%s | head -3 | tr '\n' ' ')"
assert_contains "$commit_subjects" "Implement 003-slice" "the last issue produced a commit"
assert_contains "$commit_subjects" "Implement 001-slice" "the first issue produced a commit"
assert_eq "4" "$(git -C "$repo" log --oneline | wc -l | tr -d ' ')" "exactly one commit per issue, on top of the initial commit"

assert_ok "every issue ended up in issues/done" test -f "$repo/issues/done/003-slice.md"
assert_ok "a verdict file was written for each issue" test -f "$repo/issues/reviews/003-slice.md"
assert_ok "the run was logged" bash -c "ls -d '$repo/issues/runs/'*/run.log >/dev/null 2>&1"
assert_eq "" "$(cd "$repo" && git status --porcelain)" "the loop leaves a clean working tree"

# --- what the console showed while that happened ---------------------------
#
# The point of the whole arrangement: an unattended run you can't see is one
# you can't tell from a hung one, and three agents sharing a terminal are only
# auditable afterwards if every line says which of them produced it.
assert_contains "$out" "tdd" "the implementing phase labels its lines"
assert_contains "$out" "rev" "the review phase is labeled separately from the implementation"
assert_contains "$out" "gate" "the make test gate is labeled too"
assert_contains "$out" "Bash" "the agent's tool calls are rendered, not just its final message"
assert_contains "$out" "make test ... " "the gate announces itself before running, so a slow suite doesn't look like a hang"
assert_contains "$out" "pass" "a green gate says so on that same line"
assert_contains "$out" "issues/prd.md" "a subagent's tool call is rendered too"
assert_contains "$out" "STUB_SUITE_PASSED" \
	"an approved verdict shows what the reviewer checked, including whether it ran the suite itself"
assert_contains "$out" "↳" "a subagent's work is indented under the phase that spawned it"
assert_not_contains "$out" '"type":"assistant"' \
	"the console shows rendered lines, never the raw event stream"
assert_not_contains "$out" "commands_changed" "session bookkeeping never reaches the console"

run_dir="$(ls -d "$repo/issues/runs/"*/ | head -1)"
assert_ok "the raw event stream is archived beside the rendered log" \
	test -f "$run_dir/001-slice.jsonl"
assert_contains "$(cat "$run_dir/001-slice.jsonl")" '"type":"result"' \
	"the archive is claude's untouched stream, for when the rendering dropped what you needed"
assert_contains "$(cat "$run_dir/001-slice.log")" "Bash" \
	"the issue log holds the rendered lines"
assert_not_contains "$(cat "$run_dir/001-slice.log")" '"type":"assistant"' \
	"the rendered log isn't a second copy of the JSONL"
assert_ok "each phase archives its own stream" test -f "$run_dir/001-slice.review.jsonl"

# === review happens before the commit, not after it =========================

# The property the whole arrangement rests on: a commit that no reviewer has
# seen should never exist, not even briefly. Asserted on the order the phases
# appear in the console, which is the only place the sequence is observable.
repo="$(make_repo ordering 1)"
run_loop "$repo"
assert_exit_code 0 "$rc" "the ordering fixture runs clean"
review_line="$(printf '%s\n' "$out" | grep -n "reviewing 001-slice.md" | head -1 | cut -d: -f1)"
commit_line="$(printf '%s\n' "$out" | grep -n "committing 001-slice.md" | head -1 | cut -d: -f1)"
assert_ok "the review is reported before the commit is made" \
	test "$review_line" -lt "$commit_line"
assert_contains "$(cat "$repo/stub-call-001-slice.txt")" "Do not commit" \
	"the implementing agent is told to leave its work uncommitted"

# === --max-issues ===========================================================

repo="$(make_repo capped 3)"
run_loop "$repo" --max-issues 1
assert_exit_code 0 "$rc" "--max-issues exits 0"
assert_eq "2" "$(git -C "$repo" log --oneline | wc -l | tr -d ' ')" "--max-issues 1 stops after exactly one issue"
assert_ok "the second issue is left for a later run" test -f "$repo/issues/002-slice.md"

# === pj-tdd leaving an issue for a human ====================================

repo="$(make_repo partial 2)"
STUB_MODE=partial run_loop "$repo"
unset STUB_MODE
assert_exit_code 0 "$rc" "a partially-completed issue ends the run without erroring"
assert_contains "$out" "left it for a human" "the run says the issue needs a human"
assert_ok "the unfinished issue stays in issues/, not done/" test -f "$repo/issues/001-slice.md"
assert_eq "1" "$(git -C "$repo" log --oneline | wc -l | tr -d ' ')" "no commit is made for an unfinished issue"

# === an issue that changed nothing ==========================================

repo="$(make_repo nochanges 2)"
STUB_MODE=nochanges run_loop "$repo"
unset STUB_MODE
assert_contains "$out" "produced no changes" "an issue that changed nothing stops the run"
assert_contains "$out" "committing nothing" "the message says why that is worth stopping for"
assert_eq "1" "$(git -C "$repo" log --oneline | wc -l | tr -d ' ')" "nothing is committed when nothing was built"
assert_not_ok "there is nothing to review, so no reviewer is spent on it" \
	test -d "$repo/issues/reviews"

# === an implementation that commits anyway ==================================

# The instruction not to commit is an instruction to an agent, so the loop has
# to hold whether or not it was followed. Rewound rather than refused: the work
# is all still there, and stranding a finished issue would be the worse answer.
repo="$(make_repo eagercommit 1)"
STUB_MODE=eagercommit run_loop "$repo"
unset STUB_MODE
assert_exit_code 0 "$rc" "a premature commit doesn't fail the run"
assert_contains "$out" "rewinding" "the loop says it rewound the premature commit"
assert_contains "$out" "reviewing" "the rewound work is reviewed like any other"
assert_eq "2" "$(git -C "$repo" log --oneline | wc -l | tr -d ' ')" \
	"the issue still ends up as exactly one commit"
assert_contains "$(git -C "$repo" log --format=%s -1)" "Implement 001-slice" \
	"and it is the reviewed commit this loop made, not the premature one"

# === review requesting changes it never gets ================================

repo="$(make_repo rejected 2)"
STUB_VERDICT=changes-requested run_loop "$repo"
unset STUB_VERDICT
assert_exit_code 1 "$rc" "a run whose review keeps requesting changes exits non-zero"
assert_contains "$out" "remediation pass 2 of 2" "the loop attempts two remediation passes"
assert_not_contains "$out" "remediation pass 3" "and no third"
assert_contains "$out" "stopping for a human" "it stops rather than looping on remediation"
assert_ok "the unresolved issue is moved back out of done/ so a later run doesn't skip it" \
	test -f "$repo/issues/001-slice.md"
assert_not_ok "the unresolved issue is no longer marked done" test -f "$repo/issues/done/001-slice.md"
assert_not_ok "the blocked follow-on issue was never started" test -f "$repo/stub-work-002-slice.txt"

# The findings are the substance of the review. Printing only the verdict made
# an enforced review look like a skipped one, and left no way to judge whether
# the remediation pass had addressed what was actually wrong.
assert_contains "$out" "STUB_FINDING_LABEL" "a changes-requested verdict puts its findings on the console"
assert_contains "$out" "STUB_FINDING_DETAIL" "including the detail under each finding, not just its heading"
assert_contains "$out" "↳" "the findings are printed subordinate to the verdict line"

# Nothing unreviewed is ever committed, so an issue the review never cleared
# leaves the history untouched -- the queue and the branch cannot disagree.
assert_eq "1" "$(git -C "$repo" log --oneline | wc -l | tr -d ' ')" \
	"work the review never approved is never committed"
assert_contains "$out" "left staged and uncommitted" \
	"the run says where the unapproved work actually is"
assert_ok "and it really is still there, rather than discarded" \
	bash -c "cd '$repo' && ! git diff --cached --quiet"

# === --no-review ============================================================

repo="$(make_repo noreview 1)"
run_loop "$repo" --no-review
assert_exit_code 0 "$rc" "--no-review exits 0"
assert_not_ok "--no-review writes no verdict file" test -d "$repo/issues/reviews"
assert_eq "2" "$(git -C "$repo" log --oneline | wc -l | tr -d ' ')" "--no-review still commits the work"
env_log="$fixture_root/noreview-env.log"
repo="$(make_repo noreview-lenses 1)"
STUB_ENV_LOG="$env_log" run_loop "$repo" --no-review
assert_not_contains "$(cat "$env_log")" "review " "--no-review never invokes the spec review"
assert_not_contains "$(cat "$env_log")" "quality " "--no-review never invokes the quality review"

# === two review lenses ======================================================

# count_calls LOG CALL -- how many invocations of one kind the stub logged.
count_calls() {
	grep -c "^$2 " "$1" || true
}

repo="$(make_repo lenses-approve 1)"
env_log="$fixture_root/lenses-approve-env.log"
STUB_ENV_LOG="$env_log" run_loop "$repo"
assert_exit_code 0 "$rc" "both lenses approving lets the issue through"
assert_eq "2" "$(git -C "$repo" log --oneline | wc -l | tr -d ' ')" "the approved issue is committed"
assert_eq "1" "$(count_calls "$env_log" review)" "the spec review runs once, in its own invocation"
assert_eq "1" "$(count_calls "$env_log" quality)" "the quality review runs once, in its own invocation"
assert_ok "the quality verdict goes to its own file" test -f "$repo/issues/reviews/001-slice.quality.md"
assert_ok "the spec verdict keeps its file" test -f "$repo/issues/reviews/001-slice.md"
assert_ok "the quality reviewer's own lines are labeled qual" \
	grep -q -E 'qual +.*stub: quality-reviewed 001-slice.md' <<<"$out"

# Every child the loop starts carries the loop marker, which the guard hook
# reads to refuse publishing a stack even on the host.
assert_eq "" "$(grep -v 'PJ_RUN_ISSUES=1$' "$env_log" || true)" "every invocation the loop made sees PJ_RUN_ISSUES=1"
assert_contains "$(cat "$env_log")" "commit " "the marker check covered the commit invocation too"

repo="$(make_repo lenses-one-pass 1)"
env_log="$fixture_root/lenses-one-pass-env.log"
remediate_log="$fixture_root/lenses-one-pass-remediate.log"
STUB_ENV_LOG="$env_log" STUB_REMEDIATE_LOG="$remediate_log" \
	STUB_QUALITY_VERDICTS="changes-requested approved" run_loop "$repo"
assert_exit_code 0 "$rc" "a quality objection fixed in one pass lets the issue through"
assert_eq "1" "$(count_calls "$env_log" remediate)" "exactly one remediation pass ran"
assert_contains "$out" "remediation pass 1 of 2" "the console counts the pass"
assert_not_contains "$out" "remediation pass 2" "and there was no second"
assert_eq "2" "$(git -C "$repo" log --oneline | wc -l | tr -d ' ')" "the issue is committed after the pass"
assert_contains "$(cat "$remediate_log")" "issues/reviews/001-slice.md" "the remediation prompt names the spec verdict file"
assert_contains "$(cat "$remediate_log")" "issues/reviews/001-slice.quality.md" "and the quality verdict file"
assert_contains "$(cat "$remediate_log")" "[blocking]" "it tells the fixer which findings to fix"
assert_contains "$(cat "$remediate_log")" "[pre-existing]" "and which to leave alone"
assert_eq "2" "$(count_calls "$env_log" review)" "both lenses re-run after the pass: spec"
assert_eq "2" "$(count_calls "$env_log" quality)" "both lenses re-run after the pass: quality"

repo="$(make_repo lenses-two-passes 1)"
env_log="$fixture_root/lenses-two-passes-env.log"
STUB_ENV_LOG="$env_log" STUB_QUALITY_VERDICTS="changes-requested changes-requested approved" run_loop "$repo"
assert_exit_code 0 "$rc" "a quality objection fixed on the second pass lets the issue through"
assert_eq "2" "$(count_calls "$env_log" remediate)" "two remediation passes ran"
assert_contains "$out" "remediation pass 2 of 2" "the console counts both passes"
assert_eq "2" "$(git -C "$repo" log --oneline | wc -l | tr -d ' ')" "the issue is committed after the second pass"

repo="$(make_repo lenses-exhausted 1)"
env_log="$fixture_root/lenses-exhausted-env.log"
STUB_ENV_LOG="$env_log" STUB_QUALITY_VERDICTS="changes-requested" run_loop "$repo"
assert_exit_code 1 "$rc" "changes requested on all three attempts stops the run"
assert_eq "2" "$(count_calls "$env_log" remediate)" "after exactly two remediation passes"
assert_contains "$out" "after 2 remediation passes" "the console says how many passes ran"
assert_ok "the unresolved issue is back in issues/" test -f "$repo/issues/001-slice.md"
assert_eq "1" "$(git -C "$repo" log --oneline | wc -l | tr -d ' ')" "nothing was committed"
assert_ok "the work is left staged" bash -c "cd '$repo' && ! git diff --cached --quiet"

repo="$(make_repo lenses-no-quality-file 1)"
STUB_QUALITY_MODE=nofile run_loop "$repo"
assert_exit_code 1 "$rc" "a quality review that writes no verdict file stops the run"
assert_contains "$out" "001-slice.quality.md" "the stop names the missing quality verdict file"
assert_eq "1" "$(git -C "$repo" log --oneline | wc -l | tr -d ' ')" "nothing is committed without both verdicts"

# A verdict file left over from an earlier attempt must never stand in for a
# review that didn't happen: the remediated code would ship unreviewed.
repo="$(make_repo lenses-stale-quality 1)"
STUB_QUALITY_MODE=firstonly STUB_VERDICTS="changes-requested approved" run_loop "$repo"
assert_exit_code 1 "$rc" "a quality verdict left from an earlier attempt is never reused"
assert_contains "$out" "001-slice.quality.md" "the stop names the missing quality verdict"
assert_eq "1" "$(git -C "$repo" log --oneline | wc -l | tr -d ' ')" "the remediated work isn't committed on a stale verdict"

repo="$(make_repo lenses-garbled 1)"
STUB_QUALITY_VERDICTS="maybe" run_loop "$repo"
assert_exit_code 1 "$rc" "an unrecognized quality verdict stops the run"
assert_contains "$out" "unrecognized verdict line 'Verdict: maybe'" "the stop quotes the line it couldn't read"
assert_eq "1" "$(git -C "$repo" log --oneline | wc -l | tr -d ' ')" "nothing is committed on an unreadable verdict"

repo="$(make_repo lenses-findings 1)"
STUB_VERDICTS="changes-requested approved" STUB_QUALITY_VERDICTS="changes-requested approved" run_loop "$repo"
assert_exit_code 0 "$rc" "both lenses objecting once, then approving, lets the issue through"
assert_ok "the spec findings are printed under rev" grep -q -E 'rev +↳ .*STUB_FINDING_LABEL' <<<"$out"
assert_ok "the quality findings are printed under qual" grep -q -E 'qual +↳ .*STUB_QUALITY_FINDING_LABEL' <<<"$out"

# The docs describe what the loop now does.
readme_flat="$(tr '\n' ' ' < "$DOTFILES_HOME/README" | tr -s ' ')"
header_flat="$(sed -n '1,/^set -eu/p' "$RUN_ISSUES" | tr '\n' ' ' | tr -s ' ')"
assert_contains "$readme_flat" '`pj-review-quality` for how the code reads' "the README describes the second review lens"
assert_contains "$readme_flat" "up to two remediation passes" "the README describes two remediation passes"
assert_contains "$header_flat" "pj-review-quality for how the code reads" "the script header describes the second review lens"
assert_contains "$header_flat" "up to two remediation passes" "the script header describes two remediation passes"

# phase_color, lifted out of the script with the palette forced on: the
# console colors every qual line with it.
phase_color_of() {
	local fn
	fn="$(sed -n '/^phase_color() {/,/^}/p' "$RUN_ISSUES")"
	bash -c '
		. "$1/sandbox/lib/color.sh"
		sandbox_color_supported() { return 0; }
		sandbox_color_init
		eval "$2"
		phase_color "$3"
	' _ "$DOTFILES_HOME" "$fn" "$1"
}
qual_color="$(phase_color_of qual)"
assert_eq "$(printf '\033[1m\033[35m')" "$qual_color" "qual is bold magenta in phase_color"
for label in tdd rev fix gate git loop; do
	assert_ok "qual's color differs from $label's" test "$qual_color" != "$(phase_color_of "$label")"
done

# === the project is the cwd, not the repo root ==============================

# A monorepo package: the git root holds nothing of its own.
project="$(make_repo nested 2 app)"
run_loop "$project"
assert_exit_code 0 "$rc" "a project in a subdirectory of the repo runs from where it is"
assert_ok "the work lands in the project directory" test -f "$project/stub-work-001-slice.txt"
assert_ok "the issues consumed are the project's own" test -f "$project/issues/done/002-slice.md"
assert_eq "3" "$(git -C "$project" log --oneline | wc -l | tr -d ' ')" \
	"a nested project still gets exactly one commit per issue"

run_loop "$fixture_root/nested"
assert_exit_code 1 "$rc" "the repo root of a nested project is not itself a project"
assert_contains "$out" "not the repository root" \
	"the refusal explains that the loop anchors on the directory it was run from"

# === finding the gate =======================================================

# The PRD and issues sit at the top, where the paths written in them resolve,
# while the suite belongs to one subproject -- the shape that used to fail the
# preflight outright.
#
# PJ_TEST_DIR is set on the way in to prove it is dropped rather than passed
# through: the loop's own parent may well be another run that still sets it.
project="$(make_repo autodiscover 1 "" backend)"
PJ_TEST_DIR="$fixture_root/stale" run_loop "$project"
assert_exit_code 0 "$rc" "a single nested 'make test' target is found without being named"
assert_contains "$out" "gating on 'make -C backend test'" \
	"the run says which command it settled on"
assert_contains "$out" "make -C backend test ... " \
	"the gate's progress line names the command it is about to run"
assert_contains "$(cat "$project/stub-call-001-slice.txt")" "PJ_TEST_CMD=make -C backend test" \
	"the Stop hook is handed the same command, so the red-test gate isn't silently skipped"
assert_contains "$(cat "$project/stub-call-001-slice.txt")" "PJ_PROJECT_ROOT=$project" \
	"the Stop hook is told where to run it from"
assert_contains "$(cat "$project/stub-call-001-slice.txt")" "PJ_TEST_DIR=unset" \
	"no invocation receives PJ_TEST_DIR, even when the loop itself was given one"

# Every call path, not just the implementing one: review, remediation and
# commit each get the same environment. A changes-requested verdict is what
# drives the loop through all four.
project="$(make_repo everycall 1 "" backend)"
env_log="$fixture_root/everycall-env.log"
prompt_log="$fixture_root/everycall-prompts.log"
STUB_ENV_LOG="$env_log" STUB_PROMPT_LOG="$prompt_log" STUB_VERDICT=changes-requested \
	PJ_TEST_DIR="$fixture_root/stale" run_loop "$project"
for call in tdd review quality remediate; do
	assert_contains "$(cat "$env_log")" "$call PJ_TEST_DIR=unset PJ_TEST_CMD=make -C backend test PJ_PROJECT_ROOT=$project" \
		"the $call invocation gets PJ_TEST_CMD and PJ_PROJECT_ROOT, and no PJ_TEST_DIR"
done
# The session-start hook announces the gate from PJ_TEST_CMD, so the prompts
# carry no second copy of it that could drift from the first.
assert_contains "$(cat "$prompt_log")" "requested changes to your" \
	"the prompt log really holds the remediate prompt, so the checks below cover it"
assert_not_contains "$(cat "$prompt_log")" "make -C backend test" \
	"no tdd, review or remediate prompt names the test command"
assert_not_contains "$(cat "$prompt_log")" "test gate" \
	"no tdd, review or remediate prompt says where to run tests"
project="$(make_repo everycommit 1 "" backend)"
env_log="$fixture_root/everycommit-env.log"
STUB_ENV_LOG="$env_log" PJ_TEST_DIR="$fixture_root/stale" run_loop "$project"
assert_contains "$(cat "$env_log")" "commit PJ_TEST_DIR=unset PJ_TEST_CMD=make -C backend test PJ_PROJECT_ROOT=$project" \
	"the commit invocation gets PJ_TEST_CMD and PJ_PROJECT_ROOT, and no PJ_TEST_DIR"
assert_eq "0" "$(grep -vc "PJ_TEST_DIR=unset PJ_TEST_CMD=make -C backend test PJ_PROJECT_ROOT=$project PJ_RUN_ISSUES=1\$" "$env_log" || true)" \
	"no invocation of any kind gets a different environment"

# The discovered directory goes into a string that `sh -c` runs, in the gate
# and in the Stop hook alike, so a name the shell would split or expand has to
# arrive as one word.
project="$(make_repo spacedir 1 "" "bob's app")"
run_loop "$project"
assert_exit_code 0 "$rc" "a suite discovered under a directory with a space and a quote still gates the run"
assert_contains "$out" "make -C 'bob'\\''s app' test ... " \
	"the discovered directory is shell-quoted into the command"
assert_ok "and the gate really ran that suite, rather than failing and stopping" \
	test -f "$project/issues/done/001-slice.md"
assert_contains "$(cat "$project/stub-call-001-slice.txt")" "PJ_TEST_CMD=make -C 'bob'\\''s app' test" \
	"the Stop hook is handed the same quoted command"
assert_ok "and that command works when run the way the hook runs it" \
	sh -c "cd '$project' && make -C 'bob'\\''s app' test"

project="$(make_repo rootgate 1)"
run_loop "$project"
assert_exit_code 0 "$rc" "a root 'make test' target is found without being named"
assert_contains "$(cat "$project/stub-call-001-slice.txt")" "PJ_TEST_CMD=make test" \
	"a root target resolves to plain 'make test'"
assert_contains "$out" "make test ... " "the root gate's progress line names 'make test'"

project="$(make_repo ambiguous 1 "" backend)"
mkdir -p "$project/frontend"
printf 'test:\n\t@true\n' > "$project/frontend/Makefile"
git -C "$project" add -A
git -C "$project" commit -q -m "add a second suite"
run_loop "$project"
assert_exit_code 1 "$rc" "two candidate suites are refused rather than guessed between"
assert_contains "$out" "--test-cmd" "the ambiguity refusal names the flag that resolves it"
assert_contains "$out" "backend" "the ambiguity refusal lists the candidates it found"
assert_contains "$out" "frontend" "the ambiguity refusal lists all of them"
assert_contains "$out" "commit an executable .pj/test" \
	"the ambiguity refusal names .pj/test as the fix that survives being retyped"
assert_ok "and names it before the flag" \
	sh -c 'case "$1" in *.pj/test*--test-cmd*) exit 0 ;; *) exit 1 ;; esac' _ "$out"

run_loop "$project" --test-cmd 'make -C backend test'
assert_exit_code 0 "$rc" "--test-cmd resolves the ambiguity"
assert_contains "$(cat "$project/stub-call-001-slice.txt")" "PJ_TEST_CMD=make -C backend test" \
	"--test-cmd gates on exactly that command"
assert_contains "$out" "make -C backend test ... " "the gate runs the command it was given"

# Where the gate ran, reported by the gate itself. `pwd -P` on both sides,
# because macOS's TMPDIR is a symlink.
project="$(make_repo cmdroot 1 "" backend)"
run_loop "$project" --test-cmd 'pwd -P > gate-cwd.txt'
assert_exit_code 0 "$rc" "a --test-cmd that isn't make at all is run as given"
assert_eq "$(cd "$project" && pwd -P)" "$(cat "$project/gate-cwd.txt" 2>/dev/null)" \
	"the gate command runs with the project root as its working directory"

project="$(make_repo redcmd 2 "" backend)"
run_loop "$project" --test-cmd 'echo CMD_TAIL_LINE; exit 3'
assert_contains "$out" "'echo CMD_TAIL_LINE; exit 3' is failing" "a red --test-cmd stops the run"
assert_contains "$out" "CMD_TAIL_LINE" "the red command's output tail is printed"
assert_not_ok "the review never runs over a red gate" test -f "$project/issues/reviews/001-slice.md"
assert_not_ok "the next issue is never started" test -f "$project/stub-work-002-slice.txt"

# === a project-owned .pj/test ===============================================

# add_pj_test PROJECT BODY [MODE] -- commit BODY as PROJECT/.pj/test, executable
# unless MODE says otherwise. Committed, because the loop refuses a dirty tree.
add_pj_test() {
	mkdir -p "$1/.pj"
	printf '#!/bin/sh\n%s\n' "$2" > "$1/.pj/test"
	chmod "${3:-755}" "$1/.pj/test"
	git -C "$1" add -A
	git -C "$1" commit -q -m "add .pj/test"
}

project="$(make_repo pjtest 1 "" backend)"
add_pj_test "$project" 'echo PJ_TEST_RAN >> pj-test-runs.txt'
run_loop "$project"
assert_exit_code 0 "$rc" "an executable .pj/test gates the run with no flag passed"
assert_contains "$(cat "$project/pj-test-runs.txt" 2>/dev/null)" "PJ_TEST_RAN" \
	"the gate really ran .pj/test"

# A root target that would also pass, so only the record of what ran tells the
# two apart.
project="$(make_repo pjtestroot 1)"
add_pj_test "$project" 'echo PJ_TEST_RAN >> pj-test-runs.txt'
run_loop "$project"
assert_contains "$(cat "$project/stub-call-001-slice.txt")" "PJ_TEST_CMD=./.pj/test" \
	".pj/test wins over a root 'make test' target"

project="$(make_repo pjtestflag 1)"
add_pj_test "$project" 'echo PJ_TEST_RAN >> pj-test-runs.txt'
run_loop "$project" --test-cmd 'make test'
assert_exit_code 0 "$rc" "--test-cmd alongside a .pj/test runs clean"
assert_not_ok "--test-cmd wins over .pj/test" test -f "$project/pj-test-runs.txt"

# Invoked from the project root as ./.pj/test, so it reports the root rather
# than .pj/.
project="$(make_repo pjtestcwd 1 "" backend)"
add_pj_test "$project" 'pwd -P > gate-cwd.txt'
run_loop "$project"
assert_eq "$(cd "$project" && pwd -P)" "$(cat "$project/gate-cwd.txt" 2>/dev/null)" \
	".pj/test runs with the project root as its working directory"

project="$(make_repo pjtestred 2 "" backend)"
add_pj_test "$project" 'echo PJ_TEST_TAIL_LINE; exit 4'
run_loop "$project"
assert_contains "$out" "'./.pj/test' is failing" "a red .pj/test stops the run"
assert_contains "$out" "PJ_TEST_TAIL_LINE" "the red .pj/test's output tail is printed"
assert_not_ok "the review never runs over a red .pj/test" test -f "$project/issues/reviews/001-slice.md"
assert_not_ok "the next issue is never started" test -f "$project/stub-work-002-slice.txt"

project="$(make_repo pjtestenv 1)"
add_pj_test "$project" 'true'
env_log="$fixture_root/pjtestenv-env.log"
STUB_ENV_LOG="$env_log" STUB_VERDICT=changes-requested run_loop "$project"
assert_contains "$out" "gating on './.pj/test'" "the run announces that it is gating on .pj/test"
for call in tdd review remediate; do
	assert_contains "$(cat "$env_log")" "$call PJ_TEST_DIR=unset PJ_TEST_CMD=./.pj/test PJ_PROJECT_ROOT=$project" \
		"the $call invocation hands the Stop hook the .pj/test invocation"
done
assert_ok "and that invocation works when run the way the hook runs it" \
	sh -c "cd '$project' && ./.pj/test"

# Falling through to the root target here would gate the run on the wrong suite
# -- the failure this ordering exists to prevent.
project="$(make_repo pjtestnoexec 1)"
add_pj_test "$project" 'echo PJ_TEST_RAN >> pj-test-runs.txt' 644
run_loop "$project"
assert_exit_code 1 "$rc" "a .pj/test that isn't executable is refused"
assert_contains "$out" "chmod +x" "the refusal says to make it executable"
assert_not_ok "it doesn't fall through to 'make test' and start work" \
	test -f "$project/stub-call-001-slice.txt"

project="$(make_repo badtestcmd 1)"
run_loop "$project" --test-cmd
assert_exit_code 1 "$rc" "--test-cmd with no value is refused instead of crashing the shell"
assert_contains "$out" "needs a command" "the refusal says what --test-cmd wants"

run_loop "$project" --test-cmd ''
assert_exit_code 1 "$rc" "--test-cmd with an empty value is refused too"
assert_contains "$out" "needs a command" "the empty-value refusal says what --test-cmd wants"

run_loop "$project" --test-dir backend
assert_exit_code 1 "$rc" "--test-dir is no longer accepted"
assert_contains "$out" "unknown argument '--test-dir'" "--test-dir gets the unknown-argument refusal"

out="$("$RUN_ISSUES" --help 2>&1)"
assert_contains "$out" "--test-cmd" "--help describes --test-cmd"
assert_not_contains "$out" "--test-dir" "--help no longer mentions --test-dir"
assert_not_ok "the script's own header no longer mentions --test-dir" grep -q -- '--test-dir' "$RUN_ISSUES"
assert_contains "$out" ".pj/test" "--help describes .pj/test as part of the resolution order"
assert_contains "$(cat "$DOTFILES_HOME/README")" ".pj/test" "the README describes .pj/test too"

# === a red suite in the subdirectory stops the run ==========================

# The point of resolving the gate at all: it has to be able to fail. A run that
# gates on the wrong Makefile -- or on none -- is an unattended run with no gate.
project="$(make_repo redgate 2 "" backend)"
printf 'test:\n\t@echo GATE_DETAIL_LINE; exit 1\n' > "$project/backend/Makefile"
git -C "$project" add -A
git -C "$project" commit -q -m "make the suite red"
run_loop "$project"
assert_contains "$out" "'make -C backend test' is failing" "a red suite in the gate directory stops the run"
assert_contains "$out" "GATE_DETAIL_LINE" \
	"a red gate prints the output on the spot -- the reason the run stopped shouldn't need a log dive"
assert_not_ok "the next issue is never started" test -f "$project/stub-work-002-slice.txt"

# === --plain, the escape hatch ==============================================

# For the one failure this repo can't control: a claude release whose
# stream-json schema the renderer doesn't understand yet.
repo="$(make_repo plain 1)"
run_loop "$repo" --plain
assert_exit_code 0 "$rc" "--plain exits 0"
assert_contains "$out" "stub: implemented" "--plain prints the agent's final message"
assert_eq "2" "$(git -C "$repo" log --oneline | wc -l | tr -d ' ')" "--plain still commits the work"
plain_run_dir="$(ls -d "$repo/issues/runs/"*/ | head -1)"
assert_not_ok "--plain archives no event stream, because there wasn't one" \
	test -f "$plain_run_dir/001-slice.jsonl"

# === PJ_CLAUDE_ARGS overriding the output format ============================

# Last --output-format wins, so this wouldn't fail -- it would leave the
# renderer unable to read the stream and the run reporting nothing for hours.
repo="$(make_repo argsconflict 1)"
if out="$(cd "$repo" && PATH="$stub_bin:$PATH" PJ_SANDBOX_MARKER="$marker" \
	PJ_CLAUDE_ARGS="--output-format json" NO_COLOR=1 "$RUN_ISSUES" 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "PJ_CLAUDE_ARGS overriding --output-format is refused rather than silently blinding the run"
assert_contains "$out" "--plain" "the refusal names the deliberate way to give the stream up"

if out="$(cd "$repo" && PATH="$stub_bin:$PATH" PJ_SANDBOX_MARKER="$marker" \
	PJ_CLAUDE_ARGS="--output-format json" NO_COLOR=1 "$RUN_ISSUES" --plain 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "--plain makes that override allowed again, since nothing is rendering"

# === the end-of-run full sweep ==============================================

# Per-issue gating on an affected subset can't see a change in one package
# breaking another's suite, so a run that would end clean re-runs its gate once
# with PJ_TEST_SCOPE=all. Each gate invocation records its scope and cwd outside
# the repo, so the record never becomes part of the work.
sweep_cmd() {
	printf 'echo "scope=${PJ_TEST_SCOPE:-unset} cwd=$(pwd -P)" >> %s' "$1"
}

project="$(make_repo sweepclean 2 "" backend)"
gate_log="$fixture_root/sweepclean-gate.log"
run_loop "$project" --test-cmd "$(sweep_cmd "$gate_log")"
assert_exit_code 0 "$rc" "a clean run with a green sweep exits 0"
assert_eq "3" "$(wc -l < "$gate_log" | tr -d ' ')" \
	"a clean run invokes the gate once per issue and once more for the sweep"
assert_eq "scope=all" "$(tail -1 "$gate_log" | cut -d' ' -f1)" \
	"the sweep runs with PJ_TEST_SCOPE=all in its environment"
assert_eq "0" "$(head -2 "$gate_log" | grep -vc '^scope=unset ' || true)" \
	"the per-issue gates run without PJ_TEST_SCOPE"
assert_eq "0" "$(grep -vc " cwd=$(cd "$project" && pwd -P)\$" "$gate_log" || true)" \
	"the sweep runs from the project root, like every other gate invocation"
assert_eq "1" "$(printf '%s\n' "$out" | grep -c 'gate ▸ full sweep (PJ_TEST_SCOPE=all): .* \.\.\. pass$' || true)" \
	"the sweep's line is labeled distinctly from a per-issue gate line"
assert_eq "2" "$(printf '%s\n' "$out" | grep -c 'gate ▸ echo .* \.\.\. pass$' || true)" \
	"while each per-issue gate line keeps its plain shape"
assert_contains "$out" "done -- 2 issue(s) completed this run" \
	"a green sweep leaves the usual closing summary"

# Inherited from whatever launched the loop, it must still not leak into the
# per-issue gates, or every issue would pay for the full sweep.
project="$(make_repo sweepinherit 1 "" backend)"
gate_log="$fixture_root/sweepinherit-gate.log"
PJ_TEST_SCOPE=all run_loop "$project" --test-cmd "$(sweep_cmd "$gate_log")"
assert_eq "scope=unset" "$(head -1 "$gate_log" | cut -d' ' -f1)" \
	"a PJ_TEST_SCOPE the loop inherited is dropped from the per-issue gate"

# Green on every issue, red only across the whole tree: the cross-package
# breakage the sweep exists to catch.
project="$(make_repo sweepred 2 "" backend)"
run_loop "$project" --test-cmd '[ "${PJ_TEST_SCOPE:-}" != all ] || { echo SWEEP_TAIL_LINE; exit 5; }'
assert_exit_code 1 "$rc" "a red sweep makes the run exit non-zero"
assert_eq "3" "$(git -C "$project" log --oneline | wc -l | tr -d ' ')" \
	"a red sweep leaves every commit the run made in place"
assert_contains "$out" "full sweep is failing" "the red-sweep message names the sweep as what failed"
assert_not_contains "$out" "failing after 002-slice.md" "and doesn't blame the last issue"
assert_contains "$out" "SWEEP_TAIL_LINE" "the red sweep's output tail is printed"

project="$(make_repo sweepempty 0 "" backend)"
gate_log="$fixture_root/sweepempty-gate.log"
run_loop "$project" --test-cmd "$(sweep_cmd "$gate_log")"
assert_exit_code 0 "$rc" "a run over an empty queue exits 0"
assert_not_ok "a run that completes zero issues runs no sweep" test -f "$gate_log"

# One issue committed, then the second goes red at its own gate: the run has
# already stopped for its own reason, and a sweep would only bury it.
project="$(make_repo sweepstopped 2 "" backend)"
gate_log="$fixture_root/sweepstopped-gate.log"
run_loop "$project" --test-cmd "$(sweep_cmd "$gate_log"); [ ! -f stub-work-002-slice.txt ]"
assert_contains "$out" "is failing after 002-slice.md" "the second issue's gate stops the run"
assert_eq "2" "$(wc -l < "$gate_log" | tr -d ' ')" \
	"a run that stops early on a failing issue runs no sweep"
assert_not_contains "$out" "full sweep" "and says nothing about one"

assert_ok "the script's header describes the sweep" \
	sh -c 'sed -n "/^set -eu/q;p" "$1" | grep -q "PJ_TEST_SCOPE=all"' _ "$RUN_ISSUES"
assert_ok "the README describes the sweep" grep -q "PJ_TEST_SCOPE=all" "$DOTFILES_HOME/README"

# === the manual test plan pointer ===========================================

# A clean run reads as a verified branch, and it isn't one when planning set
# checks aside for a person. Nothing else in the output would say so.
repo="$(make_repo nomanualtests 1)"
run_loop "$repo"
assert_exit_code 0 "$rc" "a run without a manual test plan exits 0"
assert_not_contains "$out" "manual-tests.md" \
	"nothing is said about a manual test plan that was never written"

repo="$(make_repo manualtests 1)"
printf '# Manual test plan\n\n## MT-1 -- it renders\n' > "$repo/issues/manual-tests.md"
run_loop "$repo"
assert_exit_code 0 "$rc" "a manual test plan doesn't change how the run exits"
assert_contains "$out" "issues/manual-tests.md" \
	"the summary points at the checks no test can make"
assert_contains "$out" "no test can make" "and says why they're listed separately"
# It sits in issues/ beside the PRD, so it is neither queued as work nor
# committed with it.
assert_eq "2" "$(git -C "$repo" log --oneline | wc -l | tr -d ' ')" \
	"the manual test plan is not committed with the issue"
assert_ok "the manual test plan is never picked up as an issue" \
	test -f "$repo/issues/manual-tests.md"

# === stack mode =============================================================

STUBS="$TEST_DIR/stubs"

# make_stacked_repo NAME [PLAN_STATUS] -- make_repo's two slices, cut from an
# approved plan as layers w/01-slice and w/02-slice on the repo's current
# branch as trunk. Passes pj-issues validate. Echoes the project path.
make_stacked_repo() {
	local project
	project="$(make_repo "$1" 2)"
	local trunk
	trunk="$(git -C "$project" branch --show-current)"
	local n
	for n in 1 2; do
		printf '\n## Branch\n\nw/0%s-slice\n\n## Plan section\n\n`issues/plan.md` Layer %s\n' "$n" "$n" \
			>> "$project/issues/00$n-slice.md"
	done
	printf '# Plan — x\n\nStatus: %s\nTrunk: %s\n\n## Stack\n\n| # | Branch | Delivers | Depends on | ~non-test lines |\n|---|---|---|---|---|\n| 1 | w/01-slice | US-1 | trunk | 10 |\n| 2 | w/02-slice | US-2 | 1 | 10 |\n' \
		"${2:-approved (2026-11-21)}" "$trunk" > "$project/issues/plan.md"
	echo "$project"
}

gh_log() { cat "$(git -C "$1" rev-parse --absolute-git-dir)/stub-gh.log" 2>/dev/null || true; }
commits_between() { git -C "$1" rev-list --count "$2..$3"; }

# --- a two-layer stack, from the trunk ---

project="$(make_stacked_repo stack-fresh)"
trunk="$(git -C "$project" branch --show-current)"
STUB_GH_DIR="$STUBS" run_loop "$project"
assert_exit_code 0 "$rc" "a two-layer stacked queue runs to completion"
calls="$(gh_log "$project")"
assert_contains "$calls" "stack init --base $trunk w/01-slice" "layer 1's branch is created with init on the trunk"
assert_contains "$calls" "stack top" "layer 2 first moves to the top of the stack"
assert_contains "$calls" "stack add w/02-slice" "and adds its branch there"
assert_eq "1" "$(commits_between "$project" "$trunk" w/01-slice)" "layer 1 gets exactly one commit"
assert_eq "1" "$(commits_between "$project" w/01-slice w/02-slice)" "layer 2 gets exactly one commit, on top of layer 1"
assert_ok "layer 2's branch contains layer 1's commit" git -C "$project" merge-base --is-ancestor w/01-slice w/02-slice
assert_eq "w/02-slice" "$(git -C "$project" branch --show-current)" "the run ends on the top layer"
assert_eq "" "$(printf '%s\n' "$calls" | grep -v '\[stdin:/dev/null\]$' || true)" \
	"every gh call the loop made had stdin from /dev/null"

# --- refusals, all before any claude invocation ---

project="$(make_stacked_repo stack-draft "draft")"
env_log="$fixture_root/stack-draft-env.log"
STUB_GH_DIR="$STUBS" STUB_ENV_LOG="$env_log" run_loop "$project"
assert_exit_code 1 "$rc" "a stacked issue whose plan is a draft is refused"
assert_contains "$out" "isn't approved" "the refusal says the plan needs approving"
assert_not_ok "no claude invocation happened before the draft-plan refusal" test -s "$env_log"

project="$(make_stacked_repo stack-off-trunk)"
trunk="$(git -C "$project" branch --show-current)"
git -C "$project" checkout -q -b elsewhere
env_log="$fixture_root/stack-off-trunk-env.log"
STUB_GH_DIR="$STUBS" STUB_ENV_LOG="$env_log" run_loop "$project"
assert_exit_code 1 "$rc" "a fresh stacked run off the plan's trunk is refused"
assert_contains "$out" "elsewhere" "the refusal names the current branch"
assert_contains "$out" "$trunk" "and the plan's trunk"
assert_not_ok "no claude invocation happened before the off-trunk refusal" test -s "$env_log"

no_gh="$fixture_root/no-gh-stack"
mkdir -p "$no_gh"
printf '#!/bin/sh\necho "unknown command \\"stack\\" for \\"gh\\"" >&2\nexit 1\n' > "$no_gh/gh"
chmod +x "$no_gh/gh"
project="$(make_stacked_repo stack-no-gh)"
env_log="$fixture_root/stack-no-gh-env.log"
STUB_GH_DIR="$no_gh" STUB_ENV_LOG="$env_log" run_loop "$project"
assert_exit_code 1 "$rc" "a stacked run without gh stack is refused"
assert_contains "$out" "gh-stack" "the refusal names the missing extension"
assert_not_ok "no claude invocation happened before the missing-extension refusal" test -s "$env_log"

# --- resuming on an existing stack ---

project="$(make_stacked_repo stack-resume)"
trunk="$(git -C "$project" branch --show-current)"
(
	cd "$project"
	PATH="$STUBS:$PATH"
	gh stack init --base "$trunk" w/01-slice >/dev/null </dev/null
	echo "layer 1" > layer1.txt && git add layer1.txt && git commit -q -m "Implement 001-slice"
	mkdir -p issues/done && mv issues/001-slice.md issues/done/
	sed -i.bak 's/^- \[ \]/- [x]/' issues/done/001-slice.md && rm issues/done/001-slice.md.bak
	gh stack add w/02-slice >/dev/null </dev/null
	# Resumed from the trunk, not from layer 1's tip, so layer 2's branch is
	# somewhere other than HEAD: the one-commit check has to count from the
	# branch it lands on, or layer 1's commit would be folded into layer 2's.
	git checkout -q "$trunk"
)
setup_calls="$(gh_log "$project" | wc -l | tr -d ' ')"
STUB_GH_DIR="$STUBS" run_loop "$project"
assert_exit_code 0 "$rc" "a resumed stacked run completes"
resumed_calls="$(gh_log "$project" | sed "1,${setup_calls}d")"
assert_not_contains "$resumed_calls" "stack init" "resuming makes no init call"
assert_not_contains "$resumed_calls" "stack add" "and no add call for a branch the stack already has"
assert_eq "w/02-slice" "$(git -C "$project" branch --show-current)" "layer 2's existing branch is checked out"
assert_eq "1" "$(commits_between "$project" w/01-slice w/02-slice)" "and layer 2 is committed there, once"
assert_ok "layer 2 still sits on layer 1's commit, rather than folding it in" \
	git -C "$project" merge-base --is-ancestor w/01-slice w/02-slice
assert_not_contains "$out" "rewinding" "checking out an existing layer isn't mistaken for a premature commit"

# --- a gh stack call that fails ---

project="$(make_stacked_repo stack-add-fails)"
trunk="$(git -C "$project" branch --show-current)"
git -C "$project" branch w/02-slice
STUB_GH_DIR="$STUBS" run_loop "$project"
assert_exit_code 1 "$rc" "a failing gh stack add stops the run with exit 1"
assert_contains "$out" "gh stack add w/02-slice" "the stop names the command that failed"
assert_eq "1" "$(commits_between "$project" "$trunk" w/01-slice)" "layer 1 was committed before the failure"
assert_eq "0" "$(commits_between "$project" "$trunk" w/02-slice)" "nothing was committed for layer 2"
assert_not_ok "layer 2 was never implemented" test -f "$project/stub-work-002-slice.txt"

# --- unstacked queues never touch gh ---

project="$(make_repo stack-unstacked 2)"
STUB_GH_DIR="$STUBS" run_loop "$project"
assert_exit_code 0 "$rc" "an unstacked queue runs as before with the stub gh on PATH"
assert_eq "" "$(gh_log "$project")" "an unstacked queue makes no gh calls at all"

# --- the whole-stack review, once the stack is drained ---

# line_of TEXT NEEDLE -- the number of the first line of TEXT containing NEEDLE.
line_of() { printf '%s\n' "$1" | { grep -n -F -e "$2" || true; } | head -1 | cut -d: -f1; }

project="$(make_stacked_repo stack-review-ok)"
env_log="$fixture_root/stack-review-ok-env.log"
STUB_GH_DIR="$STUBS" STUB_ENV_LOG="$env_log" run_loop "$project"
assert_exit_code 0 "$rc" "a drained stack with an approving stack review exits 0"
assert_eq "1" "$(count_calls "$env_log" stack)" "the stack review runs once, in its own invocation"
assert_ok "its verdict goes to issues/reviews/stack.md, named after the plan" test -f "$project/issues/reviews/stack.md"
verify_line="$(line_of "$out" "all 2 layer(s) pass")"
review_line="$(line_of "$out" "stub: reviewed the stack")"
assert_ok "pj-stack-verify runs on every layer before the stack review" test "${verify_line:-999999}" -lt "${review_line:-0}"
assert_ok "the stack reviewer's lines are labeled stak" grep -q -E 'stak +.*stub: reviewed the stack' <<<"$out"

project="$(make_stacked_repo stack-review-rejects)"
trunk="$(git -C "$project" branch --show-current)"
STUB_GH_DIR="$STUBS" STUB_STACK_VERDICT=changes-requested run_loop "$project"
assert_exit_code 1 "$rc" "a re-review still requesting changes stops the run with exit 1"
assert_ok "its findings are printed under stak" grep -q -E 'stak +↳ .*STUB_FIX_LAYER1' <<<"$out"
assert_contains "$out" "Layer: w/01-slice" "with the layer that owns each one"
assert_eq "2" "$(commits_between "$project" "$trunk" w/01-slice)" "layer 1 keeps its issue commit and its fix commit"
assert_eq "2" "$(commits_between "$project" w/01-slice w/02-slice)" "and so does layer 2"
assert_contains "$out" "no second fix wave" "there is no second round of fixes"
assert_contains "$out" "run pj-stack-verify and the pj-review-stack skill yourself" "and the stop says how to finish by hand"

project="$(make_stacked_repo stack-review-nofile)"
STUB_GH_DIR="$STUBS" STUB_STACK_MODE=nofile run_loop "$project"
assert_exit_code 1 "$rc" "a stack review that writes no verdict stops the run"
assert_contains "$out" "issues/reviews/stack.md" "naming the missing verdict file"

# A layer red at verify time but green during the run: the gate fails only on
# layer 1 with nothing staged, which the per-issue gate never sees (the work
# is staged then) but pj-stack-verify does.
project="$(make_stacked_repo stack-verify-red)"
env_log="$fixture_root/stack-verify-red-env.log"
STUB_GH_DIR="$STUBS" STUB_ENV_LOG="$env_log" run_loop "$project" \
	--test-cmd 'if git diff --cached --quiet && [ "$(git branch --show-current)" = w/01-slice ]; then echo VERIFY_LAYER_RED; exit 1; fi'
assert_exit_code 1 "$rc" "a layer failing pj-stack-verify stops the run with exit 1"
assert_contains "$out" "fails on w/01-slice" "the failing layer is named as the one that fails"
assert_eq "0" "$(count_calls "$env_log" stack)" "no stack review is sent after a failed verify"

# A gate that selects what to run by what changed (pj-affected-tests) finds
# nothing changed on a clean layer checkout, so pj-stack-verify must run it as
# the full sweep. This gate fails only with PJ_TEST_SCOPE=all on layer 1: the
# per-issue gates (no scope) and the sweep (scope all, but on layer 2) pass.
project="$(make_stacked_repo stack-verify-scope)"
env_log="$fixture_root/stack-verify-scope-env.log"
STUB_GH_DIR="$STUBS" STUB_ENV_LOG="$env_log" run_loop "$project" \
	--test-cmd 'if [ "${PJ_TEST_SCOPE:-}" = all ] && [ "$(git branch --show-current)" = w/01-slice ]; then echo SCOPED_RED; exit 1; fi'
assert_exit_code 1 "$rc" "pj-stack-verify runs each layer's gate as the full sweep (PJ_TEST_SCOPE=all)"
assert_eq "0" "$(count_calls "$env_log" stack)" "so a layer red under the sweep stops the run before the stack review"

# --no-review skips the stack review, a model review like the others, but
# not the per-layer gate, the way it never skips the per-issue gate.
project="$(make_stacked_repo stack-noreview-red)"
STUB_GH_DIR="$STUBS" run_loop "$project" --no-review \
	--test-cmd 'if git diff --cached --quiet && [ "$(git branch --show-current)" = w/01-slice ]; then echo VERIFY_LAYER_RED; exit 1; fi'
assert_exit_code 1 "$rc" "--no-review still runs pj-stack-verify, and a red layer stops the run"
project="$(make_stacked_repo stack-noreview-green)"
env_log="$fixture_root/stack-noreview-green-env.log"
STUB_GH_DIR="$STUBS" STUB_ENV_LOG="$env_log" run_loop "$project" --no-review
assert_exit_code 0 "$rc" "a green stack under --no-review exits 0"
assert_contains "$out" "all 2 layer(s) pass" "after verifying every layer"
assert_eq "0" "$(count_calls "$env_log" stack)" "but sends no stack review"
assert_contains "$out" "skipping the stack review: --no-review" "and says why"

# --- the fix phase: fixed in the owning layer, bottom first, re-reviewed once ---

# nth_line_of TEXT NEEDLE N -- the line number of the Nth line containing NEEDLE.
nth_line_of() { printf '%s\n' "$1" | { grep -n -F -e "$2" || true; } | sed -n "${3}p" | cut -d: -f1; }

project="$(make_stacked_repo stack-fix)"
trunk="$(git -C "$project" branch --show-current)"
env_log="$fixture_root/stack-fix-env.log"
fix_logs="$fixture_root/stack-fix-prompts"
mkdir -p "$fix_logs"
STUB_GH_DIR="$STUBS" STUB_ENV_LOG="$env_log" STUB_FIX_LOG_DIR="$fix_logs" \
	STUB_STACK_VERDICTS="changes-requested approved" run_loop "$project"
assert_exit_code 0 "$rc" "blocking findings fixed in their layers, then re-approved, exit 0"
assert_eq "w/01-slice w/02-slice" "$(tr '\n' ' ' < "$fix_logs/order" | sed 's/ $//')" "each affected layer is fixed once, bottom first"
assert_eq "2" "$(commits_between "$project" "$trunk" w/01-slice)" "layer 1 gets exactly one fix commit on top of its issue commit"
assert_eq "2" "$(commits_between "$project" w/01-slice w/02-slice)" "and so does layer 2"
assert_contains "$(git -C "$project" log -1 --format=%B w/01-slice)" "Review: issues/reviews/stack.md" "layer 1's fix commit carries a Review: trailer naming the stack review"
assert_contains "$(git -C "$project" log -1 --format=%B w/02-slice)" "Review: issues/reviews/stack.md" "and so does layer 2's"
assert_ok "layer 2's branch contains layer 1's fix commit (it was rebased upstack)" \
	git -C "$project" merge-base --is-ancestor w/01-slice w/02-slice
assert_eq "2" "$(count_calls "$env_log" stack)" "the stack is reviewed exactly twice: once, then once more after the fixes"
second_verify="$(nth_line_of "$out" "all 2 layer(s) pass" 2)"
second_review="$(nth_line_of "$out" "stub: reviewed the stack" 2)"
assert_ok "pj-stack-verify runs again after the fixes, before the re-review" \
	test "${second_verify:-999999}" -lt "${second_review:-0}"
assert_contains "$(cat "$fix_logs/w_01-slice.prompt")" "STUB_DETAIL_LAYER1" "layer 1's fix prompt holds its own finding"
assert_not_contains "$(cat "$fix_logs/w_01-slice.prompt")" "STUB_DETAIL_LAYER2" "and not layer 2's"
assert_contains "$(cat "$fix_logs/w_02-slice.prompt")" "STUB_DETAIL_LAYER2" "layer 2's fix prompt holds its own finding"
assert_not_contains "$(cat "$fix_logs/w_02-slice.prompt")" "STUB_DETAIL_LAYER1" "and not layer 1's"
assert_not_contains "$(cat "$fix_logs/w_02-slice.prompt")" "STUB_STACK_NOTE" "notes are never handed to a fixer"
assert_eq "w/02-slice" "$(git -C "$project" branch --show-current)" "the run ends on the top layer"
assert_eq "" "$(git -C "$project" status --porcelain)" "with a clean tree"

# A fixer that commits anyway is rewound, so its layer still ends with exactly
# one fix commit -- the one this loop made, with the Review: trailer.
project="$(make_stacked_repo stack-fix-eager)"
trunk="$(git -C "$project" branch --show-current)"
STUB_GH_DIR="$STUBS" STUB_FIX_MODE=eagercommit STUB_STACK_VERDICTS="changes-requested approved" run_loop "$project"
assert_exit_code 0 "$rc" "a fixer that commits anyway doesn't fail the fix phase"
assert_contains "$out" "the fix on w/01-slice was committed despite the instruction not to -- rewinding" "its premature commit is rewound"
assert_eq "2" "$(commits_between "$project" "$trunk" w/01-slice)" "the layer still gets exactly one fix commit"
assert_contains "$(git -C "$project" log -1 --format=%B w/01-slice)" "Review: issues/reviews/stack.md" "and it's the loop's own, with the Review: trailer"

project="$(make_stacked_repo stack-fix-conflict)"
fix_logs="$fixture_root/stack-fix-conflict-prompts"
mkdir -p "$fix_logs"
STUB_GH_DIR="$STUBS" STUB_FIX_LOG_DIR="$fix_logs" STUB_FIX_MODE=conflict \
	STUB_STACK_VERDICTS="changes-requested approved" run_loop "$project"
assert_exit_code 1 "$rc" "a failing gh stack rebase stops the run with exit 1"
assert_contains "$out" "gh stack rebase --upstack --no-trunk" "naming the command that failed"
assert_eq "w/01-slice" "$(tr '\n' ' ' < "$fix_logs/order" | sed 's/ $//')" "before the next layer's fix runs"

# Each bad-owner review also holds a valid layer-1 finding, and would approve
# on a re-review: without the owner check, layer 1 would be fixed, the bad
# finding dropped, and the run would end green.
for mode in nolayer unknown; do
	project="$(make_stacked_repo "stack-fix-$mode")"
	env_log="$fixture_root/stack-fix-$mode-env.log"
	STUB_GH_DIR="$STUBS" STUB_ENV_LOG="$env_log" STUB_STACK_VERDICTS="changes-requested approved" \
		STUB_STACK_FINDINGS="$mode" run_loop "$project"
	assert_exit_code 1 "$rc" "a blocking finding with a bad owner ($mode) stops the run"
	assert_eq "0" "$(count_calls "$env_log" stackfix)" "before any fix agent runs ($mode)"
	assert_eq "1" "$(count_calls "$env_log" stack)" "and before any re-review ($mode)"
	case "$mode" in
		nolayer) assert_contains "$out" "'STUB_ORPHAN_FINDING' has no 'Layer:' line" "the stop names the finding with no owner" ;;
		unknown) assert_contains "$out" "names 'w/99-missing', which isn't a branch of this stack" "the stop names the unknown owner" ;;
	esac
done

project="$(make_stacked_repo stack-fix-none)"
env_log="$fixture_root/stack-fix-none-env.log"
STUB_GH_DIR="$STUBS" STUB_ENV_LOG="$env_log" STUB_STACK_VERDICT=changes-requested STUB_STACK_FINDINGS=none run_loop "$project"
assert_exit_code 1 "$rc" "changes requested with no blocking finding stops the run"
assert_contains "$out" "names no [blocking] finding" "and says so"
assert_eq "0" "$(count_calls "$env_log" stackfix)" "without running a fixer"

# A gate that goes red only once layer 1's fix exists: every earlier gate,
# the sweep and pj-stack-verify run before any fix and pass.
project="$(make_stacked_repo stack-fix-red-gate)"
fix_logs="$fixture_root/stack-fix-red-gate-prompts"
mkdir -p "$fix_logs"
STUB_GH_DIR="$STUBS" STUB_FIX_LOG_DIR="$fix_logs" STUB_STACK_VERDICTS="changes-requested approved" \
	run_loop "$project" --test-cmd 'test ! -f stub-fix-w_01-slice.txt'
assert_exit_code 1 "$rc" "a red gate after a fix stops the run"
assert_contains "$out" "is failing after the fix on w/01-slice" "naming the layer whose fix broke it"
assert_eq "w/01-slice" "$(tr '\n' ' ' < "$fix_logs/order" | sed 's/ $//')" "before the next layer's fix"

project="$(make_stacked_repo stack-fix-notes)"
env_log="$fixture_root/stack-fix-notes-env.log"
STUB_GH_DIR="$STUBS" STUB_ENV_LOG="$env_log" STUB_STACK_VERDICT=approved STUB_STACK_FINDINGS=notes run_loop "$project"
assert_exit_code 0 "$rc" "a stack review with only notes approves the run"
assert_eq "0" "$(count_calls "$env_log" stackfix)" "and no fix agent runs"

project="$(make_stacked_repo stack-review-partial)"
env_log="$fixture_root/stack-review-partial-env.log"
STUB_GH_DIR="$STUBS" STUB_ENV_LOG="$env_log" run_loop "$project" --max-issues 1
assert_exit_code 0 "$rc" "a stacked run stopped by --max-issues still exits 0"
assert_eq "0" "$(count_calls "$env_log" stack)" "it sends no stack review while plan issues are open"
assert_contains "$out" "still has open issues" "and says that's why"

project="$(make_repo stack-review-unstacked 1)"
env_log="$fixture_root/stack-review-unstacked-env.log"
STUB_ENV_LOG="$env_log" run_loop "$project"
assert_exit_code 0 "$rc" "an unstacked run completes"
assert_eq "0" "$(count_calls "$env_log" stack)" "an unstacked run sends no stack review"
assert_contains "$(cat "$project"/issues/runs/*/run.log)" "pj-review verdict for 001-slice.md" \
	"the run log says which issue each verdict was for"

stak_color="$(phase_color_of stak)"
assert_eq "$(printf '\033[1m\033[36m')" "$stak_color" "stak is bold cyan in phase_color"
for label in tdd rev qual fix gate git loop; do
	assert_ok "stak's color differs from $label's" test "$stak_color" != "$(phase_color_of "$label")"
done

# --- docs ---

assert_contains "$readme_flat" "stack mode" "the README describes stack mode"
assert_contains "$readme_flat" "gh stack init --base" "including how it creates the first layer"
assert_contains "$header_flat" "Stack mode" "the script header describes stack mode"
assert_contains "$header_flat" "isn't approved" "and its refusals"
assert_contains "$readme_flat" "pj-review-stack" "the README describes the whole-stack review"
assert_contains "$readme_flat" "in the layer that owns it" "and its fix phase"
assert_contains "$header_flat" "exactly one re-review" "the script header describes the fix phase"
assert_contains "$header_flat" "pj-review-stack" "and so does the script header"

assert_report
