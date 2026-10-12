# proxy.sh
#
# The task's egress proxy: one host mitmdump per task, loading
# proxy/addon.py, listening on the host-only network that is the guest's only
# route (pj-sandbox/docs/spike-egress.md, "Findings"). spawn starts it, rm and
# gc stop it, and its PID and port live in the task's state record. Meant to
# be sourced after namespace.sh, state.sh and tokens.sh, not executed.

# pj_sandbox_proxy_valid_host HOST
#
# True unless HOST is empty or a wildcard: the proxy listens on one address,
# so it's never reachable from the LAN.
pj_sandbox_proxy_valid_host() {
	case "$1" in
		"" | 0.0.0.0 | :: | "[::]" | "*")
			echo "pj-sandbox: refusing to start the proxy on '$1': it must listen on one address, never all of them" >&2
			return 1
			;;
	esac
}

# pj_sandbox_proxy_start TASK_DIR MODE HOST PORT CONFIG_DIR
#
# Starts mitmdump for the task whose state dir is TASK_DIR, in egress MODE,
# listening on HOST:PORT, signing with CONFIG_DIR/ca, and prints its PID.
# The addon reads TASK_DIR/policy and appends to TASK_DIR/egress.log;
# mitmdump's own output goes to TASK_DIR/proxy.log. Real tokens reach it only
# through its environment (pj_sandbox_tokens_exec). A wildcard HOST is
# refused (pj_sandbox_proxy_valid_host). Fails, with the tail of proxy.log,
# if mitmdump has exited PJ_SANDBOX_PROXY_SETTLE seconds (default 1) after
# starting.
#
# pj_sandbox_tokens_exec runs in its own subshell, so the background job's
# PID isn't mitmdump's. The `sh -c` it execs writes its own PID, then execs
# mitmdump in place, so the pidfile holds exactly mitmdump's.
pj_sandbox_proxy_start() {
	task_dir="$1"
	mode="$2"
	host="$3"
	port="$4"
	pj_sandbox_proxy_valid_host "$host" || return 1

	pidfile="$task_dir/proxy.pid"
	rm -f "$pidfile"
	(
		pj_sandbox_tokens_exec "$task_dir/policy" \
			sh -c 'echo "$$" > "$0" && exec "$@"' "$pidfile" \
			mitmdump -s "$PJ_SANDBOX_HOME/proxy/addon.py" \
			--listen-host "$host" --listen-port "$port" \
			--set "confdir=$5/ca" \
			--set "pjsb_policy_dir=$task_dir/policy" \
			--set "pjsb_mode=$mode"
	) < /dev/null >> "$task_dir/proxy.log" 2>&1 &
	job=$!

	pid=""
	tries=0
	while [ "$tries" -lt 50 ]; do
		pid="$(cat "$pidfile" 2>/dev/null)" || pid=""
		[ -z "$pid" ] || break
		# Gone before writing a PID: the token step failed.
		kill -0 "$job" 2>/dev/null || break
		sleep 0.1
		tries=$((tries + 1))
	done
	rm -f "$pidfile"
	if [ -n "$pid" ]; then
		sleep "${PJ_SANDBOX_PROXY_SETTLE:-1}"
		if kill -0 "$pid" 2>/dev/null; then
			echo "$pid"
			return 0
		fi
	fi
	echo "pj-sandbox: the egress proxy didn't start; from $task_dir/proxy.log:" >&2
	tail -n 5 "$task_dir/proxy.log" >&2 2>/dev/null
	return 1
}

# pj_sandbox_proxy_kill PID POLICY_DIR
#
# Stops PID, but only while it's still the mitmdump serving POLICY_DIR: a PID
# the OS has since handed to something else is left alone. Gone already is
# success. Waits up to 5 seconds for it to exit, then sends KILL.
pj_sandbox_proxy_kill() {
	[ -n "$1" ] || return 0
	command="$(ps -p "$1" -o command= 2>/dev/null)" || return 0
	case "$command" in
		*"pjsb_policy_dir=$2 "* | *"pjsb_policy_dir=$2") ;;
		*) return 0 ;;
	esac
	kill "$1" 2>/dev/null || return 0
	tries=0
	while kill -0 "$1" 2>/dev/null; do
		if [ "$tries" -ge 50 ]; then
			kill -9 "$1" 2>/dev/null || true
			break
		fi
		sleep 0.1
		tries=$((tries + 1))
	done
}

# pj_sandbox_proxy_stop TASK
#
# Stops the proxy TASK's record names, if it's still running.
pj_sandbox_proxy_stop() {
	pj_sandbox_proxy_kill "$(pj_sandbox_state_get "$1" proxy_pid)" "$PJ_SANDBOX_STATE_DIR/$1/policy"
}
