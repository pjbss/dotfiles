# ports.sh
#
# Host port allocation for a task's ssh port and --ports forwards, all from
# PJ_SANDBOX_PORT_MIN..PJ_SANDBOX_PORT_MAX. Ported from sandbox_allocate_port
# and sandbox_allocate_ports in sandbox/lib/task.sh, with two differences:
# ports in use are read from pjsb- state records rather than `limactl list`
# (so a stopped task keeps its ports, and the old sandbox's VMs are never
# consulted), and forwards scan the pj-sandbox range rather than upward from
# each guest port's own number. Meant to be sourced after namespace.sh and
# state.sh, not executed.

# pj_sandbox_used_ports
#
# Prints every host port a state record holds, one per line: each record's
# ssh_port plus the host side of each guest:host pair in its ports field.
# A subshell, so its loop variable can't clobber a caller's (spawn's own
# $task among them); task names are read a line at a time since they may
# hold spaces.
pj_sandbox_used_ports() (
	pj_sandbox_state_tasks | while IFS= read -r task; do
		pj_sandbox_state_get "$task" ssh_port
		pj_sandbox_state_get "$task" ports | tr ',' '\n' | sed -n 's/^[0-9]*://p'
	done | grep -E '^[0-9]+$' || true
)

# pj_sandbox_host_port_free PORT
#
# True if PORT can be bound on 127.0.0.1 right now: a record can't know about
# a port some unrelated host process holds. Its own function so tests can
# shadow it rather than probing real sockets.
pj_sandbox_host_port_free() {
	python3 -c '
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    s.close()
' "$1" 2>/dev/null
}

# _pj_sandbox_next_port TAKEN
#
# Prints the first port in the range that isn't in TAKEN (one port per line)
# and is free to bind, or fails if there's none.
_pj_sandbox_next_port() {
	port="$PJ_SANDBOX_PORT_MIN"
	while [ "$port" -le "$PJ_SANDBOX_PORT_MAX" ]; do
		if ! printf '%s\n' "$1" | grep -qx "$port" && pj_sandbox_host_port_free "$port"; then
			echo "$port"
			return 0
		fi
		port=$((port + 1))
	done

	echo "pj-sandbox: no free port in range $PJ_SANDBOX_PORT_MIN-$PJ_SANDBOX_PORT_MAX" >&2
	return 1
}

# pj_sandbox_allocate_port [RESERVED]
#
# Prints a free ssh port. RESERVED is extra ports (space- or newline-
# separated) to treat as taken.
pj_sandbox_allocate_port() {
	_pj_sandbox_next_port "$(pj_sandbox_used_ports; printf '%s\n' ${1:-})"
}

# pj_sandbox_allocate_ports GUEST_PORTS_CSV [RESERVED]
#
# Prints one "guestPort:hostPort" pair per line for the comma-separated guest
# ports, each host port free and distinct from every earlier one in the same
# call. RESERVED is as for pj_sandbox_allocate_port: typically the ssh port
# this spawn just allocated, which no record holds yet.
pj_sandbox_allocate_ports() {
	taken="$(pj_sandbox_used_ports; printf '%s\n' ${2:-})"

	for guest_port in $(printf '%s\n' "$1" | tr ',' ' '); do
		host_port="$(_pj_sandbox_next_port "$taken")" || return 1
		echo "$guest_port:$host_port"
		taken="$(printf '%s\n%s' "$taken" "$host_port")"
	done
}
