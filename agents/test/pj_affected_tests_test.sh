#!/bin/bash
# pj_affected_tests_test.sh
#
# End-to-end tests for bin/pj-affected-tests, driving throwaway git repos that
# hold several package suites. Each fixture suite appends its own name to a
# shared log when it runs, so a test can see exactly which suites ran and in
# what order, and fails when a `fail` file sits beside its Makefile.
#
# Everything happens under a tmpdir; $HOME is untouched.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
DOTFILES_HOME="$(cd -P "$TEST_DIR/../.." && pwd)"

. "$DOTFILES_HOME/test/assert.sh"

AFFECTED="$DOTFILES_HOME/bin/pj-affected-tests"

fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

export LOG="$fixture_root/ran.log"

# add_suite REPO DIR -- a Makefile at REPO/DIR whose `test` target logs DIR.
add_suite() {
	mkdir -p "$1/$2"
	printf 'test:\n\t@echo %s >> "$(LOG)"\n\t@test ! -f fail\n' "$2" > "$1/$2/Makefile"
}

# new_repo NAME [SUITE_DIR...] -- a committed repo with a suite in each DIR.
new_repo() {
	repo="$fixture_root/$1"
	shift
	mkdir -p "$repo"
	git -C "$repo" init -q
	git -C "$repo" config user.email test@example.com
	git -C "$repo" config user.name test
	printf 'readme\n' > "$repo/README"
	for dir in "$@"; do
		add_suite "$repo" "$dir"
		printf 'src\n' > "$repo/$dir/src.txt"
	done
	git -C "$repo" add -A
	git -C "$repo" commit -qm init
	printf '%s' "$repo"
}

# run_affected REPO [ARG...] -- runs the command from REPO with a fresh log;
# sets $out, $rc and $ran (the logged suite names, space-separated).
run_affected() {
	dir="$1"
	shift
	rm -f "$LOG"
	: > "$LOG"
	if out="$(cd "$dir" && "$AFFECTED" "$@" 2>&1)"; then rc=0; else rc=$?; fi
	ran="$(tr '\n' ' ' < "$LOG" | sed 's/ $//')"
}

# --- one package -------------------------------------------------------------

repo="$(new_repo one pkg/a pkg/b)"
printf 'changed\n' >> "$repo/pkg/a/src.txt"
run_affected "$repo"
assert_exit_code 0 "$rc" "a green single-package change exits 0"
assert_eq "pkg/a" "$ran" "a change confined to one package runs only that suite"

# --- several packages --------------------------------------------------------

repo="$(new_repo two pkg/a pkg/b pkg/c)"
printf 'changed\n' >> "$repo/pkg/c/src.txt"
printf 'changed\n' >> "$repo/pkg/a/src.txt"
run_affected "$repo"
assert_eq "pkg/a pkg/c" "$ran" "a change spanning two packages runs both suites, in sorted order"

repo="$(new_repo dedupe pkg/a pkg/b)"
printf 'changed\n' >> "$repo/pkg/a/src.txt"
mkdir -p "$repo/pkg/a/deep"
printf 'x\n' > "$repo/pkg/a/deep/one.txt"
git -C "$repo" add pkg/a/deep/one.txt
git -C "$repo" commit -qm deep
printf 'changed\n' >> "$repo/pkg/a/deep/one.txt"
printf 'changed\n' >> "$repo/pkg/a/Makefile.inc"
run_affected "$repo"
assert_eq "pkg/a" "$ran" "a suite is run once, not once per changed file within it"

# pkg/a/src.txt maps to pkg/a and pkg/z.txt to pkg, so the order the changes are
# listed in is the reverse of the sorted order of the suites they select.
repo="$(new_repo sorted pkg pkg/a)"
printf 'changed\n' >> "$repo/pkg/a/src.txt"
printf 'new\n' > "$repo/pkg/z.txt"
run_affected "$repo"
assert_eq "pkg pkg/a" "$ran" "suites run in a stable, sorted order, each path selecting its nearest suite"

# --- untracked files ---------------------------------------------------------

repo="$(new_repo untracked pkg/a pkg/b)"
printf 'new\n' > "$repo/pkg/b/brand-new.txt"
run_affected "$repo"
assert_eq "pkg/b" "$ran" "an untracked new file selects the suite covering it"

# A whole new package is one untracked directory, which plain porcelain output
# reports as "pkg/c/" rather than as the files inside it.
repo="$(new_repo untracked-pkg pkg/a)"
add_suite "$repo" pkg/c/inner
printf 'new\n' > "$repo/pkg/c/inner/src.txt"
run_affected "$repo"
assert_eq "pkg/c/inner" "$ran" "a file inside a new untracked directory selects the suite covering it"

# The loop stages everything before gating, so a moved file shows up as one
# rename entry naming both ends -- and both packages were changed by it.
repo="$(new_repo renamed pkg/a pkg/b pkg/c)"
git -C "$repo" mv pkg/a/src.txt pkg/b/moved.txt
run_affected "$repo"
assert_eq "pkg/a pkg/b" "$ran" "a staged rename selects the suites on both sides of it"

# --- failing suites ----------------------------------------------------------

repo="$(new_repo failing pkg/a pkg/b pkg/c)"
touch "$repo/pkg/a/fail" "$repo/pkg/b/fail"
printf 'changed\n' >> "$repo/pkg/c/src.txt"
run_affected "$repo"
assert_exit_code 1 "$rc" "two failing suites exit non-zero"
assert_contains "$out" "FAILED: pkg/a" "the first failing suite is reported"
assert_contains "$out" "FAILED: pkg/b" "the second failing suite is reported"
assert_not_contains "$out" "FAILED: pkg/c" "a passing suite is not reported as failing"
assert_eq "pkg/a pkg/b pkg/c" "$ran" "a failing suite does not prevent later suites from running"

# A suite is someone else's code; one that happens to read stdin must not
# swallow the list of suites still waiting to run.
repo="$(new_repo stdin pkg/a pkg/b)"
printf 'test:\n\t@cat > /dev/null\n\t@echo pkg/a >> "$(LOG)"\n' > "$repo/pkg/a/Makefile"
printf 'changed\n' >> "$repo/pkg/b/src.txt"
run_affected "$repo"
assert_eq "pkg/a pkg/b" "$ran" "a suite reading stdin does not consume the suites after it"

# --- nothing covers the change -----------------------------------------------

repo="$(new_repo root-fallback . pkg/a)"
printf 'changed\n' >> "$repo/README"
run_affected "$repo"
assert_exit_code 0 "$rc" "a change covered only by the root suite exits 0"
assert_eq "." "$ran" "a change mapping to no package suite falls back to the root suite"

repo="$(new_repo root-clean . pkg/a)"
run_affected "$repo"
assert_eq "." "$ran" "a clean tree falls back to the root suite when there is one"

repo="$(new_repo uncovered pkg/a)"
printf 'changed\n' >> "$repo/README"
run_affected "$repo"
assert_exit_code 0 "$rc" "a change no suite covers, with no root suite, exits 0"
assert_contains "$out" "no suite covers" "a change no suite covers says so rather than passing silently"
assert_eq "" "$ran" "a change no suite covers runs nothing"

repo="$(new_repo clean pkg/a)"
run_affected "$repo"
assert_exit_code 0 "$rc" "a clean tree with no root suite exits 0"
assert_contains "$out" "no suite covers" "a clean tree takes the no-suite-covers-it path"

# Said on stdout specifically: a gate's stderr is the stream most likely to be
# thrown away, and this message is the whole defense against a silent pass.
stdout_only="$(cd "$repo" && "$AFFECTED" 2>/dev/null)"
assert_contains "$stdout_only" "no suite covers" "the no-suite message is on stdout"

# --- PJ_TEST_SCOPE=all -------------------------------------------------------

repo="$(new_repo scope-all pkg/a pkg/b deep/er/pkg/c)"
printf 'changed\n' >> "$repo/pkg/a/src.txt"
PJ_TEST_SCOPE=all run_affected "$repo"
assert_exit_code 0 "$rc" "PJ_TEST_SCOPE=all exits 0 when every suite passes"
assert_eq "deep/er/pkg/c pkg/a pkg/b" "$ran" "PJ_TEST_SCOPE=all runs every discoverable suite regardless of what changed"

repo="$(new_repo scope-all-clean pkg/a pkg/b)"
PJ_TEST_SCOPE=all run_affected "$repo"
assert_eq "pkg/a pkg/b" "$ran" "PJ_TEST_SCOPE=all runs every suite over a clean tree too"

repo="$(new_repo vendored pkg/a)"
for vendored in .git node_modules venv .venv vendor target build dist; do
	add_suite "$repo" "pkg/a/$vendored/dep"
done
add_suite "$repo" "node_modules/top"
PJ_TEST_SCOPE=all run_affected "$repo"
assert_eq "pkg/a" "$ran" "vendored directories are pruned from discovery"

# The same files, untracked, as a working-tree change: each belongs to pkg/a,
# not to the vendored suite sitting nearer to it.
run_affected "$repo"
assert_eq "pkg/a" "$ran" "a change inside a vendored directory selects the suite owning it, not the vendored one"

repo="$(new_repo scope-all-none)"
PJ_TEST_SCOPE=all run_affected "$repo"
assert_exit_code 0 "$rc" "PJ_TEST_SCOPE=all with no suites anywhere exits 0"
assert_contains "$out" "no suite covers" "PJ_TEST_SCOPE=all with no suites anywhere says so"

# --- --since REF --------------------------------------------------------------

repo="$(new_repo since pkg/a pkg/b pkg/c)"
git -C "$repo" branch base
printf 'changed\n' >> "$repo/pkg/b/src.txt"
git -C "$repo" commit -qam "change b"
printf 'loose\n' >> "$repo/pkg/c/src.txt"
run_affected "$repo" --since base
assert_exit_code 0 "$rc" "--since exits 0 when its suites pass"
assert_eq "pkg/b" "$ran" "--since REF selects suites from what changed against REF, not the working tree"

run_affected "$repo" --since
assert_exit_code 1 "$rc" "--since without a REF is refused"

run_affected "$repo" --since no-such-ref
assert_exit_code 1 "$rc" "--since a REF that doesn't exist is refused rather than read as no change"
assert_contains "$out" "no-such-ref" "the unknown REF is named in the refusal"

run_affected "$repo" --bogus
assert_exit_code 1 "$rc" "an unknown argument is refused"
assert_contains "$out" "--bogus" "an unknown argument is named in the refusal"

# --- help ---------------------------------------------------------------------

run_affected "$repo" --help
assert_exit_code 0 "$rc" "--help exits 0"
assert_contains "$out" "Usage: pj-affected-tests" "--help prints the header's Usage line"
assert_contains "$out" "PJ_TEST_SCOPE" "--help documents PJ_TEST_SCOPE"
assert_eq "" "$ran" "--help runs no suite"

help_output="$("$DOTFILES_HOME/bin/pj-help")"
assert_contains "$help_output" "pj-affected-tests" "pj-help lists pj-affected-tests"

assert_report
