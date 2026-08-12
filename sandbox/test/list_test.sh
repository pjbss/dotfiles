#!/bin/bash
# list_test.sh
#
# Plain-shell unit tests for sandbox/lib/list.sh (sandbox discovery/status
# correlation for `pj-sbx-list`). No test framework dependency,
# same minimal assert style as task_test.sh.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"

. "$SANDBOX_DIR/lib/list.sh"

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

fixture_root="$(mktemp -d)"

# --- empty state ---

empty_output="$(sandbox_list_entries "$fixture_root")"
assert_eq "" "$empty_output" "sandbox_list_entries prints nothing when no sandboxes are known"

# --- one sandbox, running ---

mkdir -p "$fixture_root/myrepo/lima-configs" "$fixture_root/myrepo/worktrees/fix-thing"
touch "$fixture_root/myrepo/lima-configs/fix-thing.yaml"

limactl() {
	echo '{"name":"fix-thing","status":"Running","sshLocalPort":60022}'
}

one_output="$(sandbox_list_entries "$fixture_root")"
assert_eq "$(printf 'fix-thing\t%s/myrepo/worktrees/fix-thing\tRunning\t' "$fixture_root")" "$one_output" \
	"sandbox_list_entries reports task name, worktree path, live status, and an empty port mapping for a sandbox spawned without --ports"

unset -f limactl

# --- one sandbox, not reported by limactl at all ---

limactl() {
	echo ""
}

stopped_output="$(sandbox_list_entries "$fixture_root")"
assert_eq "$(printf 'fix-thing\t%s/myrepo/worktrees/fix-thing\tstopped\t' "$fixture_root")" "$stopped_output" \
	"sandbox_list_entries falls back to 'stopped' when limactl has no record of the instance"

unset -f limactl

# --- two sandboxes, one running, one already torn down/stopped ---

mkdir -p "$fixture_root/myrepo/worktrees/other-task"
touch "$fixture_root/myrepo/lima-configs/other-task.yaml"

limactl() {
	echo '{"name":"fix-thing","status":"Running","sshLocalPort":60022}'
}

two_output="$(sandbox_list_entries "$fixture_root" | sort)"
expected_two="$(printf 'fix-thing\t%s/myrepo/worktrees/fix-thing\tRunning\t\nother-task\t%s/myrepo/worktrees/other-task\tstopped\t' \
	"$fixture_root" "$fixture_root" | sort)"
assert_eq "$expected_two" "$two_output" \
	"sandbox_list_entries lists multiple sandboxes independently, each with its own status"

unset -f limactl

# --- a torn-down sandbox whose config artifact is removed disappears entirely ---

rm -f "$fixture_root/myrepo/lima-configs/other-task.yaml"

limactl() {
	echo '{"name":"fix-thing","status":"Running","sshLocalPort":60022}'
}

after_removal_output="$(sandbox_list_entries "$fixture_root")"
assert_eq "$(printf 'fix-thing\t%s/myrepo/worktrees/fix-thing\tRunning\t' "$fixture_root")" "$after_removal_output" \
	"sandbox_list_entries no longer lists a sandbox once its config artifact is removed"

unset -f limactl

# --- sandbox_port_mapping (issue 006) ---

fixture_config_no_ports="$(mktemp)"
cat > "$fixture_config_no_ports" <<-'EOF'
	ssh:
	  localPort: 60022

	mounts: []
	EOF

assert_eq "" "$(sandbox_port_mapping "$fixture_config_no_ports")" \
	"sandbox_port_mapping prints nothing for a config with no portForwards: block"

fixture_config_with_ports="$(mktemp)"
cat > "$fixture_config_with_ports" <<-'EOF'
	ssh:
	  localPort: 60022

	portForwards:
	- guestPort: 8000
	  hostPort: 60100
	- guestPort: 5432
	  hostPort: 60101

	mounts: []
	EOF

assert_eq "60100:8000,60101:5432" "$(sandbox_port_mapping "$fixture_config_with_ports")" \
	"sandbox_port_mapping prints a comma-separated hostPort:guestPort mapping in portForwards: order"

rm -f "$fixture_config_no_ports" "$fixture_config_with_ports"

# --- sandbox_list_entries: port-mapping column (issue 006) ---

mkdir -p "$fixture_root/portsrepo/lima-configs" "$fixture_root/portsrepo/worktrees/with-ports"
cat > "$fixture_root/portsrepo/lima-configs/with-ports.yaml" <<-'EOF'
	ssh:
	  localPort: 60023

	portForwards:
	- guestPort: 8000
	  hostPort: 60100

	mounts: []
	EOF

limactl() {
	echo '{"name":"with-ports","status":"Running","sshLocalPort":60023}'
}

with_ports_output="$(sandbox_list_entries "$fixture_root" 2>/dev/null | awk -F'\t' '$1 == "with-ports" { print $4 }')"
assert_eq "60100:8000" "$with_ports_output" \
	"pj-sbx-list shows the forwarded host<->guest port mapping for a sandbox spawned with --ports"

unset -f limactl

# --- sandbox_list_entries: two sandboxes of the same project, different
# host-port allocations for the same guest port (issue 006 criterion 3) ---

mkdir -p "$fixture_root/portsrepo/worktrees/with-ports-2"
cat > "$fixture_root/portsrepo/lima-configs/with-ports-2.yaml" <<-'EOF'
	ssh:
	  localPort: 60024

	portForwards:
	- guestPort: 8000
	  hostPort: 60105

	mounts: []
	EOF

limactl() {
	echo ""
}

same_project_output="$(sandbox_list_entries "$fixture_root" | grep '^with-ports' | sort)"
expected_same_project="$(printf 'with-ports\t%s/portsrepo/worktrees/with-ports\tstopped\t60100:8000\nwith-ports-2\t%s/portsrepo/worktrees/with-ports-2\tstopped\t60105:8000' \
	"$fixture_root" "$fixture_root" | sort)"
assert_eq "$expected_same_project" "$same_project_output" \
	"sandbox_list_entries distinguishes port mappings across two sandboxes of the same project sharing a guest port"

unset -f limactl

rm -rf "$fixture_root"
echo "$failures failure(s)"
[ "$failures" -eq 0 ]
