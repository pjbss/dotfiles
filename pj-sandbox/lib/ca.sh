# ca.sh
#
# The per-install proxy CA. The host proxy signs its interception
# certificates with it, and each guest trusts its certificate (lib/bootstrap.sh).
# The key never leaves the host. Meant to be sourced, not executed.
#
# <config dir>/ca/ holds:
#
#   ca.pem             the certificate, the only file a guest ever gets
#   ca-key.pem         its private key, mode 600
#   mitmproxy-ca.pem   the key then the certificate, mode 600: the file
#                      `mitmdump --set confdir=<config dir>/ca` loads instead
#                      of making its own CA

# pj_sandbox_ca_ensure CONFIG_DIR
#
# Makes CONFIG_DIR/ca/ once, and reuses it after that. A CA missing any of its
# three files is replaced whole, so a certificate is never paired with a
# stray key. The new files are made in a temp dir under ca/ and moved into
# place, so an interrupted run leaves no half-written file behind.
# A subshell, so the umask and traps never leak to the caller.
pj_sandbox_ca_ensure() (
	dir="$1/ca"
	if [ -s "$dir/ca.pem" ] && [ -s "$dir/ca-key.pem" ] && [ -s "$dir/mitmproxy-ca.pem" ]; then
		exit 0
	fi

	umask 077
	mkdir -p "$dir" || exit 1
	chmod 700 "$dir" || exit 1
	tmp="$(mktemp -d "$dir/.new.XXXXXX")" || exit 1
	trap 'rm -rf "$tmp"' EXIT
	trap 'exit 1' HUP INT TERM

	if ! openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
		-subj "/CN=pj-sandbox proxy CA" \
		-addext "basicConstraints=critical,CA:TRUE" \
		-addext "keyUsage=critical,keyCertSign,cRLSign" \
		-keyout "$tmp/ca-key.pem" -out "$tmp/ca.pem" >/dev/null 2>"$tmp/err"; then
		echo "pj-sandbox: couldn't make the proxy CA in $dir: $(cat "$tmp/err")" >&2
		exit 1
	fi
	cat "$tmp/ca-key.pem" "$tmp/ca.pem" > "$tmp/mitmproxy-ca.pem" || exit 1
	chmod 600 "$tmp/ca-key.pem" "$tmp/mitmproxy-ca.pem" || exit 1
	chmod 644 "$tmp/ca.pem" || exit 1

	# The key files go in first, so a crash between moves leaves ca.pem
	# missing (and the CA replaced next time), never a new ca.pem beside an
	# old key.
	rm -f "$dir/ca.pem" || exit 1
	mv -f "$tmp/ca-key.pem" "$dir/ca-key.pem" &&
		mv -f "$tmp/mitmproxy-ca.pem" "$dir/mitmproxy-ca.pem" &&
		mv -f "$tmp/ca.pem" "$dir/ca.pem"
)
