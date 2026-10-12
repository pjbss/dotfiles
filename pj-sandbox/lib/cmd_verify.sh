# cmd_verify.sh
#
# pj-sandbox verify <task>
#
# Checks from the host that a running sandbox holds its security properties,
# printing one PASS, FAIL or SKIP line per check, then a tally. Any FAIL
# makes it exit 1. SKIP means the check couldn't be made or doesn't apply,
# such as an unbrokered profile, whose real token is in the guest by design.
#
#   mounts         `limactl list --json <instance>` shows no mounts
#   no-tokens      no brokered token is in the guest session's env, any
#                  /proc/*/environ, /etc/environment, /etc/profile.d, or
#                  any file under $HOME (login files, and the config and
#                  credential files agents keep in dot-directories) or
#                  /workspace. The guest only ever sees a salted fingerprint
#                  of each (lib/verify_scan.py), never the token.
#   egress-denied  the task is in deny mode, and a guest curl to a fresh
#                  *.invalid host fails with a denial in the proxy's log
#   ca-trusted     a guest curl to an allowlisted host succeeds, and the
#                  proxy logged it, so the guest trusts the proxy's CA
#   marker         /etc/pj-sandbox exists
#
# Each guest check is a script sent to `pj-sandbox exec <task> -- sh -s`
# over stdin. Its first line is always `root=`: the guest's filesystem root,
# which tests point at a fake one.

. "$PJ_SANDBOX_HOME/lib/cmd_exec.sh"
. "$PJ_SANDBOX_HOME/lib/tokens.sh"

# _pj_sandbox_verify_report STATUS CHECK REASON
_pj_sandbox_verify_report() {
	printf '%-4s  %s: %s\n' "$1" "$2" "$3"
	case "$1" in
		PASS) _pjsv_passed=$((_pjsv_passed + 1)) ;;
		FAIL) _pjsv_failed=$((_pjsv_failed + 1)) ;;
		SKIP) _pjsv_skipped=$((_pjsv_skipped + 1)) ;;
	esac
}

# _pj_sandbox_verify_guest TASK BODY [ARG...]
#
# Runs BODY, after a `root=` line, as `sh -s ARG...` in TASK's guest, and
# exits with its status (255 when ssh couldn't reach the guest).
_pj_sandbox_verify_guest() (
	_pjsvg_task="$1" _pjsvg_body="$2"
	shift 2
	printf 'root=\n%s\n' "$_pjsvg_body" | cmd_exec "$_pjsvg_task" -- sh -s "$@"
)

_pj_sandbox_verify_mounts() {
	if ! json="$(limactl list --json "$instance" 2>/dev/null)"; then
		_pj_sandbox_verify_report FAIL mounts "'limactl list --json $instance' failed"
		return
	fi
	if ! mounts="$(printf '%s\n' "$json" | python3 -c '
import json, sys
for line in sys.stdin:
    if line.strip():
        vm = json.loads(line)
        for m in (vm.get("config") or {}).get("mounts") or []:
            print("%s -> %s" % (m.get("location", "?"), m.get("mountPoint") or m.get("location", "?")))
')"; then
		_pj_sandbox_verify_report FAIL mounts "couldn't read Lima's JSON for $instance"
	elif [ -n "$mounts" ]; then
		_pj_sandbox_verify_report FAIL mounts "host mounts: $(printf '%s\n' "$mounts" | paste -sd ',' - | sed 's/,/, /g')"
	else
		_pj_sandbox_verify_report PASS mounts "no host mounts"
	fi
}

# The guest half of no-tokens. Its args are SALT LABEL=FP..., and it runs
# after a heredoc that puts the scanner, lib/verify_scan.py, in $prog.
_PJ_SANDBOX_VERIFY_SCAN_SH='run=""
if sudo -n true 2>/dev/null; then run="sudo -n"; fi
set -- scan "$@" -- "$root"/proc/[0-9]*/environ \
	"$root/etc/environment" "$root/etc/profile.d" "$root$HOME" "$root/workspace"
env | $run python3 -c "$prog" "$@"'

_pj_sandbox_verify_tokens() {
	for pair in $(printf '%s\n' "$creds" | tr ',' ' '); do
		case "${pair#*:}" in
			unbrokered)
				_pj_sandbox_verify_report SKIP no-tokens \
					"${pair%%:*} is unbrokered: its real token is in the guest by design"
				;;
		esac
	done

	if ! pairs="$(python3 "$PJ_SANDBOX_HOME/proxy/inject.py" sources "$PJ_SANDBOX_STATE_DIR/$task/policy" </dev/null)"; then
		_pj_sandbox_verify_report FAIL no-tokens "couldn't read the task's policy/inject.json"
		return
	fi
	salt="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
	fps=""
	for name in $(printf '%s\n' "$pairs" | cut -f1 | awk 'NF && !seen[$0]++'); do
		label="$(printf '%s\n' "$name" | sed 's/^PJSB_TOKEN_PJSB_PLACEHOLDER_//; s/^PJSB_TOKEN_//' | tr '[:upper:]_' '[:lower:]-')"
		sources="$(printf '%s\n' "$pairs" | awk -F '\t' -v n="$name" '$1 == n { print $2 }')"
		# The token only ever passes through this pipe, never a variable.
		fp="$(
			IFS='
'
			set -f
			# shellcheck disable=SC2086 # split on newlines only, one source per line
			pj_sandbox_token_resolve $sources 2>/dev/null |
				python3 "$PJ_SANDBOX_HOME/lib/verify_scan.py" fingerprint "$salt"
		)"
		if [ -z "$fp" ]; then
			_pj_sandbox_verify_report SKIP no-tokens "$label: no token on the host (or too short to fingerprint), so nothing to look for"
		else
			fps="$fps $label=$fp"
		fi
	done
	if [ -z "$fps" ]; then
		_pj_sandbox_verify_report SKIP no-tokens "no brokered token to look for"
		return
	fi

	body="prog=\$(cat <<'PJSB_VERIFY_PY'
$(cat "$PJ_SANDBOX_HOME/lib/verify_scan.py")
PJSB_VERIFY_PY
)
$_PJ_SANDBOX_VERIFY_SCAN_SH"
	# shellcheck disable=SC2086 # one LABEL=FP per word
	out="$(_pj_sandbox_verify_guest "$task" "$body" "$salt" $fps)" || out=""
	scanned="$(printf '%s\n' "$out" | awk -F '\t' '$1 == "scanned" { print $2 }')"
	found="$(printf '%s\n' "$out" | awk -F '\t' '$1 == "hit" { print $2 " in " $3 }')"
	if [ -z "$scanned" ]; then
		_pj_sandbox_verify_report FAIL no-tokens "the guest-side scan didn't run (needs python3 in the guest)"
	elif [ -n "$found" ]; then
		_pj_sandbox_verify_report FAIL no-tokens "real token found: $(printf '%s\n' "$found" | paste -sd ',' - | sed 's/,/, /g')"
	else
		_pj_sandbox_verify_report PASS no-tokens "no brokered token in the session env or $scanned files (process environments, /etc/environment, /etc/profile.d, \$HOME, /workspace)"
	fi
}

_PJ_SANDBOX_VERIFY_CURL_SH='curl -sS -o /dev/null --max-time 20 "$1"'

# _pj_sandbox_verify_log_size
#
# Prints the task's egress.log size in bytes (0 if there's none yet), taken
# before a probe so _pj_sandbox_verify_logged only reads what came after.
_pj_sandbox_verify_log_size() {
	if [ -f "$PJ_SANDBOX_STATE_DIR/$task/egress.log" ]; then
		wc -c < "$PJ_SANDBOX_STATE_DIR/$task/egress.log" | tr -d ' '
	else
		echo 0
	fi
}

# _pj_sandbox_verify_logged OFFSET HOST DECISION...
#
# True if the task's egress.log, past byte OFFSET, has an entry for HOST
# with one of the DECISIONs. Tries for about two seconds, so a proxy that
# hasn't flushed yet isn't mistaken for one that never saw the request.
_pj_sandbox_verify_logged() {
	log="$PJ_SANDBOX_STATE_DIR/$task/egress.log"
	tries=0
	while :; do
		if [ -f "$log" ] && python3 -c '
import json, sys
with open(sys.argv[1], "rb") as f:
    f.seek(int(sys.argv[2]))
    for line in f:
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if e.get("host") == sys.argv[3] and e.get("decision") in sys.argv[4:]:
            sys.exit(0)
sys.exit(1)
' "$log" "$@"; then
			return 0
		fi
		[ "$tries" -lt 10 ] || return 1
		sleep 0.2
		tries=$((tries + 1))
	done
}

_pj_sandbox_verify_egress() {
	mode="$(pj_sandbox_state_get "$task" egress_mode)"
	if [ "$mode" != deny ]; then
		_pj_sandbox_verify_report FAIL egress-denied "egress mode is '${mode:-unset}'; only deny mode denies egress"
		return
	fi
	probe="pjsb-verify-$(od -An -tx1 -N6 /dev/urandom | tr -d ' \n').invalid"
	offset="$(_pj_sandbox_verify_log_size)"
	if _pj_sandbox_verify_guest "$task" "$_PJ_SANDBOX_VERIFY_CURL_SH" "https://$probe/" >/dev/null 2>&1; then
		_pj_sandbox_verify_report FAIL egress-denied "the guest reached https://$probe/, which no allowlist names"
	elif _pj_sandbox_verify_logged "$offset" "$probe" deny; then
		_pj_sandbox_verify_report PASS egress-denied "the proxy denied https://$probe/"
	else
		_pj_sandbox_verify_report FAIL egress-denied "the guest's request to https://$probe/ failed, but the proxy log has no denial for it, so it may not have gone through the proxy"
	fi
}

# _pj_sandbox_verify_ca_url ALLOWLIST
#
# Prints an https URL for the first entry of ALLOWLIST that names one exact
# host and lets GET through, at its path prefix if it has one.
_pj_sandbox_verify_ca_url() {
	[ -f "$1" ] || return 0
	sed 's/[[:space:]]*#.*$//' "$1" | awk '
		NF == 0 || $1 ~ /^\*/ { next }
		{
			path = "/"; ok = 1
			for (i = 2; i <= NF; i++) {
				if (substr($i, 1, 1) == "/") path = $i
				else if (("," toupper($i) ",") !~ /,GET,/) ok = 0
			}
			if (ok) { print "https://" tolower($1) path; exit }
		}
	'
}

_pj_sandbox_verify_ca() {
	url="$(_pj_sandbox_verify_ca_url "$PJ_SANDBOX_STATE_DIR/$task/policy/allowlist")"
	if [ -z "$url" ]; then
		_pj_sandbox_verify_report SKIP ca-trusted "the allowlist has no exact host GET may reach"
		return
	fi
	offset="$(_pj_sandbox_verify_log_size)"
	if _pj_sandbox_verify_guest "$task" "$_PJ_SANDBOX_VERIFY_CURL_SH" "$url" >/dev/null 2>&1; then
		rc=0
	else
		rc=$?
	fi
	# A guest that got around the proxy would see the real certificate, so
	# success only shows the CA is trusted if the proxy saw the request.
	host="${url#https://}"
	host="${host%%/*}"
	case "$rc" in
		0)
			if _pj_sandbox_verify_logged "$offset" "$host" allow inject; then
				_pj_sandbox_verify_report PASS ca-trusted "the guest reached $url through the proxy"
			else
				_pj_sandbox_verify_report FAIL ca-trusted "the guest reached $url, but the proxy log has no entry for it, so it went around the proxy"
			fi
			;;
		60 | 35 | 77) _pj_sandbox_verify_report FAIL ca-trusted "TLS to $url failed (curl exit $rc): the guest doesn't trust the proxy's CA" ;;
		255) _pj_sandbox_verify_report FAIL ca-trusted "couldn't reach the guest over ssh" ;;
		*) _pj_sandbox_verify_report FAIL ca-trusted "the guest couldn't reach $url (curl exit $rc)" ;;
	esac
}

_pj_sandbox_verify_marker() {
	if _pj_sandbox_verify_guest "$task" 'test -e "$root/etc/pj-sandbox"' >/dev/null 2>&1; then
		rc=0
	else
		rc=$?
	fi
	case "$rc" in
		0) _pj_sandbox_verify_report PASS marker "/etc/pj-sandbox exists" ;;
		255) _pj_sandbox_verify_report FAIL marker "couldn't reach the guest over ssh" ;;
		*) _pj_sandbox_verify_report FAIL marker "/etc/pj-sandbox is missing" ;;
	esac
}

cmd_verify() {
	if [ "$#" -ne 1 ] || [ -z "$1" ]; then
		echo "Usage: pj-sandbox verify <task>" >&2
		return 1
	fi
	task="$1"
	instance="$(pj_sandbox_running_instance verify "$task")" || return 1
	creds="$(pj_sandbox_state_get "$task" creds)"

	_pjsv_passed=0 _pjsv_failed=0 _pjsv_skipped=0
	_pj_sandbox_verify_mounts
	_pj_sandbox_verify_tokens
	_pj_sandbox_verify_egress
	_pj_sandbox_verify_ca
	_pj_sandbox_verify_marker

	echo "verify: $_pjsv_passed passed, $_pjsv_failed failed, $_pjsv_skipped skipped"
	[ "$_pjsv_failed" -eq 0 ]
}
