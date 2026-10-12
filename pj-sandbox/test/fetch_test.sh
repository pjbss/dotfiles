#!/bin/bash
# fetch_test.sh
#
# Tests for `pj-sandbox fetch`, which brings a guest's branches back into the
# host repo under refs/sandbox/<task>/*. A temp "guest" repo stands in for the
# VM's /workspace, reached over a stub ssh (GIT_SSH_COMMAND) that runs the
# real git-upload-pack against it. The guest is hostile: it plants hooks, a
# core.hooksPath and a core.fsmonitor that would each touch a marker file. A
# `git` wrapper first on PATH records every host git invocation.

set -euo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PJ_SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"
. "$TEST_DIR/../../test/assert.sh"

CLI="$PJ_SANDBOX_DIR/bin/pj-sandbox"

fixture="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "$fixture"' EXIT

unset PJ_SANDBOX_STATE_DIR PJ_SANDBOX_SSH_INCLUDE_FILE PJ_SANDBOX_SSH_CONFIG_FILE \
	PJ_SANDBOX_PORT_MIN PJ_SANDBOX_PORT_MAX PJ_SANDBOX_INSTANCE_PREFIX \
	XDG_STATE_HOME XDG_CONFIG_HOME GIT_CONFIG_GLOBAL GIT_DIR GIT_WORK_TREE
export HOME="$fixture/home"
export STUB_DIR="$fixture/stub"
export GUEST_ROOT="$fixture/guest"
export MARKER="$fixture/pwned"
STATE_DIR="$HOME/.local/state/pj-sandbox"
mkdir -p "$HOME" "$fixture/bin" "$STUB_DIR" "$GUEST_ROOT"
git config --global user.name tester
git config --global user.email tester@example.com
git config --global init.defaultBranch main

REAL_GIT="$(command -v git)"
export REAL_GIT
cat > "$fixture/bin/git" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_DIR/git-calls"
exec "$REAL_GIT" "$@"
STUB
chmod +x "$fixture/bin/git"

# git runs this as `<ssh> [-o SendEnv=GIT_PROTOCOL] HOST "git-upload-pack '/path'"`.
cat > "$fixture/ssh-shim" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_DIR/ssh-calls"
for remote_cmd in "$@"; do :; done
eval "set -- $remote_cmd"
[ "$1" = git-upload-pack ] || { echo "unexpected remote command: $remote_cmd" >&2; exit 3; }
exec "$REAL_GIT" upload-pack "$GUEST_ROOT$2"
STUB
chmod +x "$fixture/ssh-shim"
export GIT_SSH_COMMAND="$fixture/ssh-shim"
export PJ_SANDBOX_DOTFILES_HOME="$fixture/repo"
export PATH="$fixture/bin:$PATH"

# --- the host repo, its task branch, and a record for the task ---

repo="$fixture/repo"
git init -q "$repo"
git -C "$repo" commit -q --allow-empty -m first
git -C "$repo" branch feature-a
host_branch_before="$(git -C "$repo" rev-parse refs/heads/feature-a)"
mkdir -p "$STATE_DIR/feature-a"
printf '%s\n' task=feature-a instance=pjsb-feature-a "repo=$repo" branch=feature-a base=none \
	ssh_port=61022 ports= created=2026-10-05T10:00:00Z > "$STATE_DIR/feature-a/meta"

# --- the hostile guest: a new commit, plus hooks and config that touch MARKER ---

ws="$GUEST_ROOT/workspace"
git clone -q --branch feature-a "$repo" "$ws"
git -C "$ws" remote remove origin
git -C "$ws" commit -q --allow-empty -m "guest work"
git -C "$ws" branch guest-extra
guest_commit="$(git -C "$ws" rev-parse HEAD)"
guest_oneline="$(git -C "$ws" log -1 --oneline)"

evil="$GUEST_ROOT/evil"
mkdir -p "$evil" "$ws/.git/hooks"
cat > "$evil/payload" <<EOF
#!/bin/sh
touch "$MARKER"
EOF
chmod +x "$evil/payload"
for hook in reference-transaction post-checkout post-merge post-index-change pre-auto-gc; do
	cp "$evil/payload" "$evil/$hook"
	cp "$evil/payload" "$ws/.git/hooks/$hook"
done
git -C "$ws" config core.hooksPath "$evil"
git -C "$ws" config core.fsmonitor "$evil/payload"

: > "$STUB_DIR/git-calls"

# --- fetch ---

if out="$(cd "$fixture" && "$CLI" fetch feature-a 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "fetch exits 0 (output: $out)"

assert_eq "$guest_commit" "$(git -C "$repo" rev-parse refs/sandbox/feature-a/feature-a)" \
	"refs/sandbox/<task>/<branch> is at the guest's commit"
assert_eq "$guest_commit" "$(git -C "$repo" rev-parse refs/sandbox/feature-a/guest-extra)" \
	"every guest branch lands under refs/sandbox/<task>/"
assert_eq "$host_branch_before" "$(git -C "$repo" rev-parse refs/heads/feature-a)" \
	"refs/heads/<branch> on the host is unchanged"
assert_not_ok "no guest branch becomes a host branch" \
	git -C "$repo" rev-parse --verify --quiet refs/heads/guest-extra

assert_contains "$(cat "$STUB_DIR/ssh-calls")" "pjsb-feature-a git-upload-pack '/workspace'" \
	"fetch reaches /workspace through the instance's ssh Host entry"

fetch_call="$(grep -E '(^| )fetch ' "$STUB_DIR/git-calls" || true)"
assert_contains "$fetch_call" "-c core.hooksPath=/dev/null" "the fetch overrides core.hooksPath"
assert_contains "$fetch_call" "-c core.fsmonitor=false" "the fetch disables core.fsmonitor"
assert_contains "$fetch_call" "-c protocol.ext.allow=never" "the fetch forbids the ext:: protocol"
assert_contains "$fetch_call" "fetch pjsb-feature-a:/workspace +refs/heads/*:refs/sandbox/feature-a/*" \
	"the fetch uses the instance remote and the refs/sandbox/<task>/* refspec"
assert_not_contains "$(cat "$STUB_DIR/git-calls")" "$ws" "no host git command runs in or names the guest's directory"

assert_contains "$out" "refs/sandbox/feature-a/feature-a" "fetch prints the fetched refs"
assert_contains "$out" "refs/sandbox/feature-a/guest-extra" "fetch prints every fetched ref"
assert_contains "$out" "$guest_oneline" \
	"fetch prints git log --oneline for <branch>..refs/sandbox/<task>/<branch>"
assert_not_contains "$out" " first" "the log leaves out commits the host branch already has"

fetched="$(sed -n 's/^fetched=//p' "$STATE_DIR/feature-a/meta")"
assert_ok "the record holds the last fetch time (got '$fetched')" \
	sh -c 'printf "%s\n" "$1" | grep -Eq "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"' _ "$fetched"
assert_eq "pjsb-feature-a" "$(sed -n 's/^instance=//p' "$STATE_DIR/feature-a/meta")" \
	"recording the fetch keeps the record's other fields"

git -C "$repo" status > /dev/null
assert_not_ok "no guest-planted hook or fsmonitor ran during or after the fetch" test -e "$MARKER"
# The plant is live: the same status run in the guest's own repo trips it.
git -C "$ws" status > /dev/null 2>&1 || true
assert_ok "the guest's planted fsmonitor does run in the guest repo itself" test -e "$MARKER"

# --- refusals ---

if out="$("$CLI" fetch 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "fetch with no task exits 1"
assert_contains "$out" "Usage: pj-sandbox fetch" "fetch with no task prints usage"

if out="$("$CLI" fetch no-such-task 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "fetch of an unknown task exits 1"
assert_contains "$out" "no sandbox task 'no-such-task'" "fetch of an unknown task says so"

assert_report
