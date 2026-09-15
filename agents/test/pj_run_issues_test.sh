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
while [ $# -gt 0 ]; do
	case "$1" in
		-p) prompt="${2:-}"; shift 2 ;;
		*) shift ;;
	esac
done

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
		echo "stub: reviewed $issue_name -> ${STUB_VERDICT:-approved}"
		;;

	*"requested changes to your"*)
		echo "remediated" >> "stub-work-${issue_name%.md}.txt"
		git add -A
		git commit -q --amend --no-edit
		echo "stub: remediated $issue_name"
		;;

	*"pj-tdd skill"*)
		case "${STUB_MODE:-normal}" in
			partial)
				echo "stub: left $issue_name in issues/ for a human"
				exit 0
				;;
			nocommit)
				echo "did work" >> "stub-work-${issue_name%.md}.txt"
				mkdir -p issues/done
				mv "$issue_file" "issues/done/$issue_name"
				echo "stub: worked on $issue_name but made no commit"
				exit 0
				;;
		esac

		echo "did work" >> "stub-work-${issue_name%.md}.txt"
		mkdir -p issues/done
		mv "$issue_file" "issues/done/$issue_name"
		git add -A
		git commit -q -m "Implement ${issue_name%.md}

Stub implementation.

Issue: issues/$issue_name"
		echo "stub: implemented and committed $issue_name"
		;;
esac
STUB
chmod +x "$stub_bin/claude"

# make_repo NAME ISSUE_COUNT -> echoes the repo path
make_repo() {
	local repo="$fixture_root/$1"
	mkdir -p "$repo/issues"
	git -C "$repo" init -q
	git -C "$repo" config user.email test@example.com
	git -C "$repo" config user.name test

	printf 'test:\n\t@true\n' > "$repo/Makefile"
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
		cat > "$repo/issues/$number-slice.md" <<-ISSUE
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
	echo "$repo"
}

# run_loop REPO [ARGS...]
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

assert_report
