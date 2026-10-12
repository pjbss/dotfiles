#!/bin/bash
# spike_ca_test.sh
#
# Hermetic checks for the CA and pinning spike tooling
# (pj-sandbox/test/live/spike_ca.sh). The spike itself needs a real Mac host
# with Lima and real credentials, and is run by hand (MT-5 in
# issues/manual-tests.md). These tests prove its --help and --dry-run surfaces
# and its write-up skeleton, with `limactl` and `mitmdump` stubbed to fail
# loudly if they're called. They also prove that the real tokens reach only the
# host-side mitmdump process.

set -euo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PJ_SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"
. "$TEST_DIR/../../test/assert.sh"

SPIKE="$PJ_SANDBOX_DIR/test/live/spike_ca.sh"
SPIKE_DOC="$PJ_SANDBOX_DIR/docs/spike-ca.md"

# The checks, by the label each is printed under.
CHECKS="claude claude-long copilot gh git"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- --help ---

if out="$("$SPIKE" --help 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "spike_ca.sh --help exits 0"
for c in $CHECKS; do
	assert_contains "$out" "[$c]" "--help names the '$c' check"
done
assert_contains "$out" "--dry-run" "--help documents --dry-run"

# --- argument errors ---

if out="$("$SPIKE" --bogus 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "an unknown argument exits 1"
assert_contains "$out" "unknown argument '--bogus'" "an unknown argument is named in the error"

# --- --dry-run ---

# limactl and mitmdump that record any call and fail, first on PATH.
fail_dir="$work/fail-bin"
mkdir -p "$fail_dir"
for tool in limactl mitmdump; do
	cat > "$fail_dir/$tool" <<STUB
#!/bin/sh
echo "$tool \$*" >> "$work/forbidden.calls"
echo "$tool stub: must not be called" >&2
exit 99
STUB
	chmod +x "$fail_dir/$tool"
done

if out="$(PATH="$fail_dir:$PATH" "$SPIKE" --dry-run --repo octo/private-thing 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "--dry-run exits 0"
assert_contains "$out" "$PJ_SANDBOX_DIR/lima/spike/ca.yaml" "--dry-run names its Lima config"
assert_contains "$out" "mounts: []" "--dry-run prints the Lima config's contents"
assert_contains "$out" "limactl start --tty=false --name=pjsb-spike-ca" "--dry-run prints the boot command"
assert_contains "$out" "openssl req" "--dry-run prints how the scratch CA is made"
assert_contains "$out" "update-ca-certificates" "--dry-run prints the guest trust-store install"
assert_contains "$out" "NODE_EXTRA_CA_CERTS=" "--dry-run sets NODE_EXTRA_CA_CERTS in the guest"
assert_contains "$out" "SSL_CERT_FILE=" "--dry-run sets SSL_CERT_FILE in the guest"
assert_contains "$out" "mitmdump " "--dry-run prints the mitmdump command"
assert_contains "$out" "def request" "--dry-run prints the mitmdump addon"
assert_contains "$out" "claude -p 'say ok'" "--dry-run prints the [claude] check"
assert_contains "$out" "[claude-long]" "--dry-run prints the [claude-long] check"
assert_contains "$out" "copilot -p 'say ok'" "--dry-run prints the [copilot] check"
assert_contains "$out" "gh api user" "--dry-run prints the [gh] check"
assert_contains "$out" "git ls-remote https://github.com/octo/private-thing" "--dry-run prints the [git] check against --repo"
assert_contains "$out" "limactl delete --force pjsb-spike-ca" "--dry-run prints the teardown"
assert_eq "" "$(cat "$work/forbidden.calls" 2>/dev/null || true)" "--dry-run never calls limactl or mitmdump"

# --- real tokens reach only the host-side mitmdump ---

# Sentinel "real" tokens: a fake HOME holding the Claude token file, and a gh
# whose `auth token` prints the GitHub one.
CLAUDE_SENTINEL="sk-ant-oat01-REAL-claude-sentinel-7f3a"
GH_SENTINEL="gho_REALghsentinel9b21"
fake_home="$work/home"
mkdir -p "$fake_home/.claude"
printf '%s\n' "$CLAUDE_SENTINEL" > "$fake_home/.claude/sandbox-oauth-token"
gh_dir="$work/gh-bin"
mkdir -p "$gh_dir"
cat > "$gh_dir/gh" <<STUB
#!/bin/sh
[ "\$1 \$2" = "auth token" ] && { echo "$GH_SENTINEL"; exit 0; }
exit 1
STUB
chmod +x "$gh_dir/gh"

# leaks TEXT: which sentinels TEXT contains, if any.
leaks() {
	case "$1" in *"$CLAUDE_SENTINEL"*) echo "claude-token" ;; esac
	case "$1" in *"$GH_SENTINEL"*) echo "gh-token" ;; esac
}

out="$(HOME="$fake_home" PATH="$fail_dir:$gh_dir:$PATH" "$SPIKE" --dry-run --repo octo/private-thing 2>&1)" || true
assert_contains "$out" "Claude ($fake_home/.claude/sandbox-oauth-token): found" "--dry-run reports the Claude token was found"
assert_contains "$out" "GitHub (gh auth token): found" "--dry-run reports the GitHub token was found"
assert_eq "" "$(leaks "$out")" "--dry-run output never contains a real token"
assert_contains "$out" "CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-pjsb-placeholder" "the guest gets the Claude placeholder"
assert_contains "$out" "GH_TOKEN=gho_pjsbplaceholder" "the guest gets the GitHub placeholder"

# Statically: no line of the script that touches a real-token variable also
# writes a file, prints, or talks to the guest.
bad="$(grep -nE '\breal_(claude|gh)\b|PJ_SPIKE_REAL_' "$SPIKE" | sed 's|2>/dev/null||g' | grep -E 'limactl|ssh|echo|printf|tee|cat|>' || true)"
assert_eq "" "$bad" "no line using a real token also writes, prints or reaches the guest"
assert_contains "$(grep -c 'exec mitmdump' "$SPIKE")" "1" "the real tokens are exported into a subshell that execs mitmdump"

# A live run against recording stubs. limactl logs its argv and stdin and also
# scans TMPDIR for a token on every call. mitmdump records only whether each
# token reached its environment or its argv. openssl is the real one.
rec_dir="$work/rec-bin"
mkdir -p "$rec_dir" "$work/tmp"
cat > "$rec_dir/limactl" <<STUB
#!/bin/sh
log="$work/limactl.log"
echo "ARGV: \$*" >> "\$log"
case "\$1" in
	list) exit 0 ;;
	shell) echo "STDIN:" >> "\$log"; cat >> "\$log" ;;
esac
grep -rlF -e "$CLAUDE_SENTINEL" -e "$GH_SENTINEL" "$work/tmp" >> "$work/file-leaks" 2>/dev/null || true
exit 0
STUB
cat > "$rec_dir/mitmdump" <<STUB
#!/bin/sh
{
	[ "\$PJ_SPIKE_REAL_CLAUDE" = "$CLAUDE_SENTINEL" ] && echo "env:claude"
	[ "\$PJ_SPIKE_REAL_GH" = "$GH_SENTINEL" ] && echo "env:gh"
	case "\$*" in *REAL*) echo "argv:leak" ;; esac
} >> "$work/mitmdump.seen"
exec sleep 30
STUB
# nc: "listening" once the mitmdump stub has really started, as a real port would be.
cat > "$rec_dir/nc" <<STUB
#!/bin/sh
test -s "$work/mitmdump.seen"
STUB
chmod +x "$rec_dir/limactl" "$rec_dir/mitmdump" "$rec_dir/nc"

if out="$(HOME="$fake_home" TMPDIR="$work/tmp" PATH="$rec_dir:$gh_dir:$PATH" "$SPIKE" --repo octo/private-thing 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "a live run against the stubs completes"
seen="$(cat "$work/mitmdump.seen" 2>/dev/null || true)"
assert_contains "$seen" "env:claude" "mitmdump gets the real Claude token in its environment"
assert_contains "$seen" "env:gh" "mitmdump gets the real GitHub token in its environment"
assert_not_contains "$seen" "argv:leak" "no real token is on mitmdump's command line"
limactl_log="$(cat "$work/limactl.log" 2>/dev/null || true)"
assert_contains "$limactl_log" "BEGIN CERTIFICATE" "the guest is sent the scratch CA's certificate"
assert_not_contains "$limactl_log" "PRIVATE KEY" "the guest is never sent the CA's key"
assert_contains "$limactl_log" "gho_pjsbplaceholder" "the guest is sent the placeholders"
assert_eq "" "$(leaks "$limactl_log")" "no real token is ever sent to the guest (limactl argv or stdin)"
assert_eq "" "$(cat "$work/file-leaks" 2>/dev/null || true)" "no real token is ever written to a file under TMPDIR"
assert_eq "" "$(leaks "$out")" "the live run's output never contains a real token"
assert_contains "$limactl_log" "ARGV: delete --force pjsb-spike-ca" "the live run deletes its VM"
assert_eq "" "$(ls "$work/tmp")" "the live run removes its scratch CA directory"

# --- write-up skeleton ---

assert_ok "pj-sandbox/docs/spike-ca.md exists" test -f "$SPIKE_DOC"
doc="$(cat "$SPIKE_DOC" 2>/dev/null || true)"
for c in $CHECKS; do
	assert_contains "$doc" "| \`$c\` " "spike-ca.md has a results row for $c"
done
assert_contains "$doc" "unbrokered" "spike-ca.md says a failing agent is marked unbrokered"
assert_eq "## Findings" "$(grep -E '^## ' "$SPIKE_DOC" 2>/dev/null | tail -1)" "spike-ca.md ends with a ## Findings section"

assert_report
