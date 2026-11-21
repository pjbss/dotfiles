#!/bin/bash
# stub_gh_test.sh
#
# Tests for agents/test/stubs/gh, the stand-in for GitHub's gh-stack
# extension (v0.3.0) that the stack-mode tests run against. It works over real
# git branches, so what it gets wrong would quietly make those tests prove the
# wrong thing; the behaviours they lean on are pinned here against what the
# real extension does: layer order in `view --json` (bottom first), refusing
# `add` anywhere but the top, and `rebase --upstack --no-trunk` really moving
# the layers above.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
DOTFILES_HOME="$(cd -P "$TEST_DIR/../.." && pwd)"

. "$DOTFILES_HOME/test/assert.sh"

GH="$TEST_DIR/stubs/gh"

fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

repo="$fixture_root/repo"
git init -q -b main "$repo"
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test
git -C "$repo" commit -q --allow-empty -m init

# gh ARGS... -- runs the stub in the repo, leaving $out and $rc.
gh() {
	if out="$(cd "$repo" && "$GH" "$@" </dev/null 2>&1)"; then rc=0; else rc=$?; fi
}

# commit_file NAME -- one commit adding NAME on the current branch.
commit_file() {
	printf '%s\n' "$1" > "$repo/$1"
	git -C "$repo" add "$1"
	git -C "$repo" commit -q -m "add $1"
}

current() { git -C "$repo" branch --show-current; }

# --- versions ---

gh --version
assert_exit_code 0 "$rc" "gh --version succeeds"
gh stack --version
assert_contains "$out" "gh stack version" "gh stack --version names the extension"

# --- building a stack ---

gh stack init --base main s/01-a
assert_exit_code 0 "$rc" "init creates the first layer"
assert_eq "s/01-a" "$(current)" "init checks the new branch out"
commit_file a.txt
gh stack add s/02-b
assert_exit_code 0 "$rc" "add on the top layer succeeds"
commit_file b.txt
gh stack add s/03-c
assert_eq "s/03-c" "$(current)" "add checks the new layer out"

gh stack view --json
assert_exit_code 0 "$rc" "view --json succeeds on a stack branch"
names="$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(b["name"] for b in d["branches"]))')"
assert_eq "s/01-a s/02-b s/03-c" "$names" "view --json lists layers bottom first, as the real extension does"
assert_eq "main" "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["trunk"])')" "view --json names the trunk"
assert_eq "s/03-c" "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["currentBranch"])')" "view --json names the current branch"

# --- add only at the top ---

gh stack checkout s/01-a
assert_exit_code 0 "$rc" "checkout moves to a layer"
assert_eq "s/01-a" "$(current)" "checkout really switches branches"
gh stack add s/zz
assert_exit_code 5 "$rc" "add below the top is refused with the real extension's exit code"
assert_contains "$out" "can only add branches to the top of the stack" "and its message"
assert_not_ok "the refused add creates no branch" git -C "$repo" rev-parse --verify --quiet refs/heads/s/zz

gh stack top
assert_eq "s/03-c" "$(current)" "top checks out the top layer"

# --- rebase --upstack --no-trunk ---

gh stack checkout s/01-a
commit_file fix.txt
new_commit="$(git -C "$repo" rev-parse HEAD)"
gh stack rebase --upstack --no-trunk
assert_exit_code 0 "$rc" "rebase --upstack --no-trunk succeeds"
assert_eq "s/01-a" "$(current)" "rebase leaves the starting branch checked out"
for layer in s/02-b s/03-c; do
	assert_ok "$layer now contains the lower layer's new commit" \
		git -C "$repo" merge-base --is-ancestor "$new_commit" "$layer"
done
assert_ok "s/03-c still contains s/02-b's own work" git -C "$repo" cat-file -e s/03-c:b.txt

gh stack rebase
assert_exit_code 1 "$rc" "a rebase the stub doesn't model is refused rather than faked"

# --- off the stack ---

git -C "$repo" checkout -q -b loose main
gh stack view --json
assert_exit_code 2 "$rc" "view on a branch outside the stack fails like the real extension"
assert_contains "$out" 'current branch "loose" is not part of a stack' "with its message"
git -C "$repo" checkout -q main
gh stack view --json
assert_exit_code 0 "$rc" "view on the trunk succeeds, as the real one does"

# --- unknown commands, and the call log ---

gh stack frobnicate
assert_exit_code 1 "$rc" "an unknown stack subcommand exits non-zero"
gh pr list
assert_exit_code 1 "$rc" "a gh command outside stack exits non-zero"

log="$(cat "$(git -C "$repo" rev-parse --absolute-git-dir)/stub-gh.log")"
assert_contains "$log" "stack init --base main s/01-a" "every call is logged with its arguments"
assert_contains "$log" "stack rebase --upstack --no-trunk" "including the rebase"

assert_report
