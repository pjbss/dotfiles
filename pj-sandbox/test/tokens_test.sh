#!/bin/bash
# tokens_test.sh
#
# Tests for pj-sandbox/lib/tokens.sh: each placeholder's token sources
# (keychain:, cmd:, file:) are tried in order on the host and the first that
# yields a token wins; a source that yields nothing gives an empty token and
# a warning rather than a crash; and the resolved tokens reach only the
# process tokens_exec starts -- never a file under the state dir, nor the
# caller's environment. `security` and `gh` are stubs on PATH.

set -euo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PJ_SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"
. "$TEST_DIR/../../test/assert.sh"

if ! command -v python3 >/dev/null 2>&1; then
	echo "SKIP: python3 not found; tokens.sh reads inject.json through proxy/inject.py"
	exit 0
fi

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

unset PJSB_TOKEN_PJSB_PLACEHOLDER_GH PJSB_TOKEN_PJSB_PLACEHOLDER_CLAUDE STUB_KEYCHAIN STUB_GH
export HOME="$fixture/home"
export STUB_DIR="$fixture/stub"
export PJ_SANDBOX_STATE_DIR="$fixture/state"
mkdir -p "$HOME/.claude" "$fixture/bin" "$STUB_DIR" "$PJ_SANDBOX_STATE_DIR"

# security find-generic-password -s SERVICE -a ACCOUNT -w: prints
# $STUB_KEYCHAIN if it's set, else fails the way a missing item does.
cat > "$fixture/bin/security" <<'STUB'
#!/bin/sh
echo "security $*" >> "$STUB_DIR/calls"
[ -n "${STUB_KEYCHAIN:-}" ] || { echo "security: The specified item could not be found in the keychain." >&2; exit 44; }
printf '%s\n' "$STUB_KEYCHAIN"
STUB
cat > "$fixture/bin/gh" <<'STUB'
#!/bin/sh
echo "gh $*" >> "$STUB_DIR/calls"
[ -n "${STUB_GH:-}" ] || { echo "gh: not logged in" >&2; exit 1; }
printf '%s\n' "$STUB_GH"
STUB
chmod +x "$fixture/bin/security" "$fixture/bin/gh"
export PATH="$fixture/bin:$PATH"

# tk SCRIPT
#
# Runs SCRIPT in a fresh sh with tokens.sh sourced, so the library is
# exercised under POSIX sh rather than this file's bash.
tk() {
	PJ_SANDBOX_HOME="$PJ_SANDBOX_DIR" sh -c '. "$PJ_SANDBOX_HOME/lib/tokens.sh"; eval "$1"' sh "$1"
}

calls() {
	cat "$STUB_DIR/calls" 2>/dev/null || true
	rm -f "$STUB_DIR/calls"
}

GH_SOURCES='keychain:pj-sandbox/gh "cmd:gh auth token" file:~/.claude/sandbox-oauth-token'

# --- the sources are tried in order ---

got="$(STUB_KEYCHAIN=kc-token STUB_GH=gh-token tk "pj_sandbox_token_resolve $GH_SOURCES")"
assert_eq "kc-token" "$got" "keychain comes first when it has the item"
assert_eq "security find-generic-password -s pj-sandbox -a gh -w" "$(calls)" \
	"keychain:SERVICE/ACCOUNT asks security for that item, and nothing later is tried"

got="$(STUB_GH=gh-token tk "pj_sandbox_token_resolve $GH_SOURCES")"
assert_eq "gh-token" "$got" "with no keychain item, cmd:gh auth token is next"
assert_eq "$(printf '%s\n' "security find-generic-password -s pj-sandbox -a gh -w" "gh auth token")" "$(calls)" \
	"security is asked before gh"

printf 'file-token\n' > "$HOME/.claude/sandbox-oauth-token"
got="$(tk "pj_sandbox_token_resolve $GH_SOURCES")"
assert_eq "file-token" "$got" "with keychain and gh failing, file: (with ~ expanded) is last"
assert_eq "$(printf '%s\n' "security find-generic-password -s pj-sandbox -a gh -w" "gh auth token")" "$(calls)" \
	"every earlier source was tried first"

STUB_GH="" got="$(STUB_KEYCHAIN="" tk 'pj_sandbox_token_resolve "cmd:printf \"\"" "cmd:echo second"')"
assert_eq "second" "$got" "a source that prints nothing doesn't count as working"

# --- a missing source is an empty token and a warning ---

rm -f "$HOME/.claude/sandbox-oauth-token"
status=0
out="$(tk "pj_sandbox_token_resolve $GH_SOURCES" 2> "$fixture/err")" || status=$?
assert_eq 0 "$status" "no working source still exits 0"
assert_eq "" "$out" "no working source gives an empty token"
assert_contains "$(cat "$fixture/err")" "warning" "no working source warns"
assert_contains "$(cat "$fixture/err")" "keychain:pj-sandbox/gh" "the warning names the sources it tried"
calls > /dev/null

status=0
out="$(tk 'pj_sandbox_token_resolve "bogus:x" "keychain:no-slash"' 2> "$fixture/err")" || status=$?
assert_eq "0:" "$status:$out" "an unknown or malformed source is skipped, not a crash"
assert_contains "$(cat "$fixture/err")" "bogus:x" "a source of unknown kind is named in a warning"

# --- tokens reach only the exec'd process ---

policy="$PJ_SANDBOX_STATE_DIR/task1/policy"
mkdir -p "$policy"
cat > "$policy/inject.json" <<'JSON'
[
  {"host": "api.github.com", "header": "Authorization", "scheme": "bearer", "placeholder": "pjsb-placeholder-gh", "token_source": ["keychain:pj-sandbox/gh", "cmd:gh auth token"]},
  {"host": "github.com", "header": "Authorization", "scheme": "basic", "placeholder": "pjsb-placeholder-gh", "token_source": ["keychain:pj-sandbox/gh", "cmd:gh auth token"]},
  {"host": "api.anthropic.com", "header": "Authorization", "scheme": "bearer", "placeholder": "pjsb-placeholder-claude", "token_source": ["keychain:pj-sandbox/claude", "file:~/.claude/sandbox-oauth-token"]}
]
JSON
printf 'sk-ant-SECRET-claude\n' > "$HOME/.claude/sandbox-oauth-token"

# The stand-in proxy reports what it got as a pass/fail word, never the
# token itself, so nothing the test writes can hold one.
probe='[ "$PJSB_TOKEN_PJSB_PLACEHOLDER_GH" = ghp_SECRET_gh ] && [ "$PJSB_TOKEN_PJSB_PLACEHOLDER_CLAUDE" = sk-ant-SECRET-claude ] && echo both-tokens'
got="$(STUB_GH=ghp_SECRET_gh tk "pj_sandbox_tokens_exec '$policy' sh -c '$probe'")"
assert_eq "both-tokens" "$got" "tokens_exec hands each placeholder's token to the command it execs, in its environment"
assert_eq "$(printf '%s\n' "security find-generic-password -s pj-sandbox -a gh -w" "gh auth token" \
	"security find-generic-password -s pj-sandbox -a claude -w")" "$(calls)" \
	"each placeholder is resolved once, though two rules share gh's"

got="$(STUB_GH=ghp_SECRET_gh tk "pj_sandbox_tokens_exec '$policy' true; echo \"after:\${PJSB_TOKEN_PJSB_PLACEHOLDER_GH:-unset}\"")"
assert_eq "after:unset" "$got" "the caller's environment never gains a token"
calls > /dev/null

assert_eq "" "$(grep -rlF -e ghp_SECRET_gh -e sk-ant-SECRET-claude "$PJ_SANDBOX_STATE_DIR" || true)" \
	"no file under the state dir holds a token"

rm -f "$HOME/.claude/sandbox-oauth-token"
status=0
got="$(tk "pj_sandbox_tokens_exec '$policy' sh -c 'echo \"[\${PJSB_TOKEN_PJSB_PLACEHOLDER_GH-unset}]\"'" 2> "$fixture/err")" || status=$?
assert_eq "0:[]" "$status:$got" "with every source missing the command still runs, with an empty token"
assert_contains "$(cat "$fixture/err")" "warning" "and a warning"

status=0
tk "pj_sandbox_tokens_exec '$fixture/nowhere' true" 2> "$fixture/err" || status=$?
assert_eq 0 "$status" "a policy dir with no inject.json resolves nothing and still runs the command"

printf '[{}]\n' > "$policy/inject.json"
status=0
tk "pj_sandbox_tokens_exec '$policy' echo ran" > "$fixture/out" 2> "$fixture/err" || status=$?
assert_eq "1:" "$status:$(cat "$fixture/out")" "a malformed inject.json fails without running the command"

assert_report
