#!/bin/bash
# spike_ca.sh
#
# The CA and pinning spike (issues/prd-pj-sandbox.md, "CA and pinning spike";
# issue 010). For each agent it answers one question: does the agent accept a
# proxy CA, and a placeholder token that the proxy swaps for the real one?
#
# It boots a throwaway pjsb-spike-ca VM and generates a scratch CA on the host.
# The CA's certificate (never its key) goes into the guest trust store, and
# NODE_EXTRA_CA_CERTS/SSL_CERT_FILE point at it. Then it starts mitmdump on the
# host with a small addon. For the target hosts only, the addon replaces a
# placeholder credential in the Authorization header (bearer, token or basic)
# with the real host token. Each agent then runs in the guest with only
# placeholders set. It needs a real Mac host with Lima, mitmproxy and real
# credentials, so it's run by hand (MT-5 in issues/manual-tests.md), and its
# results go into pj-sandbox/docs/spike-ca.md.
#
# Usage: spike_ca.sh [--dry-run] [--repo OWNER/NAME]
#
# Checks, each run in the guest and printed as OK or FAIL with the error text:
#   [claude]       claude -p 'say ok'
#   [claude-long]  one claude -p run that keeps going for PJ_SPIKE_CLAUDE_LONG_SECS
#                  (several Bash `sleep` turns), to catch a token refresh
#                  mid-session if the token has one
#   [copilot]      copilot -p 'say ok' (non-interactive)
#   [gh]           gh api user
#   [git]          git ls-remote https://github.com/OWNER/NAME
#
# Real tokens come from ~/.claude/sandbox-oauth-token (Claude) and
# `gh auth token` (gh, git and Copilot). They are exported only into the
# host-side mitmdump process's environment. They're never written to a file,
# put on a command line, or sent to the guest. The guest only ever sees
# placeholders.
#
# The VM, mitmdump and the scratch CA are removed at the end, even after a
# failure or Ctrl-C. Exits 0 only if every check is OK.
#
# Options:
#   --repo OWNER/NAME  the repo for [git] (default: this checkout's GitHub
#                      origin). Use a private repo: a public one answers
#                      ls-remote with no credentials at all, which proves nothing
#   --dry-run          print the Lima config, the commands, the mitmdump addon
#                      and the guest script, without calling limactl or mitmdump
#   -h, --help         show this help
#
# Environment (defaults in parentheses):
#   PJ_SPIKE_CLAUDE_PLACEHOLDER  placeholder Claude token (sk-ant-oat01-pjsb-placeholder)
#   PJ_SPIKE_GH_PLACEHOLDER      placeholder GitHub token (gho_pjsbplaceholder)
#   PJ_SPIKE_CLAUDE_HOSTS        hosts whose Claude placeholder is rewritten
#                                (api.anthropic.com console.anthropic.com
#                                claude.ai platform.claude.com)
#   PJ_SPIKE_GH_HOSTS            hosts whose GitHub placeholder is rewritten
#                                (github.com api.github.com .githubcopilot.com);
#                                a leading '.' matches any subdomain
#   PJ_SPIKE_PROXY_LISTEN        host:port mitmdump listens on (127.0.0.1:8080)
#   PJ_SPIKE_PROXY               host:port the guest uses to reach it
#                                (host.lima.internal:8080)
#   PJ_SPIKE_CLAUDE_LONG_SECS    how long [claude-long] runs for (120)
#   PJ_SPIKE_CHECK_TIMEOUT       per-check timeout in seconds (PJ_SPIKE_CLAUDE_LONG_SECS + 180)

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do SOURCE="$(readlink "$SOURCE")"; done
LIVE_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
PJ_SANDBOX_HOME="$(cd -P "$LIVE_DIR/../.." && pwd)"
PJ_SANDBOX_DOTFILES_HOME="$(cd -P "$PJ_SANDBOX_HOME/.." && pwd)"
SPIKE_LIMA_DIR="$PJ_SANDBOX_HOME/lima/spike"

# shellcheck source=../../lib/namespace.sh
. "$PJ_SANDBOX_HOME/lib/namespace.sh"

usage() {
	sed -n '2,/^$/p' "$SOURCE" | sed 's/^# \{0,1\}//'
}

die() {
	echo "spike_ca.sh: $*" >&2
	exit 1
}

repo=""
dry_run=0
while [ "$#" -gt 0 ]; do
	case "$1" in
		-h | --help)
			usage
			exit 0
			;;
		--dry-run)
			dry_run=1
			;;
		--repo)
			[ "$#" -ge 2 ] || die "--repo needs a value"
			repo="$2"
			shift
			;;
		--repo=*)
			repo="${1#--repo=}"
			;;
		*)
			die "unknown argument '$1' (see --help)"
			;;
	esac
	shift
done

if [ -z "$repo" ]; then
	origin="$(git -C "$PJ_SANDBOX_DOTFILES_HOME" remote get-url origin 2>/dev/null || true)"
	case "$origin" in
		*github.com[:/]*)
			repo="${origin#*github.com[:/]}"
			repo="${repo%.git}"
			;;
	esac
fi
[ -n "$repo" ] || die "--repo OWNER/NAME is required: this checkout has no GitHub origin to default to"
printf '%s\n' "$repo" | grep -Eqx '[A-Za-z0-9._-]+/[A-Za-z0-9._-]+' || die "--repo must be OWNER/NAME, got '$repo'"

CLAUDE_PLACEHOLDER="${PJ_SPIKE_CLAUDE_PLACEHOLDER:-sk-ant-oat01-pjsb-placeholder}"
GH_PLACEHOLDER="${PJ_SPIKE_GH_PLACEHOLDER:-gho_pjsbplaceholder}"
CLAUDE_HOSTS="${PJ_SPIKE_CLAUDE_HOSTS:-api.anthropic.com console.anthropic.com claude.ai platform.claude.com}"
GH_HOSTS="${PJ_SPIKE_GH_HOSTS:-github.com api.github.com .githubcopilot.com}"
PROXY_LISTEN="${PJ_SPIKE_PROXY_LISTEN:-127.0.0.1:8080}"
PROXY="${PJ_SPIKE_PROXY:-host.lima.internal:8080}"
LONG_SECS="${PJ_SPIKE_CLAUDE_LONG_SECS:-120}"
CHECK_TIMEOUT="${PJ_SPIKE_CHECK_TIMEOUT:-$((LONG_SECS + 180))}"
listen_host="${PROXY_LISTEN%:*}"
listen_port="${PROXY_LISTEN##*:}"

instance="${PJ_SANDBOX_INSTANCE_PREFIX}spike-ca"
config="$SPIKE_LIMA_DIR/ca.yaml"
# Where the scratch CA's certificate lands in the guest, and the bundle
# update-ca-certificates rebuilds with it included.
GUEST_CA=/usr/local/share/ca-certificates/pjsb-spike-ca.crt
GUEST_BUNDLE=/etc/ssl/certs/ca-certificates.crt

CLAUDE_TOKEN_FILE="$HOME/.claude/sandbox-oauth-token"

# addon_script
#
# The mitmdump addon. It holds no secrets: the real tokens, the placeholders
# and the target hosts all come from mitmdump's own environment.
addon_script() {
	cat <<'EOF'
"""spike_ca.sh's mitmdump addon: swap placeholder credentials for real ones,
for the target hosts only."""
import base64
import logging
import os

from mitmproxy import http

HEADERS = ("authorization", "x-api-key")

RULES = [
    (
        "claude",
        os.environ["PJ_SPIKE_CLAUDE_PLACEHOLDER"],
        os.environ.get("PJ_SPIKE_REAL_CLAUDE", ""),
        os.environ.get("PJ_SPIKE_CLAUDE_HOSTS", "").split(),
    ),
    (
        "gh",
        os.environ["PJ_SPIKE_GH_PLACEHOLDER"],
        os.environ.get("PJ_SPIKE_REAL_GH", ""),
        os.environ.get("PJ_SPIKE_GH_HOSTS", "").split(),
    ),
]


def host_matches(host, patterns):
    for pattern in patterns:
        if pattern.startswith("."):
            if host.endswith(pattern) or host == pattern[1:]:
                return True
        elif host == pattern:
            return True
    return False


def swap(value, placeholder, real):
    """VALUE with PLACEHOLDER replaced by REAL, looking inside a Basic
    credential too. VALUE unchanged if the placeholder isn't in it."""
    if placeholder in value:
        return value.replace(placeholder, real)
    scheme, _, cred = value.partition(" ")
    if scheme.lower() != "basic" or not cred:
        return value
    try:
        decoded = base64.b64decode(cred).decode()
    except ValueError:
        return value
    if placeholder not in decoded:
        return value
    return scheme + " " + base64.b64encode(decoded.replace(placeholder, real).encode()).decode()


def request(flow: http.HTTPFlow) -> None:
    host = flow.request.pretty_host
    for header in HEADERS:
        value = flow.request.headers.get(header)
        if value is None:
            continue
        for name, placeholder, real, hosts in RULES:
            if swap(value, placeholder, "X") == value:
                continue
            if not host_matches(host, hosts):
                logging.warning("pjsb-spike: %s placeholder sent to non-target host %s, left alone", name, host)
            elif not real:
                logging.warning("pjsb-spike: %s placeholder for %s, but no real token on the host", name, host)
            else:
                flow.request.headers[header] = swap(value, placeholder, real)
                logging.info("pjsb-spike: rewrote %s placeholder in %s for %s", name, header, host)
            break
EOF
}

# guest_script
#
# Runs as the guest user with bash, after the CA is trusted. Only placeholders
# are set. Prints one OK/FAIL line per check, with the error text after a FAIL,
# and exits 1 if any check fails.
guest_script() {
	cat <<EOF
set -u
export HTTPS_PROXY=http://$PROXY HTTP_PROXY=http://$PROXY
export https_proxy=http://$PROXY http_proxy=http://$PROXY
export NO_PROXY=localhost,127.0.0.1 no_proxy=localhost,127.0.0.1
export NODE_EXTRA_CA_CERTS=$GUEST_CA
export SSL_CERT_FILE=$GUEST_BUNDLE
export CLAUDE_CODE_OAUTH_TOKEN=$CLAUDE_PLACEHOLDER
export GH_TOKEN=$GH_PLACEHOLDER GITHUB_TOKEN=$GH_PLACEHOLDER COPILOT_GITHUB_TOKEN=$GH_PLACEHOLDER
CHECK_TIMEOUT=$CHECK_TIMEOUT
LONG_STEP=$(((LONG_SECS + 3) / 4))
EOF
	cat <<'EOF'
# git asks this helper for credentials after github.com's 401, and so sends the
# placeholder as a Basic credential, as `gh auth setup-git` would.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=credential.https://github.com.helper
export GIT_CONFIG_VALUE_0='!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f'
export GIT_TERMINAL_PROMPT=0

fails=0

# check LABEL CMD...: OK if CMD exits 0, else FAIL plus the tail of its output.
check() {
	label="$1"
	shift
	if out="$(timeout "$CHECK_TIMEOUT" "$@" 2>&1 </dev/null)"; then
		echo "OK [$label] $*"
	else
		echo "FAIL [$label] (exit $?) $*"
		printf '%s\n' "$out" | tail -n 20 | sed 's/^/    /'
		fails=1
	fi
}

# [claude] one short request
check claude claude -p 'say ok'
# [claude-long] one session lasting about 4 x LONG_STEP seconds, so a token
# refresh partway through, if the token has one, goes through the proxy too
check claude-long claude -p "Use the Bash tool to run \`sleep $LONG_STEP\` four times, one after another, then reply ok." --allowedTools Bash
# [copilot] non-interactive
check copilot copilot -p 'say ok'
# [gh]
check gh gh api user
EOF
	cat <<EOF
# [git]
check git git ls-remote https://github.com/$repo

exit "\$fails"
EOF
}

# The commands that make the scratch CA, in CA_DIR. mitmproxy wants key and
# certificate together in mitmproxy-ca.pem; only ca.crt goes to the guest.
make_ca() {
	run_or_print openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
		-subj "/CN=pjsb spike_ca.sh scratch CA" \
		-addext "basicConstraints=critical,CA:TRUE" \
		-addext "keyUsage=critical,keyCertSign,cRLSign" \
		-keyout "$1/ca.key" -out "$1/ca.crt"
	if [ "$DRY_RUN" -eq 1 ]; then
		echo "cat $1/ca.key $1/ca.crt > $1/mitmproxy-ca.pem"
	else
		cat "$1/ca.key" "$1/ca.crt" > "$1/mitmproxy-ca.pem"
	fi
}

# Each of these runs the command, or with DRY_RUN=1 prints it instead.
DRY_RUN="$dry_run"
run_or_print() {
	if [ "$DRY_RUN" -eq 1 ]; then
		echo "$*"
	else
		"$@" >/dev/null 2>&1
	fi
}

MITMDUMP_CMD="mitmdump --set confdir=CA_DIR --listen-host $listen_host --listen-port $listen_port -s CA_DIR/addon.py"
TRUST_CMD="limactl shell $instance sudo sh -c 'cat > $GUEST_CA && update-ca-certificates' < CA_DIR/ca.crt"

# token_status LABEL VALUE: whether a real token was found. Never the token.
token_status() {
	if [ -n "$2" ]; then
		echo "$1: found (handed only to mitmdump)"
	else
		echo "$1: NOT FOUND -- checks that need it will fail"
	fi
}

real_claude=""
[ ! -r "$CLAUDE_TOKEN_FILE" ] || real_claude="$(tr -d '[:space:]' < "$CLAUDE_TOKEN_FILE")"
real_gh="$(gh auth token 2>/dev/null || true)"

if [ "$dry_run" -eq 1 ]; then
	echo "== Lima config: $config =="
	cat "$config"
	echo
	echo "== Real tokens (host only) =="
	token_status "Claude ($CLAUDE_TOKEN_FILE)" "$real_claude"
	token_status "GitHub (gh auth token)" "$real_gh"
	echo
	echo "== Scratch CA (in a mktemp -d, CA_DIR) =="
	make_ca CA_DIR
	echo
	echo "== mitmdump addon (CA_DIR/addon.py) =="
	addon_script
	echo
	echo "== Proxy (host; the real tokens are exported into this process only) =="
	echo "$MITMDUMP_CMD"
	echo
	echo "== Boot =="
	run_or_print limactl start --tty=false --name="$instance" "$config"
	echo
	echo "== Trust the CA in the guest =="
	echo "$TRUST_CMD"
	echo
	echo "== Checks (limactl shell $instance bash -s) =="
	guest_script
	echo
	echo "== Teardown (always, even after a failure) =="
	echo "kill <mitmdump pid>"
	echo "limactl delete --force $instance"
	echo "rm -rf CA_DIR"
	exit 0
fi

# --- live run ---

command -v limactl >/dev/null 2>&1 || die "limactl not found"
command -v mitmdump >/dev/null 2>&1 || die "mitmdump not found (uv tool install mitmproxy)"
command -v openssl >/dev/null 2>&1 || die "openssl not found"

if limactl list --quiet 2>/dev/null | grep -qx "$instance"; then
	die "$instance already exists; delete it first (limactl delete --force $instance)"
fi

token_status "Claude ($CLAUDE_TOKEN_FILE)" "$real_claude"
token_status "GitHub (gh auth token)" "$real_gh"

ca_dir=""
mitm_pid=""
started=0
teardown() {
	status=$?
	trap - EXIT INT TERM
	if [ -n "$mitm_pid" ]; then
		kill "$mitm_pid" 2>/dev/null || true
		wait "$mitm_pid" 2>/dev/null || true
		echo "== mitmdump log =="
		cat "$ca_dir/mitmdump.log" 2>/dev/null || true
	fi
	if [ "$started" -eq 1 ]; then
		limactl delete --force "$instance" || echo "spike_ca.sh: failed to delete $instance" >&2
	fi
	[ -z "$ca_dir" ] || rm -rf "$ca_dir"
	exit "$status"
}
trap teardown EXIT
trap 'exit 130' INT TERM

ca_dir="$(mktemp -d "${TMPDIR:-/tmp}/pjsb-spike-ca.XXXXXX")"
make_ca "$ca_dir" || die "couldn't make the scratch CA"
addon_script > "$ca_dir/addon.py"

# The real tokens are exported only inside this subshell, which then becomes
# mitmdump: they reach its environment, never argv or a file.
(
	export PJ_SPIKE_REAL_CLAUDE="$real_claude"
	export PJ_SPIKE_REAL_GH="$real_gh"
	export PJ_SPIKE_CLAUDE_PLACEHOLDER="$CLAUDE_PLACEHOLDER" PJ_SPIKE_GH_PLACEHOLDER="$GH_PLACEHOLDER"
	export PJ_SPIKE_CLAUDE_HOSTS="$CLAUDE_HOSTS" PJ_SPIKE_GH_HOSTS="$GH_HOSTS"
	exec mitmdump --set confdir="$ca_dir" --listen-host "$listen_host" --listen-port "$listen_port" -s "$ca_dir/addon.py"
) > "$ca_dir/mitmdump.log" 2>&1 &
mitm_pid=$!
unset real_claude real_gh

tries=0
until nc -z "$listen_host" "$listen_port" >/dev/null 2>&1; do
	kill -0 "$mitm_pid" 2>/dev/null || die "mitmdump exited early: $(cat "$ca_dir/mitmdump.log")"
	tries=$((tries + 1))
	[ "$tries" -lt 30 ] || die "mitmdump isn't listening on $PROXY_LISTEN after 30s"
	sleep 1
done

started=1
limactl start --tty=false --name="$instance" "$config"

limactl shell "$instance" sudo sh -c "cat > $GUEST_CA && update-ca-certificates" < "$ca_dir/ca.crt" >/dev/null

echo "== Checks (in $instance, placeholders only) =="
rc=0
guest_script | limactl shell "$instance" bash -s || rc=1
exit "$rc"
