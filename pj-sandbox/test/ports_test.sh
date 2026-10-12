#!/bin/bash
# ports_test.sh
#
# Tests for pj-sandbox/lib/ports.sh: ssh and forward host ports come from the
# pj-sandbox range, skipping ports other pjsb- state records hold and ports
# the host reports as bound. pj_sandbox_host_port_free is shadowed with a stub
# that reports the ports in $BOUND as bound, so no real socket is probed.

set -euo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PJ_SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"
. "$TEST_DIR/../../test/assert.sh"

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

export PJ_SANDBOX_STATE_DIR="$fixture/state"
export PJ_SANDBOX_DOTFILES_HOME="$fixture/dots"
export PJ_SANDBOX_PORT_MIN=61022
export PJ_SANDBOX_PORT_MAX=61030
export BOUND=""

# p SCRIPT
#
# Runs SCRIPT under POSIX sh with the libraries sourced and the bind probe
# stubbed from $BOUND.
p() {
	sh -c '. "$1/lib/namespace.sh"; . "$1/lib/state.sh"; . "$1/lib/ports.sh"
		pj_sandbox_host_port_free() { case " $BOUND " in *" $1 "*) return 1 ;; esac; }
		eval "$2"' sh "$PJ_SANDBOX_DIR" "$1"
}

record() {
	p "pj_sandbox_state_write $*"
}

# --- empty state ---

assert_eq "61022" "$(p pj_sandbox_allocate_port)" "the first ssh port is the bottom of the range"
assert_eq "" "$(p pj_sandbox_used_ports)" "no records hold no ports"

# --- ports held by state records ---

record alpha task=alpha instance=pjsb-alpha ssh_port=61022 ports=8000:61023,5432:61024
record "'b e t a'" task=beta instance=pjsb-beta ssh_port=61025

assert_eq "$(printf '%s\n' 61022 61023 61024 61025)" "$(p pj_sandbox_used_ports | sort -n)" "used ports are every record's ssh port and forward host ports"
assert_eq "61026" "$(p pj_sandbox_allocate_port)" "the ssh port skips ports held by other state records"

# --- ports reported as bound ---

assert_eq "61028" "$(BOUND="61026 61027" p pj_sandbox_allocate_port)" "the ssh port skips ports the host reports as bound"
assert_eq "61027" "$(p 'pj_sandbox_allocate_port 61026')" "the ssh port skips reserved ports passed in"

# --- forwards ---

assert_eq "$(printf '%s\n' 8000:61027 5432:61029)" \
	"$(BOUND="61028" p 'pj_sandbox_allocate_ports 8000,5432 61026')" \
	"each forward gets the next free host port, skipping records, reserved, bound and earlier forwards"
assert_eq "" "$(p 'pj_sandbox_allocate_ports ""')" "no guest ports allocates nothing"

# --- exhaustion ---

if out="$(BOUND="61026 61027 61028 61029 61030" p pj_sandbox_allocate_port 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "allocation fails when the range is used up"
assert_contains "$out" "no free port" "an exhausted range says so"

if out="$(BOUND="61027 61028 61029 61030" p 'pj_sandbox_allocate_ports 8000,5432 61026' 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "forward allocation fails when the range runs out mid-list"

assert_report
