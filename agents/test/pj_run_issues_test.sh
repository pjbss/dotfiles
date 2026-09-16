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
# pj-tdd does for a human-only criterion, "nocommit" does the work but never
# commits.
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

case "$prompt" in
	*"pj-review skill"*)
		mkdir -p issues/reviews
		printf 'Verdict: %s\n\n## Findings\n\nstub review\n' "${STUB_VERDICT:-approved}" \
			> "issues/reviews/${issue_name%.md}.md"
		say_stub "stub: reviewed $issue_name -> ${STUB_VERDICT:-approved}"
		;;

	*"requested changes to your"*)
		echo "remediated" >> "stub-work-${issue_name%.md}.txt"
		git add -A
		git commit -q --amend --no-edit
		say_stub "stub: remediated $issue_name"
		;;

	*"pj-tdd skill"*)
		case "${STUB_MODE:-normal}" in
			partial)
				say_stub "stub: left $issue_name in issues/ for a human"
				exit 0
				;;
			nocommit)
				echo "did work" >> "stub-work-${issue_name%.md}.txt"
				mkdir -p issues/done
				mv "$issue_file" "issues/done/$issue_name"
				say_stub "stub: worked on $issue_name but made no commit"
				exit 0
				;;
		esac

		# What the loop handed this invocation, so the tests can assert on
		# the environment and prompt a real agent would have received.
		{
			echo "PJ_TEST_DIR=${PJ_TEST_DIR:-unset}"
			echo "$prompt"
		} > "stub-call-${issue_name%.md}.txt"

		echo "did work" >> "stub-work-${issue_name%.md}.txt"
		mkdir -p issues/done
		mv "$issue_file" "issues/done/$issue_name"
		git add -A
		git commit -q -m "Implement ${issue_name%.md}

Stub implementation.

Issue: issues/$issue_name"
		say_stub "stub: implemented and committed $issue_name"
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
assert_contains "$out" "make test in" "the gate announces itself before running, so a slow suite doesn't look like a hang"
assert_contains "$out" "pass" "a green gate says so on that same line"
assert_contains "$out" "issues/prd.md" "a subagent's tool call is rendered too"
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

# === an issue that produced no commit =======================================

repo="$(make_repo nocommit 2)"
STUB_MODE=nocommit run_loop "$repo"
unset STUB_MODE
assert_contains "$out" "produced no commit" "a missing commit stops the run"
assert_contains "$out" "next issue" "the message explains the risk of folding work into a later commit"
assert_eq "1" "$(git -C "$repo" log --oneline | wc -l | tr -d ' ')" "nothing is committed when the implementation step didn't commit"

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

# === finding the `make test` gate ===========================================

# The PRD and issues sit at the top, where the paths written in them resolve,
# while the suite belongs to one subproject -- the shape that used to fail the
# preflight outright.
project="$(make_repo autodiscover 1 "" backend)"
run_loop "$project"
assert_exit_code 0 "$rc" "a single nested 'make test' target is found without being named"
assert_contains "$out" "gating on the 'make test' target in backend" \
	"the run says which suite it settled on"
assert_contains "$(cat "$project/stub-call-001-slice.txt")" "make -C backend test" \
	"the agent is told where to run the suite, since there is none at its cwd"
assert_contains "$(cat "$project/stub-call-001-slice.txt")" "PJ_TEST_DIR=$project/backend" \
	"the Stop hook is pointed at the same suite, so the red-test gate isn't silently skipped"

project="$(make_repo ambiguous 1 "" backend)"
mkdir -p "$project/frontend"
printf 'test:\n\t@true\n' > "$project/frontend/Makefile"
git -C "$project" add -A
git -C "$project" commit -q -m "add a second suite"
run_loop "$project"
assert_exit_code 1 "$rc" "two candidate suites are refused rather than guessed between"
assert_contains "$out" "--test-dir" "the ambiguity refusal names the flag that resolves it"
assert_contains "$out" "backend" "the ambiguity refusal lists the candidates it found"
assert_contains "$out" "frontend" "the ambiguity refusal lists all of them"

run_loop "$project" --test-dir backend
assert_exit_code 0 "$rc" "--test-dir resolves the ambiguity"
assert_contains "$out" "gating on the 'make test' target in backend" "--test-dir picks that suite"

project="$(make_repo badtestdir 1)"
run_loop "$project" --test-dir nowhere
assert_exit_code 1 "$rc" "--test-dir pointing at nothing is refused"
assert_contains "$out" "not a directory" "the refusal says the directory doesn't exist"

mkdir -p "$project/empty"
run_loop "$project" --test-dir empty
assert_exit_code 1 "$rc" "--test-dir pointing at a directory with no test target is refused"
assert_contains "$out" "no Makefile with a 'test' target" \
	"the refusal says what was missing, rather than falling back to the root Makefile"

run_loop "$project" --test-dir
assert_exit_code 1 "$rc" "--test-dir with no value is refused instead of crashing the shell"
assert_contains "$out" "needs a directory" "the refusal says what --test-dir wants"

# === a red suite in the subdirectory stops the run ==========================

# The point of resolving the gate at all: it has to be able to fail. A run that
# gates on the wrong Makefile -- or on none -- is an unattended run with no gate.
project="$(make_repo redgate 2 "" backend)"
printf 'test:\n\t@echo GATE_DETAIL_LINE; exit 1\n' > "$project/backend/Makefile"
git -C "$project" add -A
git -C "$project" commit -q -m "make the suite red"
run_loop "$project"
assert_contains "$out" "make test is failing" "a red suite in the gate directory stops the run"
assert_contains "$out" "GATE_DETAIL_LINE" \
	"a red gate prints the output on the spot -- the reason the run stopped shouldn't need a log dive"
assert_not_ok "the next issue is never started" test -f "$project/stub-work-002-slice.txt"

# === --plain, the escape hatch ==============================================

# For the one failure this repo can't control: a claude release whose
# stream-json schema the renderer doesn't understand yet.
repo="$(make_repo plain 1)"
run_loop "$repo" --plain
assert_exit_code 0 "$rc" "--plain exits 0"
assert_contains "$out" "stub: implemented and committed" "--plain prints the agent's final message"
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

assert_report
