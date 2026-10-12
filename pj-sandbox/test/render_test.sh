#!/bin/bash
# render_test.sh
#
# Tests for pj-sandbox/lib/render.sh rendering pj-sandbox/lima/template.yaml:
# no host directory is ever mounted, every port forward is bound to loopback,
# and the ssh port lands where it was told to.

set -euo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PJ_SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"
. "$TEST_DIR/../../test/assert.sh"

TEMPLATE="$PJ_SANDBOX_DIR/lima/template.yaml"

# render SSH_PORT [MAPPINGS]
#
# Renders the real template under POSIX sh.
render() {
	sh -c 'PJ_SANDBOX_DOTFILES_HOME=/unused; . "$1/lib/namespace.sh"; . "$1/lib/render.sh"; shift; pj_sandbox_render_lima_config "$@"' \
		sh "$PJ_SANDBOX_DIR" "$TEMPLATE" "$@"
}

# --- no ports ---

out="$(render 61022)"
assert_contains "$out" "$(printf 'ssh:\n  localPort: 61022')" "ssh.localPort is the allocated port"
assert_eq "1" "$(printf '%s\n' "$out" | grep -c '^mounts: \[\]$')" "the config has exactly one explicit 'mounts: []'"
assert_eq "" "$(printf '%s\n' "$out" | grep 'location:' || true)" "the config has no 'location:' key anywhere"
assert_eq "" "$(printf '%s\n' "$out" | grep '^mounts:' | grep -v '^mounts: \[\]$' || true)" "there's no other mounts: key"
assert_eq "" "$(printf '%s\n' "$out" | grep '__PJ_SANDBOX_' || true)" "no placeholder survives rendering"
assert_eq "" "$(printf '%s\n' "$out" | grep 'portForwards' || true)" "no --ports renders no portForwards key"
assert_eq "" "$(printf '%s\n' "$out" | grep '^provision:' || true)" "no base provisioning renders no provision key"
assert_contains "$out" "minimumLimaVersion: 2.0.0" "the config pins minimumLimaVersion 2.0.0"
assert_contains "$out" "template:_images/ubuntu-lts" "the config is based on Ubuntu LTS"

# --- port forwards ---

out="$(render 61030 "$(printf '%s\n' 8000:61031 5432:61032)")"
assert_contains "$out" "$(printf 'ssh:\n  localPort: 61030')" "ssh.localPort is substituted alongside forwards"
assert_contains "$out" "$(printf -- '- guestPort: 8000\n  hostPort: 61031\n  hostIP: 127.0.0.1')" "a forward maps its guest port to its host port on 127.0.0.1"
assert_contains "$out" "$(printf -- '- guestPort: 5432\n  hostPort: 61032\n  hostIP: 127.0.0.1')" "every forward is rendered"
assert_eq "2" "$(printf '%s\n' "$out" | grep -c 'guestPort:')" "one forward per mapping"
assert_eq "2" "$(printf '%s\n' "$out" | grep -c '^  hostIP: 127.0.0.1$')" "every forward has hostIP: 127.0.0.1"
assert_eq "" "$(printf '%s\n' "$out" | grep 'location:' || true)" "forwards add no 'location:' key"

# Parsed as YAML when PyYAML is around, so the shape is checked and not just
# the text.
if python3 -c 'import yaml' 2>/dev/null; then
	got="$(printf '%s\n' "$out" | python3 -c '
import sys, yaml
c = yaml.safe_load(sys.stdin)
print(c["mounts"])
print(c["ssh"]["localPort"])
print([(f["guestPort"], f["hostPort"], f["hostIP"]) for f in c["portForwards"]])
')"
	assert_eq "$(printf '%s\n' '[]' 61030 "[(8000, 61031, '127.0.0.1'), (5432, 61032, '127.0.0.1')]")" "$got" "the rendered config parses as YAML with the expected mounts, ssh port and forwards"
fi

# --- base template provisioning ---

empty="$(mktemp)"
trap 'rm -f "$empty"' EXIT
out="$(render 61040 "" "$empty")"
assert_eq "" "$(printf '%s\n' "$out" | grep '^provision:' || true)" "an empty provision fragment renders no provision key"
assert_eq "" "$(printf '%s\n' "$out" | grep '__PJ_SANDBOX_' || true)" "no placeholder survives an empty fragment"

out="$(render 61040 "8000:61041" "$PJ_SANDBOX_DIR/templates/python3.12")"
assert_contains "$out" "$(printf 'provision:\n%s' "$(cat "$PJ_SANDBOX_DIR/templates/python3.12")")" "--base python3.12's provision block is rendered under provision:"
assert_eq "1" "$(printf '%s\n' "$out" | grep -c '^mounts: \[\]$')" "a provisioned config still has mounts: []"
assert_eq "" "$(printf '%s\n' "$out" | grep 'location:' || true)" "provisioning adds no 'location:' key"
assert_eq "" "$(printf '%s\n' "$out" | grep '__PJ_SANDBOX_' || true)" "no placeholder survives a provisioned render"
if python3 -c 'import yaml' 2>/dev/null; then
	got="$(printf '%s\n' "$out" | python3 -c '
import sys, yaml
c = yaml.safe_load(sys.stdin)
print(c["mounts"])
print([p["mode"] for p in c["provision"]])
print("python3.12-venv" in c["provision"][0]["script"])
print(len(c["portForwards"]))
')"
	assert_eq "$(printf '%s\n' '[]' "['system']" True 1)" "$got" "the provisioned config parses as YAML with mounts: [], the template's provision item and the forward"
fi

assert_report
