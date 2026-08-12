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

# --- sandbox_allocate_ports (issue 005) ---

limactl() {
	echo ""
}

no_sandboxes_ports="$(sandbox_allocate_ports "8000,5432")"
assert_eq "8000:$SANDBOX_FORWARD_PORT_MIN
5432:$((SANDBOX_FORWARD_PORT_MIN + 1))" "$no_sandboxes_ports" \
	"sandbox_allocate_ports allocates one distinct host port per guest port, from the forward range, when no sandboxes are running"

if echo "$no_sandboxes_ports" | grep -qx "$SANDBOX_SSH_PORT_MIN:.*\|.*:$SANDBOX_SSH_PORT_MIN"; then
	echo "FAIL: sandbox_allocate_ports never allocates from the SSH port range"
	failures=$((failures + 1))
else
	echo "PASS: sandbox_allocate_ports never allocates from the SSH port range"
fi

# Another running sandbox's SSH port *and* an existing port forward
# (config.portForwards[].hostPort -- confirmed against Lima's real
# limatype.Instance/PortForward JSON field names) must both be skipped.
limactl() {
	cat <<-EOF
	{"name":"task-a","status":"Running","sshLocalPort":$SANDBOX_SSH_PORT_MIN,"config":{"portForwards":[{"guestPort":8000,"hostPort":$SANDBOX_FORWARD_PORT_MIN}]}}
	EOF
}

with_forward_claimed="$(sandbox_allocate_ports "8000")"
assert_eq "8000:$((SANDBOX_FORWARD_PORT_MIN + 1))" "$with_forward_claimed" \
	"sandbox_allocate_ports skips a host port already claimed by another running sandbox's port forward"

# Two guest ports in the *same* spawn must never collide with each other
# either, even before either is visible via `limactl list --json`.
limactl() {
	echo ""
}

same_call_ports="$(sandbox_allocate_ports "8000,8000")"
host_port_1="$(echo "$same_call_ports" | sed -n '1p' | cut -d: -f2)"
host_port_2="$(echo "$same_call_ports" | sed -n '2p' | cut -d: -f2)"
if [ -n "$host_port_1" ] && [ -n "$host_port_2" ] && [ "$host_port_1" != "$host_port_2" ]; then
	echo "PASS: sandbox_allocate_ports allocates distinct host ports for the same guest port requested twice in one call"
else
	echo "FAIL: sandbox_allocate_ports allocates distinct host ports for the same guest port requested twice in one call (got '$same_call_ports')"
	failures=$((failures + 1))
fi

# Simulates two sandboxes spawned "at the same time" both requesting the
# same guest port (issue 005 acceptance criterion 4): once the first
# spawn's VM is up (so its forward shows up in `limactl list --json`), a
# second, independent sandbox_allocate_ports call for the same guest port
# must land on a different host port -- no collision.
first_spawn_mapping="$(sandbox_allocate_ports "8000")"
first_spawn_host_port="$(echo "$first_spawn_mapping" | cut -d: -f2)"

limactl() {
	cat <<-EOF
	{"name":"task-a","status":"Running","config":{"portForwards":[{"guestPort":8000,"hostPort":$first_spawn_host_port}]}}
	EOF
}

second_spawn_mapping="$(sandbox_allocate_ports "8000")"
second_spawn_host_port="$(echo "$second_spawn_mapping" | cut -d: -f2)"

if [ "$first_spawn_host_port" != "$second_spawn_host_port" ]; then
	echo "PASS: two sandboxes requesting the same guest port get different host ports once the first is running"
else
	echo "FAIL: two sandboxes requesting the same guest port get different host ports once the first is running (both got '$first_spawn_host_port')"
	failures=$((failures + 1))
fi

unset -f limactl

# --- sandbox_port_forwards_yaml (issue 005) ---

empty_forwards_yaml="$(sandbox_port_forwards_yaml "")"
assert_eq "" "$empty_forwards_yaml" "sandbox_port_forwards_yaml prints nothing for empty input"

forwards_yaml="$(sandbox_port_forwards_yaml "8000:60100
5432:60101")"
assert_eq "portForwards:
- guestPort: 8000
  hostPort: 60100
- guestPort: 5432
  hostPort: 60101" "$forwards_yaml" \
	"sandbox_port_forwards_yaml renders a portForwards YAML block, one list item per mapping"

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

fixture_template_dotfiles="$(mktemp)"
cat > "$fixture_template_dotfiles" <<-'EOF'
mounts:
- location: "__SANDBOX_DOTFILES_PATH__"
  mountPoint: "{{.Home}}/dotfiles"
  writable: false
EOF

rendered_with_dotfiles="$(sandbox_render_lima_config "$fixture_template_dotfiles" 60099 /tmp/some-worktree '' /tmp/some-dotfiles-checkout)"

case "$rendered_with_dotfiles" in
*/tmp/some-dotfiles-checkout*) echo "PASS: sandbox_render_lima_config substitutes the dotfiles repo path" ;;
*) echo "FAIL: sandbox_render_lima_config substitutes the dotfiles repo path"; failures=$((failures + 1)) ;;
esac

fixture_template_gitdir="$(mktemp)"
cat > "$fixture_template_gitdir" <<-'EOF'
mounts:
- location: "__SANDBOX_REPO_GITDIR__"
  mountPoint: "__SANDBOX_REPO_GITDIR__"
  writable: true
EOF

rendered_with_gitdir="$(sandbox_render_lima_config "$fixture_template_gitdir" 60099 /tmp/some-worktree '' '' /tmp/some-repo/.git)"

case "$rendered_with_gitdir" in
*/tmp/some-repo/.git*) echo "PASS: sandbox_render_lima_config substitutes the repo git-common-dir path" ;;
*) echo "FAIL: sandbox_render_lima_config substitutes the repo git-common-dir path"; failures=$((failures + 1)) ;;
esac

rm -f "$fixture_template" "$fixture_template_dotfiles" "$fixture_template_gitdir"

# --- sandbox_render_lima_config: --base template provisioning (issue 003) ---

fixture_template_base="$(mktemp)"
cat > "$fixture_template_base" <<-'EOF'
	provision:
	- mode: system
	  script: |
	    echo "base provisioning"
	__SANDBOX_BASE_PROVISION__
	EOF

fixture_base_template="$(mktemp)"
cat > "$fixture_base_template" <<-'EOF'
	- mode: system
	  script: |
	    echo "FIXTURE_BASE_TEMPLATE_CONTENT"
	EOF

rendered_with_base="$(sandbox_render_lima_config "$fixture_template_base" 60099 /tmp/some-worktree '' '' '' "$fixture_base_template")"

case "$rendered_with_base" in
*FIXTURE_BASE_TEMPLATE_CONTENT*) echo "PASS: sandbox_render_lima_config splices the selected --base template's provisioning into the output" ;;
*) echo "FAIL: sandbox_render_lima_config splices the selected --base template's provisioning into the output"; failures=$((failures + 1)) ;;
esac

case "$rendered_with_base" in
*__SANDBOX_BASE_PROVISION__*) echo "FAIL: sandbox_render_lima_config removes the __SANDBOX_BASE_PROVISION__ placeholder"; failures=$((failures + 1)) ;;
*) echo "PASS: sandbox_render_lima_config removes the __SANDBOX_BASE_PROVISION__ placeholder" ;;
esac

fixture_base_template_empty="$(mktemp)"

rendered_with_none="$(sandbox_render_lima_config "$fixture_template_base" 60099 /tmp/some-worktree '' '' '' "$fixture_base_template_empty")"

case "$rendered_with_none" in
*__SANDBOX_BASE_PROVISION__*) echo "FAIL: sandbox_render_lima_config's 'none' template (empty file) still removes the placeholder"; failures=$((failures + 1)) ;;
*) echo "PASS: sandbox_render_lima_config's 'none' template (empty file) still removes the placeholder" ;;
esac

assert_eq "provision:
- mode: system
  script: |
    echo \"base provisioning\"" "$rendered_with_none" \
	"sandbox_render_lima_config's 'none' template yields the same output as no base provisioning at all"

rm -f "$fixture_template_base" "$fixture_base_template" "$fixture_base_template_empty"

# --- sandbox_render_lima_config: --ports port-forward splicing (issue 005) ---

fixture_template_ports="$(mktemp)"
cat > "$fixture_template_ports" <<-'EOF'
	ssh:
	  localPort: __SANDBOX_SSH_PORT__

	__SANDBOX_PORT_FORWARDS__

	mounts: []
	EOF

rendered_with_ports="$(sandbox_render_lima_config "$fixture_template_ports" 60099 /tmp/some-worktree '' '' '' '' "8000:60100
5432:60101")"

case "$rendered_with_ports" in
*'portForwards:'*'guestPort: 8000'*'hostPort: 60100'*'guestPort: 5432'*'hostPort: 60101'*)
	echo "PASS: sandbox_render_lima_config splices the --ports mapping into a portForwards YAML block" ;;
*)
	echo "FAIL: sandbox_render_lima_config splices the --ports mapping into a portForwards YAML block (got: $rendered_with_ports)"
	failures=$((failures + 1)) ;;
esac

case "$rendered_with_ports" in
*__SANDBOX_PORT_FORWARDS__*) echo "FAIL: sandbox_render_lima_config removes the __SANDBOX_PORT_FORWARDS__ placeholder"; failures=$((failures + 1)) ;;
*) echo "PASS: sandbox_render_lima_config removes the __SANDBOX_PORT_FORWARDS__ placeholder" ;;
esac

rendered_without_ports="$(sandbox_render_lima_config "$fixture_template_ports" 60099 /tmp/some-worktree '' '' '' '' '')"

case "$rendered_without_ports" in
*portForwards*) echo "FAIL: sandbox_render_lima_config renders no portForwards key when --ports is omitted"; failures=$((failures + 1)) ;;
*) echo "PASS: sandbox_render_lima_config renders no portForwards key when --ports is omitted" ;;
esac

assert_eq "ssh:
  localPort: 60099


mounts: []" "$rendered_without_ports" \
	"sandbox_render_lima_config with no --ports mapping yields the same output as before issue 005"

rm -f "$fixture_template_ports"

if grep -qF '__SANDBOX_PORT_FORWARDS__' "$SANDBOX_DIR/lima-template.yaml"; then
	echo "PASS: lima-template.yaml contains the __SANDBOX_PORT_FORWARDS__ placeholder (issue 005)"
else
	echo "FAIL: lima-template.yaml contains the __SANDBOX_PORT_FORWARDS__ placeholder (issue 005)"
	failures=$((failures + 1))
fi

if grep -qF '__SANDBOX_BASE_PROVISION__' "$SANDBOX_DIR/lima-template.yaml"; then
	echo "PASS: lima-template.yaml contains the __SANDBOX_BASE_PROVISION__ placeholder (issue 003)"
else
	echo "FAIL: lima-template.yaml contains the __SANDBOX_BASE_PROVISION__ placeholder (issue 003)"
	failures=$((failures + 1))
fi

# --- credential mounts in the real base template (issue 004) ---

template_file="$SANDBOX_DIR/lima-template.yaml"

for cred_path in '~/.config/gh' '~/.aws'; do
	if grep -qF "location: \"$cred_path\"" "$template_file"; then
		echo "PASS: lima-template.yaml mounts $cred_path"
	else
		echo "FAIL: lima-template.yaml mounts $cred_path"
		failures=$((failures + 1))
	fi
done

# ~/.claude and ~/.copilot are deliberately NOT host-mounted: almost
# everything under them is runtime-writable (transcripts, session state,
# caches), so a read-only mount fails with EROFS the moment either CLI
# runs. Auth/skills reach the guest a different way (forwarded oauth
# token, dotfiles-sync-agents) instead of a live mount.
for non_cred_path in '~/.claude' '~/.copilot'; do
	if grep -qF "location: \"$non_cred_path\"" "$template_file"; then
		echo "FAIL: lima-template.yaml does not mount $non_cred_path"
		failures=$((failures + 1))
	else
		echo "PASS: lima-template.yaml does not mount $non_cred_path"
	fi
done

if grep -qF 'location: "__SANDBOX_DOTFILES_PATH__"' "$template_file"; then
	echo "PASS: lima-template.yaml mounts the dotfiles repo itself"
else
	echo "FAIL: lima-template.yaml mounts the dotfiles repo itself"
	failures=$((failures + 1))
fi

if grep -qF 'location: "__SANDBOX_REPO_GITDIR__"' "$template_file" && grep -qF 'mountPoint: "__SANDBOX_REPO_GITDIR__"' "$template_file"; then
	echo "PASS: lima-template.yaml mounts the spawning repo's real git directory at the same absolute path"
else
	echo "FAIL: lima-template.yaml mounts the spawning repo's real git directory at the same absolute path"
	failures=$((failures + 1))
fi

# Exactly two mounts may be writable: the worktree itself, and the repo's
# real git directory (needed for any git command inside the worktree to
# work at all -- a linked worktree's `.git` file points at an absolute
# host path inside it; see sandbox_render_lima_config's doc comment).
# Every other mount must be explicitly read-only.
writable_true_count="$(grep -c 'writable: true' "$template_file")"
assert_eq "2" "$writable_true_count" "lima-template.yaml has exactly two writable:true mounts (the worktree and the repo git directory)"

if grep -qE '\.ssh|git-credential|GIT_' "$template_file"; then
	echo "FAIL: lima-template.yaml contains no git/SSH credential references"
	failures=$((failures + 1))
else
	echo "PASS: lima-template.yaml contains no git/SSH credential references"
fi

echo "$failures failure(s)"
[ "$failures" -eq 0 ]
