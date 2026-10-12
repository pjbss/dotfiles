#!/bin/bash
# ca_test.sh
#
# Tests for the per-install proxy CA (lib/ca.sh): pj_sandbox_ca_ensure makes
# <config dir>/ca/{ca.pem,ca-key.pem} plus mitmproxy's confdir file once, the
# key files are mode 600, and a second call reuses what's there. Runs the real
# openssl against a temp config dir.

set -euo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PJ_SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"
. "$TEST_DIR/../../test/assert.sh"

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

. "$PJ_SANDBOX_DIR/lib/ca.sh"

config="$fixture/config"
ca="$config/ca"

mode_of() {
	stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

# --- the first call makes the CA ---

if out="$(pj_sandbox_ca_ensure "$config" 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "pj_sandbox_ca_ensure exits 0 (output: $out)"
assert_ok "it writes ca/ca.pem" test -s "$ca/ca.pem"
assert_ok "it writes ca/ca-key.pem" test -s "$ca/ca-key.pem"
assert_ok "it writes mitmproxy's confdir file, ca/mitmproxy-ca.pem" test -s "$ca/mitmproxy-ca.pem"

assert_eq "600" "$(mode_of "$ca/ca-key.pem")" "ca-key.pem is mode 600"
assert_eq "600" "$(mode_of "$ca/mitmproxy-ca.pem")" "mitmproxy-ca.pem (which holds the key) is mode 600"
assert_eq "700" "$(mode_of "$ca")" "the ca dir is mode 700"

assert_ok "ca.pem is a CA certificate" sh -c "openssl x509 -in '$ca/ca.pem' -noout -text | grep -q 'CA:TRUE'"
assert_not_contains "$(cat "$ca/ca.pem")" "PRIVATE KEY" "ca.pem holds no private key"
assert_eq "$(openssl x509 -in "$ca/ca.pem" -noout -pubkey)" "$(openssl pkey -in "$ca/ca-key.pem" -pubout)" \
	"ca-key.pem is ca.pem's key"
assert_eq "$(cat "$ca/ca-key.pem" "$ca/ca.pem")" "$(cat "$ca/mitmproxy-ca.pem")" \
	"mitmproxy-ca.pem is the key then the certificate, as mitmproxy's confdir expects"

# --- a second call reuses it ---

before="$(cat "$ca/ca.pem" "$ca/ca-key.pem" "$ca/mitmproxy-ca.pem")"
if out="$(pj_sandbox_ca_ensure "$config" 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "a second pj_sandbox_ca_ensure exits 0 (output: $out)"
assert_eq "$before" "$(cat "$ca/ca.pem" "$ca/ca-key.pem" "$ca/mitmproxy-ca.pem")" \
	"a second call doesn't regenerate the CA"

# --- a half-made CA is replaced whole, never paired with a stray key ---

rm -f "$ca/ca.pem"
pj_sandbox_ca_ensure "$config" >/dev/null 2>&1 || true
assert_ok "a missing ca.pem is made again" test -s "$ca/ca.pem"
assert_eq "$(openssl x509 -in "$ca/ca.pem" -noout -pubkey 2>/dev/null || true)" "$(openssl pkey -in "$ca/ca-key.pem" -pubout 2>/dev/null || true)" \
	"after a repair, ca-key.pem is still ca.pem's key"
assert_eq "$(cat "$ca/ca-key.pem" "$ca/ca.pem")" "$(cat "$ca/mitmproxy-ca.pem")" \
	"after a repair, mitmproxy-ca.pem matches the new pair"

assert_report
