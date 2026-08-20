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

# --- sandbox_allocate_ports (issue 005; guest-port-first scan added later) ---

# Stub `sandbox_host_port_free` the same way `limactl` is stubbed above:
# shell functions are looked up before PATH, so this shadows the real
# OS-level bind probe for every test below unless a test overrides it
# itself. Defaults to "every port is free" so tests exercise only the
# Lima-claimed-port logic unless they explicitly simulate an OS-level
# collision.
sandbox_host_port_free() {
	return 0
}

limactl() {
	echo ""
}

no_sandboxes_ports="$(sandbox_allocate_ports "8000,5432")"
assert_eq "8000:8000
5432:5432" "$no_sandboxes_ports" \
	"sandbox_allocate_ports maps each guest port to that same host port when nothing claims it"

# Another running sandbox's SSH port *and* an existing port forward
# (config.portForwards[].hostPort -- confirmed against Lima's real
# limatype.Instance/PortForward JSON field names) must both be skipped.
limactl() {
	cat <<-EOF
	{"name":"task-a","status":"Running","sshLocalPort":$SANDBOX_SSH_PORT_MIN,"config":{"portForwards":[{"guestPort":8000,"hostPort":8000}]}}
	EOF
}

with_forward_claimed="$(sandbox_allocate_ports "8000")"
assert_eq "8000:8001" "$with_forward_claimed" \
	"sandbox_allocate_ports scans upward from the guest port when that host port is already claimed by another running sandbox's port forward"

# An OS-level collision (some unrelated host process already bound to the
# guest port's own number) must be skipped too, even with no sandboxes
# running at all.
limactl() {
	echo ""
}
sandbox_host_port_free() {
	[ "$1" != "5432" ]
}

with_os_level_collision="$(sandbox_allocate_ports "5432")"
assert_eq "5432:5433" "$with_os_level_collision" \
	"sandbox_allocate_ports scans upward from the guest port when that host port is bound by an unrelated host process"

sandbox_host_port_free() {
	return 0
}

# EXTRA_RESERVED_PORTS (e.g. this same spawn's own just-allocated SSH port,
# which won't show up in `limactl list --json` until its VM is up) must
# also be skipped.
with_extra_reserved="$(sandbox_allocate_ports "8000" "8000")"
assert_eq "8000:8001" "$with_extra_reserved" \
	"sandbox_allocate_ports skips a port passed in as an extra reserved port"

# Two guest ports in the *same* spawn must never collide with each other
# either, even before either is visible via `limactl list --json`.
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

# The upward scan must give up once it reaches SANDBOX_FORWARD_PORT_SCAN_MAX
# rather than looping forever.
limactl() {
	echo ""
}
sandbox_host_port_free() {
	return 1
}

if SANDBOX_FORWARD_PORT_SCAN_MAX=8002 sandbox_allocate_ports "8000" >/dev/null 2>&1; then
	echo "FAIL: sandbox_allocate_ports errors once the scan reaches SANDBOX_FORWARD_PORT_SCAN_MAX"
	failures=$((failures + 1))
else
	echo "PASS: sandbox_allocate_ports errors once the scan reaches SANDBOX_FORWARD_PORT_SCAN_MAX"
fi

unset -f limactl sandbox_host_port_free

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

# --- sandbox_port_forwards_yaml: template-contributed static fragment (issue 013) ---
#
# A directory template's port_forwards.yaml (e.g. an `ignore: true` rule
# suppressing Lima's own built-in "forward every guest port on 127.0.0.1"
# catch-all -- see lima-vm/lima#2901) must combine with --ports' own
# dynamic mappings into the SAME portForwards: list, and must still render
# even when there are no --ports mappings at all.

template_fragment_ignore="$(mktemp)"
cat > "$template_fragment_ignore" <<-'EOF'
	- guestPort: 6379
	  ignore: true
	EOF

assert_eq "portForwards:
- guestPort: 6379
  ignore: true" "$(sandbox_port_forwards_yaml "" "$template_fragment_ignore")" \
	"sandbox_port_forwards_yaml renders a template's static fragment even with no --ports mappings at all"

assert_eq "portForwards:
- guestPort: 8000
  hostPort: 60100
- guestPort: 6379
  ignore: true" "$(sandbox_port_forwards_yaml "8000:60100" "$template_fragment_ignore")" \
	"sandbox_port_forwards_yaml combines --ports' dynamic mappings and a template's static fragment in one portForwards: list"

assert_eq "" "$(sandbox_port_forwards_yaml "" "")" \
	"sandbox_port_forwards_yaml prints nothing when both mappings and the template fragment are empty"

nonexistent_fragment="$(mktemp -u)"
assert_eq "" "$(sandbox_port_forwards_yaml "" "$nonexistent_fragment")" \
	"sandbox_port_forwards_yaml prints nothing for a nonexistent template fragment path"

rm -f "$template_fragment_ignore"

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

# --- sandbox_render_lima_config: a directory template's port_forwards.yaml (issue 013) ---

fixture_port_forwards_fragment="$(mktemp)"
cat > "$fixture_port_forwards_fragment" <<-'EOF'
	- guestPort: 6379
	  ignore: true
	EOF

rendered_with_template_forwards_no_ports="$(sandbox_render_lima_config "$fixture_template_ports" 60099 /tmp/some-worktree '' '' '' '' '' '' "$fixture_port_forwards_fragment")"

case "$rendered_with_template_forwards_no_ports" in
*'portForwards:'*'guestPort: 6379'*'ignore: true'*)
	echo "PASS: a directory template's port_forwards.yaml renders a portForwards: block even with --ports omitted entirely" ;;
*)
	echo "FAIL: a directory template's port_forwards.yaml renders a portForwards: block even with --ports omitted entirely (got: $rendered_with_template_forwards_no_ports)"
	failures=$((failures + 1)) ;;
esac

rendered_with_both="$(sandbox_render_lima_config "$fixture_template_ports" 60099 /tmp/some-worktree '' '' '' '' "8000:60100" '' "$fixture_port_forwards_fragment")"

case "$rendered_with_both" in
*'portForwards:'*'guestPort: 8000'*'hostPort: 60100'*'guestPort: 6379'*'ignore: true'*)
	echo "PASS: --ports' dynamic mapping and a directory template's port_forwards.yaml combine into one portForwards: list" ;;
*)
	echo "FAIL: --ports' dynamic mapping and a directory template's port_forwards.yaml combine into one portForwards: list (got: $rendered_with_both)"
	failures=$((failures + 1)) ;;
esac

python3 -c "
import yaml
d = yaml.safe_load('''$rendered_with_both''')
assert len(d['portForwards']) == 2, d['portForwards']
print('OK')
" && echo "PASS: the combined portForwards: block parses as one valid YAML list, not two colliding keys" \
	|| { echo "FAIL: the combined portForwards: block parses as one valid YAML list, not two colliding keys"; failures=$((failures + 1)); }

rm -f "$fixture_port_forwards_fragment" "$fixture_template_ports"

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

if grep -qF '__SANDBOX_BASE_MOUNTS__' "$SANDBOX_DIR/lima-template.yaml"; then
	echo "PASS: lima-template.yaml contains the __SANDBOX_BASE_MOUNTS__ placeholder (issue 010)"
else
	echo "FAIL: lima-template.yaml contains the __SANDBOX_BASE_MOUNTS__ placeholder (issue 010)"
	failures=$((failures + 1))
fi

# --- sandbox_render_lima_config: directory-shaped --base templates' extra mounts (issue 010) ---

. "$SANDBOX_DIR/lib/base_template.sh"

fixture_template_dir_base="$(mktemp)"
cat > "$fixture_template_dir_base" <<-'EOF'
	mounts:
	- location: "/existing/mount"
	  mountPoint: "/existing/mount"
	  writable: false
	__SANDBOX_BASE_MOUNTS__

	provision:
	- mode: system
	  script: |
	    echo "base provisioning"
	__SANDBOX_BASE_PROVISION__
	EOF

# A directory template with only provision.yaml (no mounts.yaml) must
# render identically to a flat-file template: its provisioning splices in,
# and the mounts: list gains no extra entries.

dir_template_provision_only="$(mktemp -d)"
cat > "$dir_template_provision_only/provision.yaml" <<-'EOF'
	- mode: system
	  script: |
	    echo "DIR_TEMPLATE_PROVISION_ONLY"
	EOF

resolved_provision_only="$(sandbox_base_template_provision_path "$dir_template_provision_only")"
resolved_mounts_absent="$(sandbox_base_template_mounts_path "$dir_template_provision_only")"

rendered_dir_provision_only="$(sandbox_render_lima_config "$fixture_template_dir_base" 60099 /tmp/some-worktree '' '' '' "$resolved_provision_only" '' "$resolved_mounts_absent")"
rendered_flat_equivalent="$(sandbox_render_lima_config "$fixture_template_dir_base" 60099 /tmp/some-worktree '' '' '' "$resolved_provision_only" '' '')"

case "$rendered_dir_provision_only" in
*DIR_TEMPLATE_PROVISION_ONLY*) echo "PASS: a directory template's provision.yaml (no mounts.yaml) still splices its provisioning" ;;
*) echo "FAIL: a directory template's provision.yaml (no mounts.yaml) still splices its provisioning"; failures=$((failures + 1)) ;;
esac

case "$rendered_dir_provision_only" in
*__SANDBOX_BASE_MOUNTS__*) echo "FAIL: sandbox_render_lima_config removes the __SANDBOX_BASE_MOUNTS__ placeholder when no mounts fragment is given"; failures=$((failures + 1)) ;;
*) echo "PASS: sandbox_render_lima_config removes the __SANDBOX_BASE_MOUNTS__ placeholder when no mounts fragment is given" ;;
esac

mount_entry_count_provision_only="$(printf '%s\n' "$rendered_dir_provision_only" | grep -c '^- location:')"
assert_eq "1" "$mount_entry_count_provision_only" \
	"a directory template with only provision.yaml adds no extra mounts: entries"

assert_eq "$rendered_flat_equivalent" "$rendered_dir_provision_only" \
	"a directory template with only provision.yaml (no mounts.yaml) renders identically whether BASE_MOUNTS is empty-string or omitted"

# A directory template with both provision.yaml and mounts.yaml splices
# both: provisioning at __SANDBOX_BASE_PROVISION__, extra mount(s) at
# __SANDBOX_BASE_MOUNTS__.

dir_template_both="$(mktemp -d)"
cat > "$dir_template_both/provision.yaml" <<-'EOF'
	- mode: system
	  script: |
	    echo "DIR_TEMPLATE_BOTH_PROVISION"
	EOF
cat > "$dir_template_both/mounts.yaml" <<-'EOF'
	- location: "/host/extra"
	  mountPoint: "/guest/extra"
	  writable: false
	EOF

resolved_provision_both="$(sandbox_base_template_provision_path "$dir_template_both")"
resolved_mounts_both="$(sandbox_base_template_mounts_path "$dir_template_both")"

rendered_dir_both="$(sandbox_render_lima_config "$fixture_template_dir_base" 60099 /tmp/some-worktree '' '' '' "$resolved_provision_both" '' "$resolved_mounts_both")"

case "$rendered_dir_both" in
*DIR_TEMPLATE_BOTH_PROVISION*) echo "PASS: a directory template with both files splices its provisioning" ;;
*) echo "FAIL: a directory template with both files splices its provisioning"; failures=$((failures + 1)) ;;
esac

case "$rendered_dir_both" in
*'location: "/host/extra"'*'mountPoint: "/guest/extra"'*) echo "PASS: a directory template with both files splices its extra mount into the mounts: list" ;;
*) echo "FAIL: a directory template with both files splices its extra mount into the mounts: list (got: $rendered_dir_both)"; failures=$((failures + 1)) ;;
esac

mount_entry_count_both="$(printf '%s\n' "$rendered_dir_both" | grep -c '^- location:')"
assert_eq "2" "$mount_entry_count_both" \
	"a directory template with both files leaves the pre-existing mount plus exactly one extra mount entry"

# A directory template with only mounts.yaml (no provision.yaml) splices
# only the extra mount, no additional provision: item.

dir_template_mounts_only="$(mktemp -d)"
cat > "$dir_template_mounts_only/mounts.yaml" <<-'EOF'
	- location: "/host/mounts-only"
	  mountPoint: "/guest/mounts-only"
	  writable: false
	EOF

resolved_provision_mounts_only="$(sandbox_base_template_provision_path "$dir_template_mounts_only")"
resolved_mounts_mounts_only="$(sandbox_base_template_mounts_path "$dir_template_mounts_only")"

rendered_mounts_only="$(sandbox_render_lima_config "$fixture_template_dir_base" 60099 /tmp/some-worktree '' '' '' "$resolved_provision_mounts_only" '' "$resolved_mounts_mounts_only")"

case "$rendered_mounts_only" in
*'location: "/host/mounts-only"'*'mountPoint: "/guest/mounts-only"'*) echo "PASS: a directory template with only mounts.yaml splices its extra mount" ;;
*) echo "FAIL: a directory template with only mounts.yaml splices its extra mount (got: $rendered_mounts_only)"; failures=$((failures + 1)) ;;
esac

provision_item_count_mounts_only="$(printf '%s\n' "$rendered_mounts_only" | grep -c 'mode: system')"
assert_eq "1" "$provision_item_count_mounts_only" \
	"a directory template with only mounts.yaml adds no extra provision: item (just the base fixture's own one)"

case "$rendered_mounts_only" in
*DIR_TEMPLATE*) echo "FAIL: a directory template with only mounts.yaml adds no extra provision: item"; failures=$((failures + 1)) ;;
*) echo "PASS: a directory template with only mounts.yaml adds no extra provision: item" ;;
esac

rm -rf "$fixture_template_dir_base" "$dir_template_provision_only" "$dir_template_both" "$dir_template_mounts_only"

# --- a directory template's files manifest combines with its own provision.yaml (issue 012) ---
#
# No lima-template.yaml/sandbox_render_lima_config change needed for this:
# a `mode: data` entry is just another item in the same `provision:` list
# `mode: system` entries already live in, so the caller (pj-sbx-spawn)
# concatenates provision.yaml's content with
# sandbox_base_template_files_provision_yaml's generated output into one
# file *before* it ever reaches sandbox_render_lima_config's existing
# BASE_TEMPLATE argument -- proven here directly, without needing any new
# placeholder.

fixture_template_provision_only="$(mktemp)"
cat > "$fixture_template_provision_only" <<-'EOF'
	provision:
	- mode: system
	  script: |
	    echo "base provisioning"
	__SANDBOX_BASE_PROVISION__
	EOF

dir_template_with_files="$(mktemp -d)"
cat > "$dir_template_with_files/provision.yaml" <<-'EOF'
	- mode: system
	  script: |
	    echo "DIR_TEMPLATE_WITH_FILES_PROVISION"
	EOF

host_file_for_render_test="$(mktemp)"
printf 'credential file content\n' > "$host_file_for_render_test"
echo "$host_file_for_render_test:/guest/path/cred" > "$dir_template_with_files/files"

resolved_provision_with_files="$(sandbox_base_template_provision_path "$dir_template_with_files")"
resolved_files_manifest="$(sandbox_base_template_files_path "$dir_template_with_files")"

combined_provision_file="$(mktemp)"
cat "$resolved_provision_with_files" > "$combined_provision_file"
sandbox_base_template_files_provision_yaml "$resolved_files_manifest" >> "$combined_provision_file"

rendered_with_files="$(sandbox_render_lima_config "$fixture_template_provision_only" 60099 /tmp/some-worktree '' '' '' "$combined_provision_file")"

case "$rendered_with_files" in
*DIR_TEMPLATE_WITH_FILES_PROVISION*) echo "PASS: the combined splice still includes the directory template's own provision.yaml script" ;;
*) echo "FAIL: the combined splice still includes the directory template's own provision.yaml script"; failures=$((failures + 1)) ;;
esac

case "$rendered_with_files" in
*'mode: data'*'path: "/guest/path/cred"'*) echo "PASS: the combined splice includes the generated mode: data entry for the files manifest" ;;
*) echo "FAIL: the combined splice includes the generated mode: data entry for the files manifest (got: $rendered_with_files)"; failures=$((failures + 1)) ;;
esac

rendered_with_files_yaml_file="$(mktemp)"
sandbox_render_lima_config "$fixture_template_provision_only" 60099 /tmp/some-worktree '' '' '' "$combined_provision_file" > "$rendered_with_files_yaml_file"

python3 -c "
import yaml
d = yaml.safe_load(open('$rendered_with_files_yaml_file'))
items = d['provision']
assert len(items) == 3, items
assert items[0]['mode'] == 'system' and 'base provisioning' in items[0]['script']
assert items[1]['mode'] == 'system' and 'DIR_TEMPLATE_WITH_FILES_PROVISION' in items[1]['script']
assert items[2]['mode'] == 'data' and items[2]['path'] == '/guest/path/cred'
assert items[2]['content'] == 'credential file content\n', repr(items[2]['content'])
print('OK')
" && echo "PASS: the combined splice parses as valid YAML with the base script, template script, and data entry as three distinct provision: items in order" \
	|| { echo "FAIL: the combined splice parses as valid YAML with the base script, template script, and data entry as three distinct provision: items in order"; failures=$((failures + 1)); }

rm -f "$fixture_template_provision_only" "$host_file_for_render_test" "$combined_provision_file" "$rendered_with_files_yaml_file"
rm -rf "$dir_template_with_files"

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
