#!/bin/bash
# namespace_test.sh
#
# Tests for pj-sandbox/lib/namespace.sh: every runtime namespace's default,
# every environment override, and the pjsb- instance naming. Each case sources
# namespace.sh in a fresh `env -i` shell, so neither the caller's environment
# nor an earlier case can leak into what's being checked.

set -euo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PJ_SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"
. "$TEST_DIR/../../test/assert.sh"

NAMESPACE="$PJ_SANDBOX_DIR/lib/namespace.sh"

# ns [VAR=value...] -- EXPRESSION
#
# Sources namespace.sh under a clean environment holding only HOME, the
# dotfiles root, and the given assignments, then prints EXPRESSION.
ns() {
	assignments=()
	while [ "$1" != "--" ]; do
		assignments+=("$1")
		shift
	done
	shift
	env -i HOME=/home/tester PATH="$PATH" PJ_SANDBOX_DOTFILES_HOME=/dots ${assignments[@]+"${assignments[@]}"} \
		sh -c '. "$1"; eval "printf %s \"$2\""' sh "$NAMESPACE" "$1"
}

# --- defaults ---

assert_eq "pjsb-" "$(ns -- '$PJ_SANDBOX_INSTANCE_PREFIX')" "instance prefix defaults to pjsb-"
assert_eq "/home/tester/.ssh/pj-sandbox-next-config" "$(ns -- '$PJ_SANDBOX_SSH_INCLUDE_FILE')" "ssh include file defaults to ~/.ssh/pj-sandbox-next-config"
assert_eq "61022" "$(ns -- '$PJ_SANDBOX_PORT_MIN')" "port range starts at 61022"
assert_eq "61099" "$(ns -- '$PJ_SANDBOX_PORT_MAX')" "port range ends at 61099"
assert_eq "/home/tester/.config/pj-sandbox" "$(ns -- '$PJ_SANDBOX_CONFIG_DIR')" "config dir defaults to ~/.config/pj-sandbox"
assert_eq "/home/tester/.local/state/pj-sandbox" "$(ns -- '$PJ_SANDBOX_STATE_DIR')" "state dir defaults to ~/.local/state/pj-sandbox"
assert_eq "/dots/local/pj-sandbox/templates" "$(ns -- '$PJ_SANDBOX_TEMPLATES_DIR')" "templates dir defaults to local/pj-sandbox/templates under the dotfiles root"

# --- XDG base directories ---

assert_eq "/xdg/config/pj-sandbox" "$(ns XDG_CONFIG_HOME=/xdg/config -- '$PJ_SANDBOX_CONFIG_DIR')" "config dir follows XDG_CONFIG_HOME"
assert_eq "/xdg/state/pj-sandbox" "$(ns XDG_STATE_HOME=/xdg/state -- '$PJ_SANDBOX_STATE_DIR')" "state dir follows XDG_STATE_HOME"

# --- environment overrides ---

assert_eq "test-" "$(ns PJ_SANDBOX_INSTANCE_PREFIX=test- -- '$PJ_SANDBOX_INSTANCE_PREFIX')" "PJ_SANDBOX_INSTANCE_PREFIX overrides the prefix"
assert_eq "/tmp/ssh-inc" "$(ns PJ_SANDBOX_SSH_INCLUDE_FILE=/tmp/ssh-inc -- '$PJ_SANDBOX_SSH_INCLUDE_FILE')" "PJ_SANDBOX_SSH_INCLUDE_FILE overrides the ssh include file"
assert_eq "40000" "$(ns PJ_SANDBOX_PORT_MIN=40000 -- '$PJ_SANDBOX_PORT_MIN')" "PJ_SANDBOX_PORT_MIN overrides the range start"
assert_eq "40010" "$(ns PJ_SANDBOX_PORT_MAX=40010 -- '$PJ_SANDBOX_PORT_MAX')" "PJ_SANDBOX_PORT_MAX overrides the range end"
assert_eq "/tmp/cfg" "$(ns XDG_CONFIG_HOME=/xdg/config PJ_SANDBOX_CONFIG_DIR=/tmp/cfg -- '$PJ_SANDBOX_CONFIG_DIR')" "PJ_SANDBOX_CONFIG_DIR overrides the config dir, even over XDG_CONFIG_HOME"
assert_eq "/tmp/state" "$(ns XDG_STATE_HOME=/xdg/state PJ_SANDBOX_STATE_DIR=/tmp/state -- '$PJ_SANDBOX_STATE_DIR')" "PJ_SANDBOX_STATE_DIR overrides the state dir, even over XDG_STATE_HOME"
assert_eq "/tmp/tpl" "$(ns PJ_SANDBOX_TEMPLATES_DIR=/tmp/tpl -- '$PJ_SANDBOX_TEMPLATES_DIR')" "PJ_SANDBOX_TEMPLATES_DIR overrides the templates dir"

# --- pj_sandbox_instance_name ---

name="$(ns -- '$(pj_sandbox_instance_name "My Task!! Foo_Bar  #42")')"
assert_eq "pjsb-my-task-foo-bar-42" "$name" "instance name is the pjsb- prefix plus the slugged task name"

case "$name" in
	pjsb-*) echo "PASS: instance name starts with pjsb-" ;;
	*) echo "FAIL: instance name starts with pjsb- (got '$name')"; failures=$((failures + 1)) ;;
esac

if printf '%s' "$name" | grep -Eq '^[A-Za-z0-9]+([._-][A-Za-z0-9]+)*$'; then
	echo "PASS: instance name is Lima-valid"
else
	echo "FAIL: instance name is Lima-valid (got '$name')"
	failures=$((failures + 1))
fi

assert_eq "pjsb-sandbox-task" "$(ns -- '$(pj_sandbox_instance_name "!!!")')" "an all-punctuation task name still gets a valid, prefixed name"
assert_eq "test-my-task" "$(ns PJ_SANDBOX_INSTANCE_PREFIX=test- -- '$(pj_sandbox_instance_name "my task")')" "instance name uses an overridden prefix"

assert_report
