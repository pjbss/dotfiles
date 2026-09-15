#!/bin/bash
# credential_mounts_test.sh
#
# Tests sandbox_render_lima_config's CREDENTIAL_MOUNTS argument -- what
# pj-sbx-spawn's `--no-creds` passes when a VM is going to run an unattended
# coding agent.
#
# The point of the flag is that a credential never forwarded can't be
# exfiltrated by a prompt injection sitting in the repo the agent was pointed
# at, so these assert both halves: the gh/AWS mounts are gone, and everything
# the sandbox genuinely needs (the worktree, the dotfiles repo, and above all
# the git directory mount, without which no git command inside /workspace
# works at all) is still there.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"
DOTFILES_HOME="$(cd -P "$SANDBOX_DIR/.." && pwd)"

. "$DOTFILES_HOME/test/assert.sh"
. "$SANDBOX_DIR/lib/task.sh"

template="$SANDBOX_DIR/lima-template.yaml"

with_creds="$(sandbox_render_lima_config "$template" 60022 /wt my-profile /df /gd "" "" "" "" yes)"
without_creds="$(sandbox_render_lima_config "$template" 60022 /wt my-profile /df /gd "" "" "" "" no)"
defaulted="$(sandbox_render_lima_config "$template" 60022 /wt my-profile /df /gd)"

# --- the default is unchanged: omitting the argument keeps credentials ---

assert_contains "$defaulted" 'location: "~/.config/gh"' "omitting CREDENTIAL_MOUNTS keeps the gh mount (existing callers are unaffected)"
assert_contains "$defaulted" 'location: "~/.aws"' "omitting CREDENTIAL_MOUNTS keeps the AWS mount"

assert_contains "$with_creds" 'location: "~/.config/gh"' "CREDENTIAL_MOUNTS=yes keeps the gh mount"
assert_contains "$with_creds" 'location: "~/.aws"' "CREDENTIAL_MOUNTS=yes keeps the AWS mount"

# --- no is what actually withholds them ---

assert_not_contains "$without_creds" 'location: "~/.config/gh"' "CREDENTIAL_MOUNTS=no drops the gh credential mount"
assert_not_contains "$without_creds" '{{.Home}}/.config/gh' "CREDENTIAL_MOUNTS=no leaves no orphaned gh mountPoint line behind"
assert_not_contains "$without_creds" 'location: "~/.aws"' "CREDENTIAL_MOUNTS=no drops the AWS credential mount"
assert_not_contains "$without_creds" '{{.Home}}/.aws' "CREDENTIAL_MOUNTS=no leaves no orphaned AWS mountPoint line behind"

# --- everything the sandbox actually needs survives ---

assert_contains "$without_creds" 'mountPoint: "/workspace"' "CREDENTIAL_MOUNTS=no keeps the worktree mount"
assert_contains "$without_creds" 'mountPoint: "{{.Home}}/dotfiles"' "CREDENTIAL_MOUNTS=no keeps the dotfiles mount"
assert_contains "$without_creds" 'location: "/gd"' "CREDENTIAL_MOUNTS=no keeps the git directory mount, without which git inside /workspace fails outright"

# --- the mounts list is still well-formed YAML ---

mount_count_with="$(printf '%s\n' "$with_creds" | grep -c '^- location:')"
mount_count_without="$(printf '%s\n' "$without_creds" | grep -c '^- location:')"
assert_eq "$((mount_count_with - 2))" "$mount_count_without" "exactly two mount entries are removed, no more and no fewer"

orphans="$(printf '%s\n' "$without_creds" | awk '
	/^- location:/ { in_mount = 1; next }
	/^  (mountPoint|writable):/ { if (!in_mount) print; next }
	{ in_mount = 0 }
')"
assert_eq "" "$orphans" "no mount key is left behind without its own '- location:' line"

if command -v python3 >/dev/null 2>&1; then
	python3 - "$without_creds" <<'PY' && parse_rc=0 || parse_rc=$?
import sys
try:
    import yaml
except ImportError:
    sys.exit(0)
yaml.safe_load(sys.argv[1])
PY
	assert_exit_code 0 "$parse_rc" "the credential-free config still parses as YAML"
fi

assert_report
