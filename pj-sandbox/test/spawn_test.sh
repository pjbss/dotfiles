#!/bin/bash
# spawn_test.sh
#
# Tests for `pj-sandbox spawn`, run through the real dispatcher from inside a
# temp git repo, with a stub `limactl` first on PATH and HOME pointed at a temp
# dir, so the ssh files and the state dir are all the defaults under that fake
# home. The git bundle and guest clone are covered by git_bundle_test.sh; here
# the guest steps are only recorded.

set -euo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PJ_SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"
. "$TEST_DIR/../../test/assert.sh"
. "$TEST_DIR/stub_proxy.sh"

CLI="$PJ_SANDBOX_DIR/bin/pj-sandbox"

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

# Every namespace falls back to its default under the fake HOME.
unset PJ_SANDBOX_STATE_DIR PJ_SANDBOX_SSH_INCLUDE_FILE PJ_SANDBOX_SSH_CONFIG_FILE \
	PJ_SANDBOX_PORT_MIN PJ_SANDBOX_PORT_MAX PJ_SANDBOX_INSTANCE_PREFIX PJ_SANDBOX_TEMPLATES_DIR \
	XDG_STATE_HOME XDG_CONFIG_HOME GIT_CONFIG_GLOBAL GIT_DIR GIT_WORK_TREE
export HOME="$fixture/home"
export STUB_DIR="$fixture/stub"
STATE_DIR="$HOME/.local/state/pj-sandbox"
INCLUDE_FILE="$HOME/.ssh/pj-sandbox-next-config"
OLD_INCLUDE_FILE="$HOME/.ssh/pj-sandbox-config"
mkdir -p "$HOME/.ssh" "$fixture/bin" "$STUB_DIR"
git init -q "$fixture/repo"
git -C "$fixture/repo" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m first
cd "$fixture/repo"

# The old sandbox's include file and the user's own ssh config, both of which
# spawn must leave alone (the latter apart from one Include line).
printf 'Host old-task\n  HostName 127.0.0.1\n  Port 60022\n' > "$OLD_INCLUDE_FILE"
cp "$OLD_INCLUDE_FILE" "$fixture/old-include.orig"
printf 'Host personal\n  HostName example.com\n' > "$HOME/.ssh/config"

# `limactl start` keeps a copy of the config it was given; `limactl ls`
# answers the ssh.config path the way Lima does, pointing at a file shaped
# like Lima's own.
cat > "$fixture/bin/limactl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_DIR/calls"
case "$1" in
	start)
		for last in "$@"; do :; done
		cp "$last" "$STUB_DIR/rendered.yaml"
		[ -z "${LIMACTL_START_FAIL:-}" ] || exit 1
		;;
	ls)
		for name in "$@"; do :; done
		cat > "$STUB_DIR/$name.ssh.config" <<EOF
# This SSH config file can be passed to 'ssh -F'.
# This file is created by Lima, but not used by Lima itself currently.
Host lima-$name
  IdentityFile "/fake/.lima/_config/user"
  User tester
  Hostname 127.0.0.1
  Port 61022
EOF
		echo "$STUB_DIR/$name.ssh.config"
		;;
	copy) ;;
	shell) cat > /dev/null ;;
	*)
		echo "unexpected limactl call: $*" >&2
		exit 3
		;;
esac
STUB
chmod +x "$fixture/bin/limactl"
# The guest bootstrap (bootstrap_test.sh covers it) goes over ssh, which only
# needs to drain the archive and script here. The fixture repo stands in for
# the dotfiles, so the real checkout is never archived.
cat > "$fixture/bin/ssh" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_DIR/ssh-calls"
cat > /dev/null
STUB
chmod +x "$fixture/bin/ssh"
export PJ_SANDBOX_DOTFILES_HOME="$fixture/repo"
# spawn starts the task's proxy; a stub stands in for mitmdump.
pj_test_stub_proxy "$fixture/bin"
export PJ_SANDBOX_PROXY_SETTLE=0
export PATH="$fixture/bin:$PATH"

# --- a first spawn ---

if out="$("$CLI" spawn 'My.Task' --base none --ports 8000,5432 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "spawn exits 0 (output: $out)"

start_call="$(grep '^start ' "$STUB_DIR/calls" || true)"
assert_contains "$start_call" "--name pjsb-my-task" "spawn starts the VM as pjsb-<slug>"
assert_eq "1" "$(grep -c '^start ' "$STUB_DIR/calls")" "spawn calls limactl start once"

rendered="$(cat "$STUB_DIR/rendered.yaml")"
assert_eq "1" "$(printf '%s\n' "$rendered" | grep -c '^mounts: \[\]$')" "limactl start gets the rendered config, with mounts: []"
assert_eq "" "$(printf '%s\n' "$rendered" | grep 'location:' || true)" "the config limactl start gets mounts nothing"
ssh_port="$(printf '%s\n' "$rendered" | sed -n 's/^  localPort: //p')"
assert_ok "ssh.localPort ($ssh_port) is in the 61022-61099 range" test "$ssh_port" -ge 61022 -a "$ssh_port" -le 61099
assert_eq "2" "$(printf '%s\n' "$rendered" | grep -c '^  hostIP: 127.0.0.1$')" "each --ports forward is rendered on 127.0.0.1"

# --- ssh entry ---

include="$(cat "$INCLUDE_FILE")"
assert_contains "$include" "Host pjsb-my-task" "the Host entry goes into the new include file"
assert_contains "$include" "  Port 61022" "the Host entry carries Lima's own ssh options"
assert_not_contains "$include" "Host lima-" "the Host entry is renamed from Lima's alias"
assert_eq "$(cat "$fixture/old-include.orig")" "$(cat "$OLD_INCLUDE_FILE")" "~/.ssh/pj-sandbox-config is left untouched"
assert_eq "Include $INCLUDE_FILE" "$(head -1 "$HOME/.ssh/config")" "~/.ssh/config includes the new file, first"
assert_contains "$(cat "$HOME/.ssh/config")" "Host personal" "~/.ssh/config keeps the user's own entries"
assert_not_contains "$(cat "$HOME/.ssh/config")" "pj-sandbox-config" "~/.ssh/config gets no Include for the old file"

# --- state record ---

meta="$STATE_DIR/My.Task/meta"
assert_ok "spawn writes the state record" test -f "$meta"
get() { sed -n "s/^$1=//p" "$meta"; }
assert_eq "My.Task" "$(get task)" "the record names the task"
assert_eq "pjsb-my-task" "$(get instance)" "the record names the instance"
assert_eq "none" "$(get base)" "the record holds --base"
assert_eq "$ssh_port" "$(get ssh_port)" "the record holds the rendered ssh port"
ports="$(get ports)"
assert_eq "8000:$(printf '%s\n' "$rendered" | grep -A1 'guestPort: 8000' | sed -n 's/^  hostPort: //p'),5432:$(printf '%s\n' "$rendered" | grep -A1 'guestPort: 5432' | sed -n 's/^  hostPort: //p')" \
	"$ports" "the record holds each guest:host forward as rendered"
assert_ok "the record has a created timestamp" sh -c 'grep -Eq "^created=[0-9]{4}-[0-9]{2}-[0-9]{2}T" "$1"' sh "$meta"

# --- a second task gets its own ports ---

"$CLI" spawn other --base none >/dev/null 2>&1
other_port="$(sed -n 's/^ssh_port=//p' "$STATE_DIR/other/meta")"
assert_eq "other" "$(sed -n 's/^task=//p' "$STATE_DIR/other/meta")" "a spawn with other tasks recorded still records its own task name"
for held in $ssh_port $(printf '%s\n' "$ports" | tr ',' '\n' | cut -d: -f2); do
	assert_ok "the second task's ssh port ($other_port) isn't one the first holds ($held)" test "$other_port" != "$held"
done
assert_contains "$(cat "$INCLUDE_FILE")" "Host pjsb-my-task" "a second spawn keeps the first task's Host entry"
assert_contains "$(cat "$INCLUDE_FILE")" "Host pjsb-other" "a second spawn adds its own Host entry"
assert_eq "1" "$(grep -c "^Include " "$HOME/.ssh/config")" "the Include line is added only once"

# --- refusals, none of which may reach limactl ---

: > "$STUB_DIR/calls"
before="$(cat "$meta")"
if out="$("$CLI" spawn 'My.Task' --base none 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "spawning a task that already has a state record exits 1"
assert_contains "$out" "already exists" "an existing task is named as such"
assert_eq "$before" "$(cat "$meta")" "the existing record is left as it was"

for args in "" "nobase" "t --base" "t --base default" "t --base none --ports" "t --base none --ports 80x" "t --base none --ports 0" "t --base none --ports 70000" "t --base none --bogus" "a b --base none"; do
	# shellcheck disable=SC2086
	if out="$("$CLI" spawn $args 2>&1)"; then rc=0; else rc=$?; fi
	assert_exit_code 1 "$rc" "spawn $args exits 1"
done
out="$("$CLI" spawn t --base default 2>&1 || true)"
assert_contains "$out" "unknown base 'default'" "an unknown --base is named"
assert_contains "$out" "$(printf 'Available --base names:\n  none\n  python3.12\n  python3.14')" "an unknown --base lists the valid names"

# A local template that asks for host mounts is refused outright.
LOCAL_TEMPLATES="$PJ_SANDBOX_DOTFILES_HOME/local/pj-sandbox/templates"
mkdir -p "$LOCAL_TEMPLATES/mounty"
printf -- '- location: "~/secrets"\n  writable: true\n' > "$LOCAL_TEMPLATES/mounty/mounts.yaml"
if out="$("$CLI" spawn t --base mounty 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "a template with mounts.yaml makes spawn fail"
assert_contains "$out" "no host mounts" "the refusal says pj-sandbox allows no host mounts"
assert_contains "$out" "mounts.yaml" "the refusal names the offending file"
rm -rf "$LOCAL_TEMPLATES/mounty"

assert_eq "" "$(cat "$STUB_DIR/calls")" "no refused spawn calls limactl"
assert_ok "no refused spawn leaves a state record" test ! -e "$STATE_DIR/t"

# --- --base list and --help ---

mkdir -p "$LOCAL_TEMPLATES/extra"
if out="$("$CLI" spawn --base list 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "spawn --base list exits 0"
assert_eq "$(printf '%s\n' 'extra (local)' none python3.12 python3.14)" "$out" "spawn --base list prints both dirs' names one per line"
if out="$("$CLI" spawn --help 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "spawn --help exits 0"
assert_contains "$out" "Usage: pj-sandbox spawn" "spawn --help shows usage"
assert_contains "$out" "$(printf 'Available --base names:\n  extra (local)\n  none\n  python3.12')" "spawn --help lists the valid --base names"
rmdir "$LOCAL_TEMPLATES/extra"
mkdir -p "$fixture/tpl/elsewhere"
assert_eq "$(printf '%s\n' 'elsewhere (local)' none python3.12 python3.14)" "$(PJ_SANDBOX_TEMPLATES_DIR="$fixture/tpl" "$CLI" spawn --base list 2>&1)" \
	"PJ_SANDBOX_TEMPLATES_DIR moves the local templates dir"
assert_eq "" "$(cat "$STUB_DIR/calls")" "--base list and --help never call limactl"

# --- a provisioned base ---

"$CLI" spawn py --base python3.12 >/dev/null 2>&1
rendered="$(cat "$STUB_DIR/rendered.yaml")"
assert_contains "$rendered" "$(cat "$PJ_SANDBOX_DIR/templates/python3.12")" "--base python3.12 renders that template's provision block"
assert_eq "1" "$(printf '%s\n' "$rendered" | grep -c '^provision:$')" "--base python3.12's block goes under the one provision: key"
assert_eq "1" "$(printf '%s\n' "$rendered" | grep -c '^mounts: \[\]$')" "--base python3.12 still renders mounts: []"
assert_eq "python3.12" "$(sed -n 's/^base=//p' "$STATE_DIR/py/meta")" "the record holds the provisioned --base"

# A local directory template overrides the built-in, and its files are
# copied in rather than mounted.
mkdir -p "$LOCAL_TEMPLATES/python3.14"
printf -- '- mode: system\n  script: echo local-python\n' > "$LOCAL_TEMPLATES/python3.14/provision.yaml"
printf 'copied-secret\n' > "$HOME/.toolrc"
printf '~/.toolrc:/home/tester/.toolrc\n' > "$LOCAL_TEMPLATES/python3.14/files"
"$CLI" spawn py14 --base python3.14 >/dev/null 2>&1
rendered="$(cat "$STUB_DIR/rendered.yaml")"
assert_contains "$rendered" "echo local-python" "a local template overrides the built-in of the same name"
assert_not_contains "$rendered" "deadsnakes" "the overridden built-in isn't rendered"
assert_contains "$rendered" "$(printf -- '- mode: data\n  path: "/home/tester/.toolrc"')" "template files are copied in as mode: data items"
assert_contains "$rendered" "    copied-secret" "the copied-in file carries the host file's content"
assert_eq "1" "$(printf '%s\n' "$rendered" | grep -c '^mounts: \[\]$')" "a template with files still renders mounts: []"
rm -rf "$LOCAL_TEMPLATES/python3.14"

# --- limactl start failing ---

if out="$(LIMACTL_START_FAIL=1 "$CLI" spawn broken --base none 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "spawn fails when limactl start does"
assert_ok "a failed start leaves no state record" test ! -e "$STATE_DIR/broken/meta"
assert_ok "a failed start leaves no bundle or state dir behind" test ! -e "$STATE_DIR/broken"
assert_not_contains "$(cat "$INCLUDE_FILE")" "pjsb-broken" "a failed start writes no Host entry"

assert_report
