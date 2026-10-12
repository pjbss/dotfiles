#!/bin/bash
# broker_e2e_test.sh
#
# End-to-end tests for the credential broker (issue 024): spawn resolves the
# chosen profiles' tokens for the task's proxy only, and the guest gets
# placeholders; --no-creds resolves and sends nothing; an unbrokered profile's
# real token, and only that one, goes to the guest with a warning; and
# `status --json` says which is which.
#
# Runs a copy of pj-sandbox (so a fixture profile can be marked unbrokered)
# with stub `limactl`, `ssh`, `mitmdump`, `security` and `gh`. The stubs
# `security` and `gh` hand out fixture tokens and log every call. Everything
# `ssh` and `limactl shell` are given, argv and stdin, is "the stream sent to
# the guest". The stub mitmdump saves its environment, which is how the proxy
# gets its tokens.

set -euo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PJ_SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"
. "$TEST_DIR/../../test/assert.sh"
. "$TEST_DIR/stub_proxy.sh"

fixture="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "$fixture"' EXIT

unset PJ_SANDBOX_STATE_DIR PJ_SANDBOX_SSH_INCLUDE_FILE PJ_SANDBOX_SSH_CONFIG_FILE \
	PJ_SANDBOX_PORT_MIN PJ_SANDBOX_PORT_MAX PJ_SANDBOX_INSTANCE_PREFIX PJ_SANDBOX_TEMPLATES_DIR \
	PJ_SANDBOX_PROXY_HOST XDG_STATE_HOME XDG_CONFIG_HOME GIT_CONFIG_GLOBAL GIT_DIR GIT_WORK_TREE \
	GH_TOKEN GITHUB_TOKEN
export HOME="$fixture/home"
export STUB_DIR="$fixture/stub"
export PJ_SANDBOX_PROXY_SETTLE=0.2
STATE_DIR="$HOME/.local/state/pj-sandbox"
mkdir -p "$HOME/.ssh" "$HOME/.claude" "$fixture/bin" "$STUB_DIR"

cp -R "$PJ_SANDBOX_DIR" "$fixture/pjsb"
CLI="$fixture/pjsb/bin/pj-sandbox"

git init -q "$fixture/repo"
git -C "$fixture/repo" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m first
cd "$fixture/repo"

# The fixture tokens. gh and copilot come from the Keychain; claude's Keychain
# item is missing, so its file source is used, the way a host without the
# Keychain item works.
TOKEN_GH="fixture-gh-token-0451"
TOKEN_COPILOT="fixture-copilot-token-7720"
TOKEN_CLAUDE="fixture-claude-token-3189"
TOKENS="$TOKEN_GH $TOKEN_COPILOT $TOKEN_CLAUDE"
printf '%s\n' "$TOKEN_CLAUDE" > "$HOME/.claude/sandbox-oauth-token"

cat > "$fixture/bin/limactl" <<'STUB'
#!/bin/sh
case "$1" in
	start)
		shift
		printf '%s\n' "${2#--name=}" >> "$STUB_DIR/instances"
		;;
	ls)
		for name in "$@"; do :; done
		printf 'Host lima-%s\n  Hostname 127.0.0.1\n  Port 61022\n' "$name" > "$STUB_DIR/$name.ssh.config"
		echo "$STUB_DIR/$name.ssh.config"
		;;
	list)
		[ -f "$STUB_DIR/instances" ] || exit 0
		while read -r name; do
			printf '{"name":"%s","status":"Running"}\n' "$name"
		done < "$STUB_DIR/instances"
		;;
	copy) ;;
	shell)
		printf '%s\n' "$*" >> "$STUB_DIR/guest-stream"
		cat >> "$STUB_DIR/guest-stream"
		;;
	*) exit 3 ;;
esac
STUB
cat > "$fixture/bin/ssh" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_DIR/guest-stream"
cat >> "$STUB_DIR/guest-stream"
STUB
chmod +x "$fixture/bin/limactl" "$fixture/bin/ssh"
pj_test_stub_proxy "$fixture/bin"
# After the shared stubs, so these replace its always-failing gh and security.
cat > "$fixture/bin/security" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "\$STUB_DIR/token-calls"
[ "\$1" = find-generic-password ] || exit 1
case "\$*" in
	*"-s pj-sandbox -a gh -w"*) echo "$TOKEN_GH" ;;
	*"-s pj-sandbox -a copilot -w"*) echo "$TOKEN_COPILOT" ;;
	*) exit 44 ;;
esac
STUB
cat > "$fixture/bin/gh" <<'STUB'
#!/bin/sh
printf 'gh %s\n' "$*" >> "$STUB_DIR/token-calls"
exit 1
STUB
chmod +x "$fixture/bin/security" "$fixture/bin/gh"
export PJ_SANDBOX_DOTFILES_HOME="$fixture/repo"
export PATH="$fixture/bin:$PATH"

meta_get() { sed -n "s/^$2=//p" "$STATE_DIR/$1/meta"; }
proxy_env() { cat "$STUB_DIR/mitmdump-env.$(meta_get "$1" proxy_pid)"; }
reset_stream() { : > "$STUB_DIR/guest-stream"; : > "$STUB_DIR/token-calls"; }
# creds TASK: `status --json`'s creds object, as profile=state lines.
creds() {
	"$CLI" status "$1" --json | python3 -c '
import json, sys
for k, v in sorted(json.load(sys.stdin)["creds"].items()):
    print("%s=%s" % (k, v))'
}

# --- brokered: placeholders to the guest, tokens to the proxy only ---

reset_stream
if out="$("$CLI" spawn alpha --base none 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "spawn exits 0 (output: $out)"
stream="$(cat "$STUB_DIR/guest-stream")"
for p in gh claude copilot; do
	assert_contains "$stream" "pjsb-placeholder-$p" "the guest is sent the $p placeholder"
done
for t in $TOKENS; do
	assert_not_contains "$stream" "$t" "the guest is never sent fixture token $t"
done
env_alpha="$(proxy_env alpha)"
assert_contains "$env_alpha" "PJSB_TOKEN_PJSB_PLACEHOLDER_GH=$TOKEN_GH" "the proxy's environment holds the gh token"
assert_contains "$env_alpha" "PJSB_TOKEN_PJSB_PLACEHOLDER_COPILOT=$TOKEN_COPILOT" "the proxy's environment holds the copilot token"
assert_contains "$env_alpha" "PJSB_TOKEN_PJSB_PLACEHOLDER_CLAUDE=$TOKEN_CLAUDE" "the proxy's environment holds the claude token (from its file source)"
for t in $TOKENS; do
	assert_not_contains "$(cat "$STUB_DIR/mitmdump-calls")" "$t" "the proxy's argv never holds $t"
	assert_eq "" "$(grep -rlF -- "$t" "$STATE_DIR" || true)" "no file in the state dir holds $t"
done
assert_not_contains "$out" "unbrokered" "a fully brokered spawn warns of nothing unbrokered"
assert_eq "$(printf 'claude=brokered\ncopilot=brokered\ngh=brokered')" "$(creds alpha)" \
	"status --json reports every default profile as brokered"

# The guest's environment carries the placeholders into its login file.
assert_contains "$stream" "GH_TOKEN='pjsb-placeholder-gh'" "the guest env assigns GH_TOKEN its placeholder"
assert_contains "$stream" "CLAUDE_CODE_OAUTH_TOKEN='pjsb-placeholder-claude'" "the guest env assigns CLAUDE_CODE_OAUTH_TOKEN its placeholder"

# --- git's credential helper returns the gh placeholder ---

# gh's post-bootstrap.sh, run against a scratch git config the way the guest
# runs it, then asked for github.com credentials from a login environment.
helper_home="$fixture/helper-home"
mkdir -p "$helper_home"
HOME="$helper_home" sh "$PJ_SANDBOX_DIR/profiles/gh/post-bootstrap.sh"
filled="$(printf 'protocol=https\nhost=github.com\n\n' |
	HOME="$helper_home" GH_TOKEN=pjsb-placeholder-gh GIT_TERMINAL_PROMPT=0 git credential fill 2>&1 || true)"
assert_contains "$filled" "password=pjsb-placeholder-gh" "git's credential helper returns the gh placeholder"
assert_contains "$stream" "credential" "gh's post-bootstrap (the credential helper) is sent to the guest"
filled="$(printf 'protocol=https\nhost=github.com\n\n' |
	HOME="$helper_home" GIT_TERMINAL_PROMPT=0 git credential fill 2>&1 || true)"
assert_not_contains "$filled" "password=" "with no GH_TOKEN (--no-creds), the helper returns no password"

# --- --no-creds: no sources, no placeholders, an empty inject set ---

reset_stream
if out="$("$CLI" spawn beta --base none --no-creds 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "spawn --no-creds exits 0 (output: $out)"
assert_eq "" "$(cat "$STUB_DIR/token-calls")" "--no-creds calls no token source"
assert_not_contains "$(cat "$STUB_DIR/guest-stream")" "pjsb-placeholder-" "--no-creds sends the guest no placeholder"
assert_not_contains "$(proxy_env beta)" "PJSB_TOKEN_" "--no-creds gives the proxy no token"
assert_eq "[]" "$(python3 -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1]))))' "$STATE_DIR/beta/policy/inject.json")" \
	"--no-creds starts the proxy with an empty inject set"
assert_contains "$(cat "$STUB_DIR/guest-stream")" "NODE_EXTRA_CA_CERTS=" "--no-creds still sends the guest its CA settings"
assert_eq "$(printf 'claude=none\ncopilot=none\ngh=none')" "$(creds beta)" "status --json reports none for every profile under --no-creds"

# --- --agent alone grants nothing beyond its profiles ---

reset_stream
"$CLI" spawn gamma --base none --agent gh >/dev/null 2>&1
assert_eq "gh=brokered" "$(creds gamma)" "--agent gh reports only gh, brokered"
assert_not_contains "$(proxy_env gamma)" "PJSB_TOKEN_PJSB_PLACEHOLDER_CLAUDE" "--agent gh resolves no claude token"
assert_not_contains "$(cat "$STUB_DIR/guest-stream")" "pjsb-placeholder-claude" "--agent gh sends no claude placeholder"

reset_stream
"$CLI" spawn delta --base none --agent gh --no-creds >/dev/null 2>&1
assert_eq "gh=none" "$(creds delta)" "--agent gh --no-creds reports gh as none"
assert_eq "" "$(cat "$STUB_DIR/token-calls")" "--agent gh --no-creds calls no token source"

# --- a profile with no inject rules has no credential ---

mkdir -p "$fixture/pjsb/profiles/plain"
for f in provision.sh allowlist; do : > "$fixture/pjsb/profiles/plain/$f"; done
printf '[]\n' > "$fixture/pjsb/profiles/plain/inject.json"
printf 'PLAIN_SETTING=1\n' > "$fixture/pjsb/profiles/plain/guest-env"
"$CLI" spawn epsilon --base none --agent plain,gh >/dev/null 2>&1
assert_eq "$(printf 'gh=brokered\nplain=none')" "$(creds epsilon)" "a profile with no inject rules reports none"
rm -rf "$fixture/pjsb/profiles/plain"

# --- unbrokered: only that profile's real token reaches the guest ---

touch "$fixture/pjsb/profiles/copilot/unbrokered"
reset_stream
if out="$("$CLI" spawn zeta --base none 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "spawn with an unbrokered profile exits 0 (output: $out)"
assert_contains "$out" "warning" "spawn warns when a profile is unbrokered"
assert_contains "$out" "'copilot'" "the warning names the unbrokered profile"
assert_not_contains "$out" "'gh'" "the warning names no brokered profile"
stream="$(cat "$STUB_DIR/guest-stream")"
assert_contains "$stream" "COPILOT_GITHUB_TOKEN='$TOKEN_COPILOT'" "the unbrokered profile's real token reaches the guest"
assert_not_contains "$stream" "pjsb-placeholder-copilot" "the unbrokered profile's placeholder isn't sent"
assert_not_contains "$stream" "$TOKEN_GH" "a brokered profile's token still never reaches the guest"
assert_not_contains "$stream" "$TOKEN_CLAUDE" "the claude token still never reaches the guest"
assert_contains "$stream" "pjsb-placeholder-gh" "brokered profiles still get placeholders"
assert_not_contains "$(cat "$STATE_DIR/zeta/policy/inject.json")" "pjsb-placeholder-copilot" "the unbrokered profile's inject rules aren't given to the proxy"
assert_not_contains "$(proxy_env zeta)" "$TOKEN_COPILOT" "the proxy isn't handed the unbrokered profile's token"
assert_eq "" "$(grep -rlF -- "$TOKEN_COPILOT" "$STATE_DIR" || true)" "the unbrokered token is written to no file in the state dir"
assert_eq "$(printf 'claude=brokered\ncopilot=unbrokered\ngh=brokered')" "$(creds zeta)" \
	"status --json reports the unbrokered profile as unbrokered"

reset_stream
"$CLI" spawn eta --base none --no-creds >/dev/null 2>&1
assert_eq "" "$(cat "$STUB_DIR/token-calls")" "--no-creds resolves no token for an unbrokered profile either"
assert_eq "$(printf 'claude=none\ncopilot=none\ngh=none')" "$(creds eta)" "--no-creds reports an unbrokered profile as none"

assert_report
