#!/bin/bash
# pj_stack_verify_test.sh
#
# Integration tests for bin/pj-stack-verify: the test gate run on every layer
# of a stack, bottom to top, stopping at the first red one. Runs against the
# stub gh (agents/test/stubs/gh) in throwaway repositories; each layer's
# Makefile records which branch it ran on, so the tests can check order and
# that nothing ran past a failure.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
DOTFILES_HOME="$(cd -P "$TEST_DIR/../.." && pwd)"

. "$DOTFILES_HOME/test/assert.sh"

VERIFY="$DOTFILES_HOME/bin/pj-stack-verify"
STUBS="$TEST_DIR/stubs"

fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

# make_stack NAME BROKEN_LAYER -- a repo with a three-layer stack s/01-a,
# s/02-b, s/03-c whose `make test` logs the branch to $VERIFY_LOG and fails
# while a file named `broken` exists. BROKEN_LAYER (2, or 0 for none) adds it;
# layer 3 removes it again, so a verify that ran past a red layer would see
# green. Leaves s/03-c checked out; prints the repo path.
make_stack() {
	repo="$fixture_root/$1"
	git init -q -b main "$repo"
	git -C "$repo" config user.email test@example.com
	git -C "$repo" config user.name test
	printf 'test:\n\t@git branch --show-current >> "$$VERIFY_LOG"\n\t@echo "checking $$(git branch --show-current)"\n\t@test ! -f broken || { echo LAYER_BROKEN_DETAIL; exit 1; }\n' \
		> "$repo/Makefile"
	git -C "$repo" add Makefile
	git -C "$repo" commit -q -m init
	(
		cd "$repo"
		PATH="$STUBS:$PATH"
		gh stack init --base main s/01-a >/dev/null
		echo a > a.txt && git add a.txt && git commit -q -m a
		gh stack add s/02-b >/dev/null
		echo b > b.txt
		[ "$2" = 2 ] && echo x > broken
		git add -A && git commit -q -m b
		gh stack add s/03-c >/dev/null
		echo c > c.txt
		rm -f broken
		git add -A && git commit -q -m c
	)
	printf '%s\n' "$repo"
}

# verify REPO [ARGS...] -- runs pj-stack-verify from REPO with the stub gh
# first on PATH, leaving $out and $rc; the layers' runs go to $VERIFY_LOG.
verify() {
	local repo="$1"
	shift
	VERIFY_LOG="$fixture_root/$(basename "$repo").log"
	: > "$VERIFY_LOG"
	if out="$(cd "$repo" && PATH="${VERIFY_PATH:-$STUBS:$PATH}" VERIFY_LOG="$VERIFY_LOG" NO_COLOR=1 \
		"$VERIFY" "$@" </dev/null 2>&1)"; then rc=0; else rc=$?; fi
}

ran() { tr '\n' ' ' < "$VERIFY_LOG" | sed 's/ $//'; }
current() { git -C "$1" branch --show-current; }

# --- every layer green ---

repo="$(make_stack green 0)"
git -C "$repo" checkout -q s/02-b
verify "$repo"
assert_exit_code 0 "$rc" "a stack whose every layer passes exits 0"
assert_eq "s/01-a s/02-b s/03-c" "$(ran)" "the gate runs on every layer, bottom to top"
assert_eq "s/01-a s/02-b s/03-c" "$(printf '%s\n' "$out" | sed -n 's/^✓ \(s\/[^ ]*\).*/\1/p' | tr '\n' ' ' | sed 's/ $//')" \
	"one passing line per layer, bottom to top"
assert_eq "s/02-b" "$(current "$repo")" "the branch it started on is checked out again"

# --- a red middle layer ---

repo="$(make_stack red-middle 2)"
verify "$repo"
assert_exit_code 1 "$rc" "a failing layer exits 1"
assert_contains "$out" "✗ s/02-b" "the failing layer is named"
assert_contains "$out" "LAYER_BROKEN_DETAIL" "with the tail of its output"
assert_eq "s/01-a s/02-b" "$(ran)" "nothing runs above the first failing layer"
assert_eq "s/03-c" "$(current "$repo")" "the starting branch is restored after a failure"

# --- --test-cmd overrides the resolved gate ---

repo="$(make_stack override 2)"
verify "$repo" --test-cmd 'git branch --show-current >> "$VERIFY_LOG"'
assert_exit_code 0 "$rc" "--test-cmd replaces the failing make test"
assert_eq "s/01-a s/02-b s/03-c" "$(ran)" "the override still runs on every layer"
verify "$repo" --test-cmd
assert_exit_code 1 "$rc" "--test-cmd without a command is refused"

# --- a gate that dirties the tree ---

# Checking out the next layer would carry the change into its run (or fail),
# so the run stops on the layer that did it.
repo="$(make_stack dirtying 0)"
verify "$repo" --test-cmd 'git branch --show-current >> "$VERIFY_LOG"; echo junk >> Makefile'
assert_exit_code 1 "$rc" "a gate that leaves the tree dirty stops the run"
assert_contains "$out" "left the working tree dirty on s/01-a" "the layer whose gate dirtied the tree is named"
assert_eq "s/01-a" "$(ran)" "no later layer runs on top of the change"

# A restore that can't happen is said out loud, never swallowed: here layer
# 1's gate creates c.txt, which s/03-c tracks, so checking s/03-c out fails.
repo="$(make_stack unrestorable 0)"
verify "$repo" --test-cmd 'echo stray > c.txt'
assert_exit_code 1 "$rc" "the run still fails"
assert_contains "$out" "couldn't check s/03-c back out" "a failed restore is reported"
assert_contains "$out" "still on s/01-a" "with where the user actually is"

# --- each layer's gate runs as the full sweep ---

# A clean layer checkout has no changed set, so a gate that runs only what
# changed (pj-affected-tests) would pass having run nothing.
repo="$(make_stack scoped 0)"
verify "$repo" --test-cmd '[ "${PJ_TEST_SCOPE:-}" = all ]'
assert_exit_code 0 "$rc" "each layer's gate runs with PJ_TEST_SCOPE=all"

# --- refusals ---

repo="$(make_stack dirty 0)"
echo stray > "$repo/stray.txt"
verify "$repo"
assert_exit_code 1 "$rc" "a dirty tree is refused"
assert_contains "$out" "dirty" "the refusal says why"
assert_eq "" "$(ran)" "no layer is checked out or run over a dirty tree"

repo="$(make_stack offstack 0)"
git -C "$repo" checkout -q -b loose main
verify "$repo"
assert_exit_code 1 "$rc" "a branch outside any stack is refused"
assert_contains "$out" "not part of a stack" "the refusal relays why"

no_stack="$fixture_root/no-stack-bin"
mkdir -p "$no_stack"
printf '#!/bin/sh\necho "unknown command \\"stack\\" for \\"gh\\"" >&2\nexit 1\n' > "$no_stack/gh"
chmod +x "$no_stack/gh"
repo="$(make_stack nogh 0)"
VERIFY_PATH="$no_stack:$PATH" verify "$repo"
assert_exit_code 1 "$rc" "a gh without the stack extension is refused"
assert_contains "$out" "gh stack" "the refusal names what's missing"

# --- discoverable ---

assert_contains "$("$DOTFILES_HOME/bin/pj-help" 2>&1)" "pj-stack-verify" "pj-help lists pj-stack-verify"
verify "$repo" --help
assert_contains "$out" "Usage: pj-stack-verify" "--help prints the usage header"
assert_contains "$(cat "$DOTFILES_HOME/README")" "pj-stack-verify" "the README mentions pj-stack-verify"

assert_report
