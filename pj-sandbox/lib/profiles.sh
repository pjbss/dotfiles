# profiles.sh
#
# Agent profiles, selected with `pj-sandbox spawn --agent`. Each is a
# directory under pj-sandbox/profiles/ holding:
#
#   provision.sh       run as root at provision time
#   allowlist          one host pattern per line, optionally followed by
#                      methods and a path prefix; # comments allowed
#   inject.json        a JSON array of {host, header, scheme, placeholder,
#                      token_source} rules, token_source being a list of
#                      host-side sources tried in order (lib/tokens.sh)
#   guest-env          KEY=value lines the guest gets: token placeholders and
#                      the CA paths its tools need to trust the proxy
#   post-bootstrap.sh  optional; run as the guest user after the bootstrap
#   unbrokered         optional, empty; marks an agent the proxy can't broker
#                      for (pj-sandbox/docs/spike-ca.md), so its real token is
#                      put in the guest instead of a placeholder
#
# The core only reads these files. It never names an agent, so adding or
# dropping one is a new directory, not a code change. Meant to be sourced,
# not executed.

# pj_sandbox_profile_names PROFILES_DIR
#
# Prints every profile name, one per line, sorted. A missing PROFILES_DIR has
# none.
pj_sandbox_profile_names() {
	for dir in "$1"/*/; do
		[ -d "$dir" ] || continue
		basename "$dir"
	done
}

# pj_sandbox_profile_names_block PROFILES_DIR
#
# The "Available --agent names:" block an --agent error shows.
pj_sandbox_profile_names_block() {
	printf '%sAvailable --agent names:%s\n' "${C_CYAN:-}" "${C_RESET:-}"
	pj_sandbox_profile_names "$1" | sed 's/^/  /'
}

# pj_sandbox_profiles_resolve PROFILES_DIR CSV
#
# Prints CSV's profile names one per line, in CSV order with repeats dropped.
# An empty item, or a name with no directory under PROFILES_DIR, fails with
# the valid names on stderr.
# A subshell, so the noglob the split needs never leaks to the caller.
pj_sandbox_profiles_resolve() (
	case "$2" in
		"" | ,* | *, | *,,*)
			echo "pj-sandbox: --agent takes comma-separated profile names, got '$2'" >&2
			pj_sandbox_profile_names_block "$1" >&2
			exit 1
			;;
	esac
	set -f
	selected=""
	for name in $(printf '%s\n' "$2" | tr ',' ' '); do
		case "$name" in
			.* | */*) found=no ;;
			*) [ -d "$1/$name" ] && found=yes || found=no ;;
		esac
		if [ "$found" = no ]; then
			set +f
			echo "pj-sandbox: unknown agent profile '$name'" >&2
			pj_sandbox_profile_names_block "$1" >&2
			exit 1
		fi
		case " $selected " in
			*" $name "*) ;;
			*) selected="$selected $name" ;;
		esac
	done
	printf '%s\n' $selected
)

# pj_sandbox_profiles_provision_yaml PROFILES_DIR NAMES
#
# NAMES is one profile per line. Prints one Lima `mode: system` provision item
# per profile, whose script is that profile's provision.sh. Fails if one has
# no provision.sh.
pj_sandbox_profiles_provision_yaml() {
	printf '%s\n' "$2" | while IFS= read -r name; do
		[ -n "$name" ] || continue
		if [ ! -f "$1/$name/provision.sh" ]; then
			echo "pj-sandbox: agent profile '$name' has no provision.sh" >&2
			return 1
		fi
		echo "- mode: system"
		echo "  script: |"
		sed 's/^/    /' "$1/$name/provision.sh" || return 1
	done
}

# _pj_sandbox_json_array_body FILE
#
# Prints what's between a JSON array file's outer brackets, trimmed, or
# fails if FILE isn't bracketed that way. Joining these bodies with commas is
# a valid merge of the arrays, whatever their elements hold.
_pj_sandbox_json_array_body() {
	awk '
		{ buf = buf $0 "\n" }
		END {
			s = buf
			sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s)
			if (substr(s, 1, 1) != "[" || substr(s, length(s), 1) != "]") exit 1
			s = substr(s, 2, length(s) - 2)
			sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s)
			printf "%s", s
		}
	' "$1"
}

# pj_sandbox_profile_creds PROFILES_DIR NAME NO_CREDS
#
# Prints profile NAME's credential state: `none` when NO_CREDS is yes or its
# inject.json has no rules, `unbrokered` when it has an `unbrokered` file, and
# `brokered` otherwise.
pj_sandbox_profile_creds() {
	if [ "$3" = yes ] || [ ! -f "$1/$2/inject.json" ] ||
		[ -z "$(_pj_sandbox_json_array_body "$1/$2/inject.json" 2>/dev/null)" ]; then
		echo none
	elif [ -e "$1/$2/unbrokered" ]; then
		echo unbrokered
	else
		echo brokered
	fi
}

# pj_sandbox_profiles_creds PROFILES_DIR NAMES NO_CREDS
#
# Prints NAME:STATE for each of NAMES (pj_sandbox_profile_creds), comma
# separated, for the state record's `creds` field.
pj_sandbox_profiles_creds() {
	for name in $2; do
		printf '%s:%s\n' "$name" "$(pj_sandbox_profile_creds "$1" "$name" "$3")"
	done | paste -sd , -
}

# pj_sandbox_profiles_guest_env PROFILES_DIR NAMES NO_CREDS
#
# Prints the KEY=value lines the guest gets from the selected profiles'
# guest-env files, in NAMES order, comments, blank lines and repeats dropped.
# A value that's a placeholder depends on its profile's credential state
# (pj_sandbox_profile_creds): a brokered profile's is kept, a profile with
# none has it dropped, and an unbrokered profile's is replaced by its real
# token, resolved from that profile's own inject.json sources. The output can
# then hold a real token, so it's meant for a variable, never a file.
# A subshell, so no token is left in a caller's variables.
pj_sandbox_profiles_guest_env() (
	for name in $2; do
		[ -f "$1/$name/guest-env" ] || continue
		creds="$(pj_sandbox_profile_creds "$1" "$name" "$3")"
		sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//' "$1/$name/guest-env" | grep -v '^$' |
			while IFS= read -r line; do
				case "${line#*=}" in
					pjsb-placeholder-*) ;;
					*)
						printf '%s\n' "$line"
						continue
						;;
				esac
				case "$creds" in
					brokered) printf '%s\n' "$line" ;;
					unbrokered)
						placeholder="${line#*=}"
						env_name="PJSB_TOKEN_$(printf '%s' "$placeholder" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_')"
						sources="$(python3 "$PJ_SANDBOX_HOME/proxy/inject.py" sources "$1/$name" </dev/null |
							awk -F '\t' -v n="$env_name" '$1 == n { print $2 }')" || exit 1
						IFS='
'
						set -f
						# shellcheck disable=SC2086 # split on newlines only, one source per line
						token="$(pj_sandbox_token_resolve $sources </dev/null)"
						set +f
						unset IFS
						printf '%s=%s\n' "${line%%=*}" "$token"
						;;
				esac
			done
	done | awk '!seen[$0]++'
)

# pj_sandbox_profiles_write_policy PROFILES_DIR NAMES INJECT_NAMES POLICY_DIR [ALLOWLIST...]
#
# Writes the selected profiles' merged policy for the proxy into POLICY_DIR:
# `allowlist` holds every entry of NAMES' profiles in order, then each extra
# ALLOWLIST file's (a template's or repo's; one that doesn't exist is
# skipped), comments, blank lines and repeats dropped; `inject.json` holds
# every rule of INJECT_NAMES' profiles in order, as one JSON array. Spawn
# passes only the brokered profiles as INJECT_NAMES, so the proxy never holds
# a token the guest has, or one --no-creds withheld.
pj_sandbox_profiles_write_policy() {
	profiles_dir="$1" names="$2" inject_names="$3" policy_dir="$4"
	shift 4
	mkdir -p "$policy_dir" || return 1

	# Trailing comments go too, so `host  # 3 requests` from `allowlist
	# suggest` dedupes against a bare `host`.
	{
		printf '%s\n' "$names" | while IFS= read -r name; do
			[ -z "$name" ] || [ ! -f "$profiles_dir/$name/allowlist" ] || cat "$profiles_dir/$name/allowlist"
		done
		for extra in "$@"; do
			[ ! -f "$extra" ] || cat "$extra"
		done
	} | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//' | grep -v '^$' | awk '!seen[$0]++' > "$policy_dir/allowlist"

	bodies=""
	for name in $inject_names; do
		[ -f "$profiles_dir/$name/inject.json" ] || continue
		if ! body="$(_pj_sandbox_json_array_body "$profiles_dir/$name/inject.json")"; then
			echo "pj-sandbox: agent profile '$name' has an inject.json that isn't a JSON array" >&2
			return 1
		fi
		[ -n "$body" ] || continue
		if [ -n "$bodies" ]; then
			bodies="$bodies,
$body"
		else
			bodies="$body"
		fi
	done
	printf '[\n%s\n]\n' "$bodies" > "$policy_dir/inject.json"
}

# pj_sandbox_profiles_post_bootstrap PROFILES_DIR NAMES INSTANCE SSH_CONFIG
#
# Pipes each selected profile's post-bootstrap.sh, in NAMES order, to
# `sh -s` in the guest over `ssh -F SSH_CONFIG INSTANCE`. Stops at the first
# that fails.
pj_sandbox_profiles_post_bootstrap() {
	for name in $2; do
		[ -f "$1/$name/post-bootstrap.sh" ] || continue
		if ! ssh -F "$4" "$3" 'sh -s' < "$1/$name/post-bootstrap.sh"; then
			echo "pj-sandbox: agent profile '$name': post-bootstrap.sh failed in $3" >&2
			return 1
		fi
	done
}
