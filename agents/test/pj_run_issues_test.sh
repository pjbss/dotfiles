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
		*"pj-review skill"*) call=review ;;
		*"pj-commit skill"*) call=commit ;;
		*"requested changes to your"*) call=remediate ;;
		*"pj-tdd skill"*) call=tdd ;;
		*) call=other ;;
	esac
	printf '%s PJ_TEST_DIR=%s PJ_TEST_CMD=%s PJ_PROJECT_ROOT=%s\n' "$call" \
		"${PJ_TEST_DIR:-unset}" "${PJ_TEST_CMD:-unset}" "${PJ_PROJECT_ROOT:-unset}" \
		>> "$STUB_ENV_LOG"
fi

case "$prompt" in
	*"pj-review skill"*)
		mkdir -p issues/reviews
		# Both sections, in the shape pj-review's SKILL.md specifies, so the
		# tests can tell which of them the loop puts on the console.
		cat > "issues/reviews/${issue_name%.md}.md" <<VERDICT
Verdict: ${STUB_VERDICT:-approved}

## Reviewed

\`issues/$issue_name\`, \`make test\`: STUB_SUITE_PASSED

## Findings

1. **STUB_FINDING_LABEL** -- \`src/stub.sh:41\`
   STUB_FINDING_DETAIL
VERDICT
		say_stub "stub: reviewed $issue_name -> ${STUB_VERDICT:-approved}"
		;;

	*"pj-commit skill"*)
		git add -A
		git commit -q -m "Implement ${issue_name%.md}

Stub implementation.

Issue: issues/$issue_name"
		say_stub "stub: committed $issue_name"
		;;

	*"requested changes to your"*)
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
run_loop() {
	local repo="$1"
	shift
	if out="$(cd "$repo" && PATH="$stub_bin:$PATH" \
		PJ_SANDBOX_MARKER="$marker" \
		STUB_MODE="${STUB_MODE:-normal}" STUB_VERDICT="${STUB_VERDICT:-approved}" \
		NO_COLOR=1 "$RUN_ISSUES" "$@" 2>&1)"; then
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
assert_contains "$out" "one remediation pass" "the loop attempts exactly one remediation"
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
assert_contains "$(cat "$project/stub-call-001-slice.txt")" "'make -C backend test'" \
	"the agent is told the command, since there is no suite at its cwd"
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
STUB_ENV_LOG="$env_log" STUB_VERDICT=changes-requested PJ_TEST_DIR="$fixture_root/stale" \
	run_loop "$project"
for call in tdd review remediate; do
	assert_contains "$(cat "$env_log")" "$call PJ_TEST_DIR=unset PJ_TEST_CMD=make -C backend test PJ_PROJECT_ROOT=$project" \
		"the $call invocation gets PJ_TEST_CMD and PJ_PROJECT_ROOT, and no PJ_TEST_DIR"
done
project="$(make_repo everycommit 1 "" backend)"
env_log="$fixture_root/everycommit-env.log"
STUB_ENV_LOG="$env_log" PJ_TEST_DIR="$fixture_root/stale" run_loop "$project"
assert_contains "$(cat "$env_log")" "commit PJ_TEST_DIR=unset PJ_TEST_CMD=make -C backend test PJ_PROJECT_ROOT=$project" \
	"the commit invocation gets PJ_TEST_CMD and PJ_PROJECT_ROOT, and no PJ_TEST_DIR"
assert_eq "0" "$(grep -vc "PJ_TEST_DIR=unset PJ_TEST_CMD=make -C backend test PJ_PROJECT_ROOT=$project\$" "$env_log" || true)" \
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

assert_report
