#!/bin/bash
# ssh_config_test.sh
#
# Plain-shell unit tests for sandbox/lib/ssh_config.sh (VS Code Remote-SSH
# config generation for `pj-sandbox-spawn`). No test framework
# dependency, same minimal assert style as task_test.sh/list_test.sh.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"

. "$SANDBOX_DIR/lib/ssh_config.sh"

failures=0

assert_eq() {
	expected="$1"
	actual="$2"
	message="$3"

	if [ "$expected" != "$actual" ]; then
		echo "FAIL: $message (expected '$expected', got '$actual')"
		failures=$((failures + 1))
	else
		echo "PASS: $message"
	fi
}

# --- sandbox_ssh_render_host_block ---

fixture_lima_config="$(mktemp)"
cat > "$fixture_lima_config" <<-'EOF'
# This SSH config file can be passed to 'ssh -F'.
# This file is created by Lima, but not used by Lima itself currently.
# Modifications to this file will be lost on restarting the Lima instance.
Host lima-fix-thing
  User psexton
  Hostname 127.0.0.1
  Port 60022
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
EOF

rendered="$(sandbox_ssh_render_host_block fix-thing "$fixture_lima_config")"

assert_eq "Host fix-thing" "$(echo "$rendered" | head -n1)" \
	"sandbox_ssh_render_host_block uses the task name as the Host alias, not lima-<name>"

case "$rendered" in
*"lima-fix-thing"*)
	echo "FAIL: sandbox_ssh_render_host_block drops the original 'Host lima-<name>' line"
	failures=$((failures + 1))
	;;
*)
	echo "PASS: sandbox_ssh_render_host_block drops the original 'Host lima-<name>' line"
	;;
esac

case "$rendered" in
*"Port 60022"*) echo "PASS: sandbox_ssh_render_host_block preserves Lima's option lines (Port)" ;;
*)
	echo "FAIL: sandbox_ssh_render_host_block preserves Lima's option lines (Port)"
	failures=$((failures + 1))
	;;
esac

case "$rendered" in
*"StrictHostKeyChecking no"*)
	echo "PASS: sandbox_ssh_render_host_block preserves Lima's option lines (StrictHostKeyChecking)"
	;;
*)
	echo "FAIL: sandbox_ssh_render_host_block preserves Lima's option lines (StrictHostKeyChecking)"
	failures=$((failures + 1))
	;;
esac

rm -f "$fixture_lima_config"

# --- sandbox_ssh_write_entry ---

fixture_include="$(mktemp -u)"

sandbox_ssh_write_entry "$fixture_include" "fix-thing" "$(printf 'Host fix-thing\n  Port 60022\n')"

assert_eq "$(printf 'Host fix-thing\n  Port 60022')" "$(cat "$fixture_include")" \
	"sandbox_ssh_write_entry creates the include file when it doesn't exist yet"

sandbox_ssh_write_entry "$fixture_include" "other-task" "$(printf 'Host other-task\n  Port 60023\n')"

after_second="$(cat "$fixture_include")"

case "$after_second" in
*"Host fix-thing"*"Port 60022"*)
	echo "PASS: sandbox_ssh_write_entry preserves the first sandbox's stanza when a second is added"
	;;
*)
	echo "FAIL: sandbox_ssh_write_entry preserves the first sandbox's stanza when a second is added"
	failures=$((failures + 1))
	;;
esac

case "$after_second" in
*"Host other-task"*"Port 60023"*)
	echo "PASS: sandbox_ssh_write_entry adds the second sandbox's stanza independently"
	;;
*)
	echo "FAIL: sandbox_ssh_write_entry adds the second sandbox's stanza independently"
	failures=$((failures + 1))
	;;
esac

# --- re-spawning the same task name updates its entry in place ---

sandbox_ssh_write_entry "$fixture_include" "fix-thing" "$(printf 'Host fix-thing\n  Port 60099\n')"

after_update="$(cat "$fixture_include")"

case "$after_update" in
*"Port 60022"*)
	echo "FAIL: sandbox_ssh_write_entry replaces a re-spawned task's stale stanza rather than duplicating it"
	failures=$((failures + 1))
	;;
*)
	echo "PASS: sandbox_ssh_write_entry replaces a re-spawned task's stale stanza rather than duplicating it"
	;;
esac

case "$after_update" in
*"Host fix-thing"*"Port 60099"*)
	echo "PASS: sandbox_ssh_write_entry's replacement stanza has the new port"
	;;
*)
	echo "FAIL: sandbox_ssh_write_entry's replacement stanza has the new port"
	failures=$((failures + 1))
	;;
esac

case "$after_update" in
*"Host other-task"*"Port 60023"*)
	echo "PASS: sandbox_ssh_write_entry leaves the other task's stanza alone during an update"
	;;
*)
	echo "FAIL: sandbox_ssh_write_entry leaves the other task's stanza alone during an update"
	failures=$((failures + 1))
	;;
esac

rm -f "$fixture_include"

# --- sandbox_ssh_ensure_include ---

fixture_ssh_dir="$(mktemp -d)"
fixture_ssh_config="$fixture_ssh_dir/config"
fixture_include_path="$fixture_ssh_dir/pj-sandbox-config"

sandbox_ssh_ensure_include "$fixture_include_path" "$fixture_ssh_config"

assert_eq "Include $fixture_include_path" "$(head -n1 "$fixture_ssh_config")" \
	"sandbox_ssh_ensure_include creates ~/.ssh/config with the Include line when missing"

before_second_call="$(cat "$fixture_ssh_config")"
sandbox_ssh_ensure_include "$fixture_include_path" "$fixture_ssh_config"
after_second_call="$(cat "$fixture_ssh_config")"

assert_eq "$before_second_call" "$after_second_call" \
	"sandbox_ssh_ensure_include is a no-op when the Include line is already present"

rm -rf "$fixture_ssh_dir"

# --- prepending onto a hand-edited ~/.ssh/config preserves its content ---

fixture_ssh_dir2="$(mktemp -d)"
fixture_ssh_config2="$fixture_ssh_dir2/config"
fixture_include_path2="$fixture_ssh_dir2/pj-sandbox-config"

cat > "$fixture_ssh_config2" <<-'EOF'
Host github.com
  User git
  IdentityFile ~/.ssh/id_ed25519
EOF

sandbox_ssh_ensure_include "$fixture_include_path2" "$fixture_ssh_config2"

result2="$(cat "$fixture_ssh_config2")"

assert_eq "Include $fixture_include_path2" "$(echo "$result2" | head -n1)" \
	"sandbox_ssh_ensure_include puts the Include line first, ahead of hand-written Host blocks"

case "$result2" in
*"Host github.com"*"IdentityFile ~/.ssh/id_ed25519"*)
	echo "PASS: sandbox_ssh_ensure_include preserves the user's hand-written ssh config content"
	;;
*)
	echo "FAIL: sandbox_ssh_ensure_include preserves the user's hand-written ssh config content"
	failures=$((failures + 1))
	;;
esac

rm -rf "$fixture_ssh_dir2"

# --- sandbox_ssh_remove_entry ---

fixture_include3="$(mktemp -u)"

sandbox_ssh_write_entry "$fixture_include3" "fix-thing" "$(printf 'Host fix-thing\n  Port 60022\n')"
sandbox_ssh_write_entry "$fixture_include3" "other-task" "$(printf 'Host other-task\n  Port 60023\n')"

sandbox_ssh_remove_entry "$fixture_include3" "fix-thing"

after_remove="$(cat "$fixture_include3")"

case "$after_remove" in
*"Host fix-thing"*)
	echo "FAIL: sandbox_ssh_remove_entry removes the target task's stanza"
	failures=$((failures + 1))
	;;
*)
	echo "PASS: sandbox_ssh_remove_entry removes the target task's stanza"
	;;
esac

case "$after_remove" in
*"Host other-task"*"Port 60023"*)
	echo "PASS: sandbox_ssh_remove_entry leaves other tasks' stanzas untouched"
	;;
*)
	echo "FAIL: sandbox_ssh_remove_entry leaves other tasks' stanzas untouched"
	failures=$((failures + 1))
	;;
esac

rm -f "$fixture_include3"

# --- sandbox_ssh_remove_entry is a no-op when the include file doesn't exist ---

fixture_include4="$(mktemp -u)"

sandbox_ssh_remove_entry "$fixture_include4" "fix-thing"

if [ -e "$fixture_include4" ]; then
	echo "FAIL: sandbox_ssh_remove_entry doesn't create the include file when it didn't exist"
	failures=$((failures + 1))
else
	echo "PASS: sandbox_ssh_remove_entry doesn't create the include file when it didn't exist"
fi

# --- sandbox_ssh_remove_entry is a no-op when the task has no stanza ---

fixture_include5="$(mktemp -u)"

sandbox_ssh_write_entry "$fixture_include5" "other-task" "$(printf 'Host other-task\n  Port 60023\n')"
before_noop="$(cat "$fixture_include5")"

sandbox_ssh_remove_entry "$fixture_include5" "no-such-task"

assert_eq "$before_noop" "$(cat "$fixture_include5")" \
	"sandbox_ssh_remove_entry is a no-op when the task has no stanza in the include file"

rm -f "$fixture_include5"

echo "$failures failure(s)"
[ "$failures" -eq 0 ]
