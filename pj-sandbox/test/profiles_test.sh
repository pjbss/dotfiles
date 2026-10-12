#!/bin/bash
# profiles_test.sh
#
# Tests for agent profiles (pj-sandbox/profiles/, lib/profiles.sh): `spawn
# --agent` renders only the chosen profiles' provisioning, merges their
# policy files into the task's policy/ dir and records them; an unknown name
# is refused; every default profile's guest-env holds only placeholders and
# the CA paths its tools need to trust the proxy;
# Claude's post-bootstrap seeds its onboarding keys; the profiles agree with
# the CA spike's findings on which agents can be brokered; and the core never
# names an agent. spawn runs through the real dispatcher with stub `limactl` and
# `ssh`, the same way spawn_test.sh does.

set -euo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PJ_SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"
. "$TEST_DIR/../../test/assert.sh"
. "$TEST_DIR/stub_proxy.sh"

CLI="$PJ_SANDBOX_DIR/bin/pj-sandbox"
PROFILES="$PJ_SANDBOX_DIR/profiles"

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

unset PJ_SANDBOX_STATE_DIR PJ_SANDBOX_SSH_INCLUDE_FILE PJ_SANDBOX_SSH_CONFIG_FILE \
	PJ_SANDBOX_PORT_MIN PJ_SANDBOX_PORT_MAX PJ_SANDBOX_INSTANCE_PREFIX PJ_SANDBOX_TEMPLATES_DIR \
	XDG_STATE_HOME XDG_CONFIG_HOME GIT_CONFIG_GLOBAL GIT_DIR GIT_WORK_TREE
export HOME="$fixture/home"
export STUB_DIR="$fixture/stub"
STATE_DIR="$HOME/.local/state/pj-sandbox"
mkdir -p "$HOME/.ssh" "$fixture/bin" "$STUB_DIR"
git init -q "$fixture/repo"
git -C "$fixture/repo" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m first
cd "$fixture/repo"

cat > "$fixture/bin/limactl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_DIR/calls"
case "$1" in
	start)
		for last in "$@"; do :; done
		cp "$last" "$STUB_DIR/rendered.yaml"
		;;
	ls)
		for name in "$@"; do :; done
		printf 'Host lima-%s\n  Port 61022\n' "$name" > "$STUB_DIR/$name.ssh.config"
		echo "$STUB_DIR/$name.ssh.config"
		;;
	copy) ;;
	shell) cat > /dev/null ;;
	*) exit 3 ;;
esac
STUB
chmod +x "$fixture/bin/limactl"
# Each ssh call's stdin is kept, so the scripts piped to the guest can be
# checked.
cat > "$fixture/bin/ssh" <<'STUB'
#!/bin/sh
n="$(ls "$STUB_DIR" | grep -c '^ssh-stdin-' || true)"
printf '%s\n' "$*" >> "$STUB_DIR/ssh-calls"
cat > "$STUB_DIR/ssh-stdin-$n"
STUB
chmod +x "$fixture/bin/ssh"
export PJ_SANDBOX_DOTFILES_HOME="$fixture/repo"
# spawn starts the task's proxy; a stub stands in for mitmdump.
pj_test_stub_proxy "$fixture/bin"
export PJ_SANDBOX_PROXY_SETTLE=0
export PATH="$fixture/bin:$PATH"

# indented FILE
#
# FILE's content as it appears inside a rendered `script: |` block.
indented() { sed 's/^/    /' "$1"; }

# entries FILE
#
# FILE's allowlist entries: no comments, no blank lines.
entries() { grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$1" || true; }

# --- the default profiles exist and are complete ---

assert_eq "$(printf '%s\n' claude copilot gh)" "$(ls -1 "$PROFILES")" "the default profiles are claude, copilot and gh"
for p in claude copilot gh; do
	for f in provision.sh allowlist inject.json guest-env; do
		assert_ok "profiles/$p has $f" test -s "$PROFILES/$p/$f"
	done
done

# --- --agent gh,claude ---

if out="$("$CLI" spawn two --base none --agent gh,claude 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "spawn --agent gh,claude exits 0 (output: $out)"
rendered="$(cat "$STUB_DIR/rendered.yaml")"
assert_contains "$rendered" "$(cat "$PJ_SANDBOX_DIR/lima/core-provision.yaml")" "the core provision step is rendered"
assert_contains "$rendered" "$(indented "$PROFILES/gh/provision.sh")" "gh's provision.sh is rendered"
assert_contains "$rendered" "$(indented "$PROFILES/claude/provision.sh")" "claude's provision.sh is rendered"
assert_not_contains "$rendered" "$(indented "$PROFILES/copilot/provision.sh")" "copilot's provision.sh isn't rendered"
assert_not_contains "$rendered" "@github/copilot" "nothing installs the copilot CLI"
assert_eq "1" "$(printf '%s\n' "$rendered" | grep -c '^provision:$')" "everything lands under one provision: key"
if python3 -c 'import yaml' 2>/dev/null; then
	got="$(printf '%s\n' "$rendered" | python3 -c '
import sys, yaml
c = yaml.safe_load(sys.stdin)
print(c["mounts"])
print(" ".join(p["mode"] for p in c["provision"]))
')"
	assert_eq "$(printf '%s\n' '[]' 'system system system')" "$got" "the config parses as YAML: core, gh and claude provision items, no mounts"
fi

assert_eq "agents=gh,claude" "$(grep '^agents=' "$STATE_DIR/two/meta")" "the record holds agents=gh,claude"

policy="$STATE_DIR/two/policy"
assert_eq "$({ entries "$PROFILES/gh/allowlist"; entries "$PROFILES/claude/allowlist"; } | awk '!seen[$0]++')" \
	"$(cat "$policy/allowlist")" "policy/allowlist is gh's then claude's entries, comments and repeats dropped"
if command -v python3 >/dev/null 2>&1; then
	got="$(python3 -c '
import json, sys
merged = json.load(open(sys.argv[1]))
want = json.load(open(sys.argv[2])) + json.load(open(sys.argv[3]))
print(merged == want)
print(sorted(set(k for r in merged for k in r)))
' "$policy/inject.json" "$PROFILES/gh/inject.json" "$PROFILES/claude/inject.json")"
	assert_eq "$(printf '%s\n' True "['header', 'host', 'placeholder', 'scheme', 'token_source']")" "$got" \
		"policy/inject.json is gh's rules then claude's, as one JSON array of {host, header, scheme, placeholder, token_source}"
fi
assert_not_contains "$(cat "$policy/inject.json")" "pjsb-placeholder-copilot" "policy/inject.json has no copilot rule"

# Claude's post-bootstrap.sh is piped to the guest after the bootstrap.
assert_contains "$(cat "$STUB_DIR"/ssh-stdin-*)" "$(cat "$PROFILES/claude/post-bootstrap.sh")" "claude's post-bootstrap.sh is piped to the guest"
last="$(ls "$STUB_DIR" | grep '^ssh-stdin-' | sort -t- -k3 -n | tail -1)"
assert_eq "$(cat "$PROFILES/claude/post-bootstrap.sh")" "$(cat "$STUB_DIR/$last")" "it runs after the bootstrap"
assert_eq "sh -s" "$(tail -1 "$STUB_DIR/ssh-calls" | awk '{print $(NF-1), $NF}')" "it runs as 'sh -s', with nothing in argv"
rm -f "$STUB_DIR"/ssh-stdin-*

# --- the default is every profile ---

"$CLI" spawn all --base none >/dev/null 2>&1
assert_eq "agents=claude,copilot,gh" "$(grep '^agents=' "$STATE_DIR/all/meta")" "with no --agent every profile is selected"
rendered="$(cat "$STUB_DIR/rendered.yaml")"
for p in claude copilot gh; do
	assert_contains "$rendered" "$(indented "$PROFILES/$p/provision.sh")" "the default renders $p's provision.sh"
done
rm -f "$STUB_DIR"/ssh-stdin-*

# --- --agent gh runs no post-bootstrap ---

"$CLI" spawn ghonly --base none --agent gh >/dev/null 2>&1
assert_not_contains "$(cat "$STUB_DIR"/ssh-stdin-*)" "hasCompletedOnboarding" "--agent gh pipes no claude post-bootstrap"
assert_eq "$(entries "$PROFILES/gh/allowlist" | awk '!seen[$0]++')" "$(cat "$STATE_DIR/ghonly/policy/allowlist")" "--agent gh writes only gh's allowlist"

# --- template and repo allowlists (where `allowlist suggest --write` saves) ---

mkdir -p "$fixture/templates/withlist" "$(git rev-parse --git-common-dir)/pj-sandbox"
printf 'echo hi\n' > "$fixture/templates/withlist/provision.yaml"
printf 'template.example  # 4 requests\ngithub.com\n' > "$fixture/templates/withlist/allowlist"
printf '# from allowlist suggest\nrepo.example  # 2 requests\n' > "$(git rev-parse --git-common-dir)/pj-sandbox/allowlist"
if out="$(PJ_SANDBOX_TEMPLATES_DIR="$fixture/templates" "$CLI" spawn listed --base withlist --agent gh 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "spawn with a template allowlist and a repo allowlist exits 0 (output: $out)"
assert_eq "$(entries "$PROFILES/gh/allowlist" | awk '!seen[$0]++'; printf 'template.example\nrepo.example')" \
	"$(cat "$STATE_DIR/listed/policy/allowlist")" "spawn merges the template's then the repo's allowlist after the profiles', comments and repeats dropped"
rm -rf "$(git rev-parse --git-common-dir)/pj-sandbox"
rm -f "$STUB_DIR"/ssh-stdin-*

# --- unknown or malformed --agent ---

: > "$STUB_DIR/calls"
for agents in bogus gh,bogus "" gh, ,gh "gh,,claude" ../gh; do
	if out="$("$CLI" spawn bad --base none --agent "$agents" 2>&1)"; then rc=0; else rc=$?; fi
	assert_exit_code 1 "$rc" "--agent '$agents' exits 1"
	assert_contains "$out" "$(printf 'Available --agent names:\n  claude\n  copilot\n  gh')" "--agent '$agents' lists the valid profiles"
done
out="$("$CLI" spawn bad --base none --agent gh,bogus 2>&1 || true)"
assert_contains "$out" "unknown agent profile 'bogus'" "the unknown name is named"
assert_eq "" "$(cat "$STUB_DIR/calls")" "a refused --agent never calls limactl"
assert_ok "a refused --agent leaves no state dir" test ! -e "$STATE_DIR/bad"
assert_contains "$("$CLI" spawn --help 2>&1)" "--agent" "spawn --help mentions --agent"

# --- guest-env holds only placeholders and CA paths ---

# The CA settings guest-env may hold, and the only values they may take: the
# proxy CA's certificate (lib/bootstrap.sh installs it there) or the system
# bundle update-ca-certificates rebuilds with it.
GUEST_CA=/usr/local/share/ca-certificates/pjsb.crt
GUEST_BUNDLE=/etc/ssl/certs/ca-certificates.crt
for p in claude copilot gh; do
	lines="$(entries "$PROFILES/$p/guest-env")"
	assert_ok "profiles/$p/guest-env has at least one KEY=value line" test -n "$lines"
	while IFS= read -r line; do
		case "$line" in
			[A-Za-z_]*=pjsb-placeholder-*) ok=true ;;
			NODE_EXTRA_CA_CERTS="$GUEST_CA") ok=true ;;
			SSL_CERT_FILE="$GUEST_BUNDLE" | GIT_SSL_CAINFO="$GUEST_BUNDLE") ok=true ;;
			*) ok=false ;;
		esac
		assert_ok "$p guest-env '$line' is a placeholder or a CA path" "$ok"
	done <<< "$lines"
done

# Node agents only read NODE_EXTRA_CA_CERTS; gh (Go) and git (OpenSSL) are
# pointed at the rebuilt system bundle, as in the CA spike
# (docs/spike-ca.md).
for p in claude copilot; do
	assert_contains "$(entries "$PROFILES/$p/guest-env")" "NODE_EXTRA_CA_CERTS=$GUEST_CA" \
		"$p guest-env points NODE_EXTRA_CA_CERTS at the proxy CA"
done
assert_contains "$(entries "$PROFILES/gh/guest-env")" "SSL_CERT_FILE=$GUEST_BUNDLE" "gh guest-env sets SSL_CERT_FILE"
assert_contains "$(entries "$PROFILES/gh/guest-env")" "GIT_SSL_CAINFO=$GUEST_BUNDLE" "gh guest-env sets GIT_SSL_CAINFO"

# --- the profiles agree with the CA spike's findings ---

# docs/spike-ca.md's Results table says, per check, whether that agent can be
# brokered. A profile whose agent can't be carries an `unbrokered` file. None
# does today. Marking one means building the fallback too: forward its token
# as a real secret, ignore its inject.json, and flag it in status --json and
# verify.
SPIKE_CA="$PJ_SANDBOX_DIR/docs/spike-ca.md"
findings="$(awk '/^## Findings$/ { on = 1; next } /^## / { on = 0 } on && NF' "$SPIKE_CA")"
assert_ok "docs/spike-ca.md has a non-empty ## Findings section" test -n "$findings"

# check|verdict, one per Results row.
verdicts="$(awk -F'|' '
	/^## Results$/ { on = 1; next }
	/^## / { on = 0 }
	on && /^\| `/ {
		check = $2; verdict = $(NF - 1)
		gsub(/[ `]/, "", check); gsub(/ /, "", verdict)
		print check "|" verdict
	}
' "$SPIKE_CA")"
assert_eq "claude claude-long copilot gh git" "$(printf '%s\n' "$verdicts" | cut -d'|' -f1 | paste -sd ' ' -)" \
	"spike-ca.md's Results table has a row per check"
while IFS='|' read -r check verdict; do
	case "$check" in
		claude | claude-long) p=claude ;;
		copilot) p=copilot ;;
		gh | git) p=gh ;;
		*) p="" ;;
	esac
	assert_ok "spike-ca.md check '$check' maps to a profile" test -n "$p"
	case "$verdict" in
		brokered) assert_not_ok "$p is brokered ('$check'), so it has no unbrokered file" test -e "$PROFILES/$p/unbrokered" ;;
		unbrokered) assert_ok "$p is unbrokered ('$check'), so it has an unbrokered file" test -e "$PROFILES/$p/unbrokered" ;;
		*) assert_ok "spike-ca.md check '$check' says brokered or unbrokered, not '$verdict'" false ;;
	esac
done <<< "$verdicts"

# --- claude's post-bootstrap seeds onboarding ---

if command -v python3 >/dev/null 2>&1; then
	guest="$fixture/guest"
	mkdir -p "$guest/home" "$guest/bin"
	printf '#!/bin/sh\necho "9.8.7 (Claude Code)"\n' > "$guest/bin/claude"
	chmod +x "$guest/bin/claude"
	printf '{"keep": "me"}\n' > "$guest/home/.claude.json"
	HOME="$guest/home" PATH="$guest/bin:$PATH" sh "$PROFILES/claude/post-bootstrap.sh"
	got="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get("hasCompletedOnboarding"), d.get("bypassPermissionsModeAccepted"), d.get("lastOnboardingVersion"), d.get("keep"))
' "$guest/home/.claude.json")"
	assert_eq "True True 9.8.7 me" "$got" "post-bootstrap seeds both onboarding keys and keeps existing ones"

	rm -f "$guest/home/.claude.json"
	HOME="$guest/home" PATH="$guest/bin:$PATH" sh "$PROFILES/claude/post-bootstrap.sh"
	got="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get("hasCompletedOnboarding"), d.get("bypassPermissionsModeAccepted"))
' "$guest/home/.claude.json")"
	assert_eq "True True" "$got" "post-bootstrap creates ~/.claude.json when there is none"
else
	echo "profiles_test: python3 missing, skipping the post-bootstrap checks" >&2
fi

# --- the core never names an agent ---

assert_eq "" "$(grep -rniE 'claude|copilot|anthropic' "$PJ_SANDBOX_DIR/lib" "$PJ_SANDBOX_DIR/bin" || true)" \
	"no file under lib/ or bin/ names an agent (claude, copilot, anthropic, CLAUDE_)"

assert_report
