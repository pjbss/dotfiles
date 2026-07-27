#!/bin/bash
# task_test.sh
#
# Plain-shell unit tests for sandbox/lib/task.sh (task-name slugifying and
# SSH port allocation). No test framework dependency (bats isn't installed
# or declared anywhere in this repo) -- just a minimal assert helper.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"

. "$SANDBOX_DIR/lib/task.sh"

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

# Asserts $1 matches the Lima instance-name identifier regex.
assert_lima_valid_name() {
	candidate="$1"
	message="$2"

	if echo "$candidate" | grep -Eq '^[A-Za-z0-9]+([._-][A-Za-z0-9]+)*$'; then
		echo "PASS: $message (got '$candidate')"
	else
		echo "FAIL: $message (got '$candidate')"
		failures=$((failures + 1))
	fi
}

# --- sandbox_instance_name ---

name1="$(sandbox_instance_name 'my task')"
name2="$(sandbox_instance_name 'my task')"
assert_eq "$name1" "$name2" "sandbox_instance_name is deterministic for the same task name"

slugified="$(sandbox_instance_name 'My Task!! Foo_Bar  #42')"
assert_lima_valid_name "$slugified" "sandbox_instance_name produces a Lima-valid name for spaces/uppercase/special chars"

degenerate="$(sandbox_instance_name '!!!')"
assert_lima_valid_name "$degenerate" "sandbox_instance_name produces a Lima-valid name even when the task name is all special characters"

# --- sandbox_allocate_port ---

# Stub `limactl` as a shell function: functions are looked up before PATH,
# so this shadows the real binary for any code in this process that just
# calls `limactl ...` (which is exactly what sandbox_allocate_port does).
limactl() {
	echo ""
}

no_sandboxes_port="$(sandbox_allocate_port)"
if [ "$no_sandboxes_port" -ge "$SANDBOX_SSH_PORT_MIN" ] && [ "$no_sandboxes_port" -le "$SANDBOX_SSH_PORT_MAX" ]; then
	echo "PASS: sandbox_allocate_port allocates a port from the defined range when no sandboxes are running (got $no_sandboxes_port)"
else
	echo "FAIL: sandbox_allocate_port allocates a port from the defined range when no sandboxes are running (got $no_sandboxes_port)"
	failures=$((failures + 1))
fi

limactl() {
	cat <<-EOF
	{"name":"task-a","status":"Running","sshLocalPort":$SANDBOX_SSH_PORT_MIN}
	{"name":"task-b","status":"Running","sshLocalPort":$((SANDBOX_SSH_PORT_MIN + 1))}
	EOF
}

with_sandboxes_port="$(sandbox_allocate_port)"
assert_eq "$((SANDBOX_SSH_PORT_MIN + 2))" "$with_sandboxes_port" "sandbox_allocate_port skips ports already claimed by running sandboxes"

unset -f limactl

# --- sandbox_render_lima_config ---

fixture_template="$(mktemp)"
cat > "$fixture_template" <<-'EOF'
ssh:
  localPort: __SANDBOX_SSH_PORT__

mounts:
- location: "__SANDBOX_WORKTREE_PATH__"
  mountPoint: "/workspace"
  writable: true
EOF

rendered="$(sandbox_render_lima_config "$fixture_template" 60099 /tmp/some-worktree '')"

case "$rendered" in
*60099*) echo "PASS: sandbox_render_lima_config substitutes the SSH port" ;;
*) echo "FAIL: sandbox_render_lima_config substitutes the SSH port"; failures=$((failures + 1)) ;;
esac

case "$rendered" in
*/tmp/some-worktree*) echo "PASS: sandbox_render_lima_config substitutes the worktree path" ;;
*) echo "FAIL: sandbox_render_lima_config substitutes the worktree path"; failures=$((failures + 1)) ;;
esac

case "$rendered" in
*AWS_PROFILE*) echo "FAIL: sandbox_render_lima_config omits the env stanza when AWS_PROFILE is empty"; failures=$((failures + 1)) ;;
*) echo "PASS: sandbox_render_lima_config omits the env stanza when AWS_PROFILE is empty" ;;
esac

rendered_with_profile="$(sandbox_render_lima_config "$fixture_template" 60099 /tmp/some-worktree work-sso)"

case "$rendered_with_profile" in
*'AWS_PROFILE: "work-sso"'*) echo "PASS: sandbox_render_lima_config passes through a non-empty AWS_PROFILE" ;;
*) echo "FAIL: sandbox_render_lima_config passes through a non-empty AWS_PROFILE"; failures=$((failures + 1)) ;;
esac

rm -f "$fixture_template"

# --- credential mounts in the real base template (issue 004) ---

template_file="$SANDBOX_DIR/lima-template.yaml"

for cred_path in '~/.claude' '~/.config/gh' '~/.aws'; do
	if grep -qF "location: \"$cred_path\"" "$template_file"; then
		echo "PASS: lima-template.yaml mounts $cred_path"
	else
		echo "FAIL: lima-template.yaml mounts $cred_path"
		failures=$((failures + 1))
	fi
done

# Every mount block in the template other than the read-write worktree
# mount must be explicitly read-only.
writable_true_count="$(grep -c 'writable: true' "$template_file")"
assert_eq "1" "$writable_true_count" "lima-template.yaml has exactly one writable:true mount (the worktree)"

if grep -qE '\.ssh|git-credential|GIT_' "$template_file"; then
	echo "FAIL: lima-template.yaml contains no git/SSH credential references"
	failures=$((failures + 1))
else
	echo "PASS: lima-template.yaml contains no git/SSH credential references"
fi

echo "$failures failure(s)"
[ "$failures" -eq 0 ]
