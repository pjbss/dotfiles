#!/bin/bash
# guest_auth_preamble_test.sh
#
# Tests how pj-sbx-spawn hands the host's forwarded credentials to the guest
# bootstrap script.
#
# These exist because of a real bug: the tokens used to travel as positional
# arguments (`ssh host sh -s -- "$gh_token" "$claude_token"`), and ssh does not
# preserve argument boundaries -- it joins its command argv into one string for
# the remote login shell to re-split, so an empty argument vanishes and every
# later one shifts down a slot. Under `--no-creds`, which deliberately leaves
# the gh token empty and is the documented setup for an unattended agent, the
# guest therefore received the *Claude* token as $1: it exported an Anthropic
# OAuth token as GH_TOKEN/GITHUB_TOKEN, and never set CLAUDE_CODE_OAUTH_TOKEN,
# so Claude Code in a fresh VM had no credential at all.
#
# The empty-gh-token case below is that exact regression, so the assertions
# deliberately check the *pairing* of value to variable, not just that some
# value arrived.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"
DOTFILES_HOME="$(cd -P "$SANDBOX_DIR/.." && pwd)"

. "$DOTFILES_HOME/test/assert.sh"
. "$SANDBOX_DIR/lib/task.sh"

# Evaluates a preamble the way the guest's `sh -s` does, and echoes the
# resulting variables in a form that makes a mis-slotted value obvious.
eval_preamble() {
	sh -c "$(sandbox_guest_auth_preamble "$1" "$2")"'
		printf "gh=[%s] claude=[%s]\n" "$gh_token_in" "$claude_token_in"
	'
}

# --- the regression: an empty gh token must not shift the Claude token ---

assert_eq "$(eval_preamble "" "sk-ant-oat01-CLAUDE")" \
	"gh=[] claude=[sk-ant-oat01-CLAUDE]" \
	"an empty gh token (what --no-creds forwards) leaves the Claude token in its own slot, rather than shifting it into the gh one"

# --- both present, the ordinary case ---

assert_eq "$(eval_preamble "gho_GHTOKEN" "sk-ant-oat01-CLAUDE")" \
	"gh=[gho_GHTOKEN] claude=[sk-ant-oat01-CLAUDE]" \
	"both tokens forwarded land in their own variables"

# --- the other empties ---

assert_eq "$(eval_preamble "gho_GHTOKEN" "")" \
	"gh=[gho_GHTOKEN] claude=[]" \
	"an empty Claude token (no ~/.claude/sandbox-oauth-token on the host) leaves the gh token alone"

assert_eq "$(eval_preamble "" "")" \
	"gh=[] claude=[]" \
	"both empty stays both empty, so the guest writes neither export"

# --- a token is an opaque string: it must survive verbatim ---

assert_eq "$(eval_preamble "tok'with\"quotes\$and\`ticks" "sk-ant")" \
	"gh=[tok'with\"quotes\$and\`ticks] claude=[sk-ant]" \
	"shell metacharacters in a token are passed through literally, not expanded or word-split"

# --- the preamble is assignments only: it must not execute anything ---

canary="$(sandbox_guest_auth_preamble 'x$(touch /tmp/pj-preamble-canary)' 'y')"
rm -f /tmp/pj-preamble-canary
sh -c "$canary" >/dev/null
assert_eq "$([ -e /tmp/pj-preamble-canary ] && echo executed || echo inert)" "inert" \
	"a command substitution embedded in a token value is never executed when the guest evaluates the preamble"

assert_eq "$(printf '%s\n' "$canary" | grep -c .)" "2" \
	"the preamble is exactly two lines, so it can be prepended to the bootstrap script without disturbing it"

assert_report
