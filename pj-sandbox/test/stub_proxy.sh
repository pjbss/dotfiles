# stub_proxy.sh
#
# Stub host commands for the task proxy that `pj-sandbox spawn` starts, shared
# by every test that runs spawn. Sourced, not run. The real mitmdump may be
# installed on the host, and token sources may reach the real Keychain or gh,
# so each spawn test puts these first on PATH.

# pj_test_stub_proxy BIN_DIR
#
# Writes into BIN_DIR:
#   mitmdump  appends its argv to $STUB_DIR/mitmdump-calls and saves its
#             environment, where the proxy's tokens are, to
#             $STUB_DIR/mitmdump-env.<its PID>, then idles until
#             killed or until $STUB_DIR is removed, so a test's own cleanup
#             ends every stub proxy it left. With MITMDUMP_FAIL set it exits 1
#             at once, like a mitmdump refusing a bad policy.
#   gh, security
#             fail, so no token source ever yields a real token.
pj_test_stub_proxy() {
	cat > "$1/mitmdump" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_DIR/mitmdump-calls"
env > "$STUB_DIR/mitmdump-env.$$"
[ -z "${MITMDUMP_FAIL:-}" ] || exit 1
while [ -d "$STUB_DIR" ]; do sleep 1; done
STUB
	printf '#!/bin/sh\nexit 1\n' > "$1/gh"
	printf '#!/bin/sh\nexit 1\n' > "$1/security"
	chmod +x "$1/mitmdump" "$1/gh" "$1/security"
}
