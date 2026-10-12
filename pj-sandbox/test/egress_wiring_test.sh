#!/bin/bash
# egress_wiring_test.sh
#
# Tests for the egress wiring (issue 023): spawn starts one mitmdump per task
# on the host-only network, records it, and `rm`/`gc` stop exactly that one.
# Runs the real dispatcher with stub `limactl`, `ssh` and `mitmdump`
# (stub_proxy.sh), the same way spawn_test.sh does.

set -euo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PJ_SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"
. "$TEST_DIR/../../test/assert.sh"
. "$TEST_DIR/stub_proxy.sh"

CLI="$PJ_SANDBOX_DIR/bin/pj-sandbox"

fixture="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "$fixture"' EXIT

unset PJ_SANDBOX_STATE_DIR PJ_SANDBOX_SSH_INCLUDE_FILE PJ_SANDBOX_SSH_CONFIG_FILE \
	PJ_SANDBOX_PORT_MIN PJ_SANDBOX_PORT_MAX PJ_SANDBOX_INSTANCE_PREFIX PJ_SANDBOX_TEMPLATES_DIR \
	PJ_SANDBOX_PROXY_HOST XDG_STATE_HOME XDG_CONFIG_HOME GIT_CONFIG_GLOBAL GIT_DIR GIT_WORK_TREE
export HOME="$fixture/home"
export STUB_DIR="$fixture/stub"
# Long enough for a stub mitmdump that exits at once to be seen as dead.
export PJ_SANDBOX_PROXY_SETTLE=0.5
STATE_DIR="$HOME/.local/state/pj-sandbox"
mkdir -p "$HOME/.ssh" "$fixture/bin" "$STUB_DIR"
git init -q "$fixture/repo"
git -C "$fixture/repo" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m first
cd "$fixture/repo"

# start keeps the rendered config; list/delete track $STUB_DIR/instances the
# way Lima would, for rm and gc.
cat > "$fixture/bin/limactl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_DIR/calls"
case "$1" in
	start)
		for last in "$@"; do :; done
		cp "$last" "$STUB_DIR/rendered.yaml"
		shift
		printf '%s\n' "${2#--name=}" >> "$STUB_DIR/instances"
		;;
	ls)
		for name in "$@"; do :; done
		printf 'Host lima-%s\n  Hostname 127.0.0.1\n  Port 61022\n' "$name" > "$STUB_DIR/$name.ssh.config"
		echo "$STUB_DIR/$name.ssh.config"
		;;
	list)
		[ -f "$STUB_DIR/instances" ] || exit 0
		while read -r name; do
			printf '{"name":"%s","status":"Running"}\n' "$name"
		done < "$STUB_DIR/instances"
		;;
	delete)
		grep -vxF "$3" "$STUB_DIR/instances" > "$STUB_DIR/instances.new" || true
		mv "$STUB_DIR/instances.new" "$STUB_DIR/instances"
		;;
	copy) ;;
	shell) cat > /dev/null ;;
	*)
		echo "unexpected limactl call: $*" >&2
		exit 3
		;;
esac
STUB
# The guest bootstrap (the one `sh -s` script carrying the CA) is kept, so
# its generated text can be checked; profiles' post-bootstrap scripts aren't.
cat > "$fixture/bin/ssh" <<'STUB'
#!/bin/sh
cat > "$STUB_DIR/ssh-stdin"
! grep -q '^PJSB_CA$' "$STUB_DIR/ssh-stdin" || mv "$STUB_DIR/ssh-stdin" "$STUB_DIR/bootstrap.sh"
STUB
chmod +x "$fixture/bin/limactl" "$fixture/bin/ssh"
pj_test_stub_proxy "$fixture/bin"
export PJ_SANDBOX_DOTFILES_HOME="$fixture/repo"
export PATH="$fixture/bin:$PATH"

meta_get() { sed -n "s/^$2=//p" "$STATE_DIR/$1/meta"; }
proxy_call() { grep -F -- "pjsb_policy_dir=$STATE_DIR/$1/policy " "$STUB_DIR/mitmdump-calls" || true; }
alive() { kill -0 "$1" 2>/dev/null; }

# --- spawn starts the task's proxy and records it ---

if out="$("$CLI" spawn alpha --base none 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "spawn exits 0 (output: $out)"

call="$(proxy_call alpha)"
assert_eq "1" "$(printf '%s\n' "$call" | grep -c .)" "spawn starts exactly one mitmdump for the task"
assert_contains "$call" "-s $PJ_SANDBOX_DIR/proxy/addon.py" "the proxy loads the policy and inject addon"
assert_contains "$call" "--set pjsb_policy_dir=$STATE_DIR/alpha/policy" "the proxy gets the task's policy dir (its log is egress.log beside it)"
assert_contains "$call" "--set pjsb_mode=deny" "the mode defaults to deny"
assert_contains "$call" "--set confdir=$HOME/.config/pj-sandbox/ca" "the proxy signs with the per-install CA"
assert_contains "$call" "--listen-host 192.168.106.1" "the proxy listens on the host-only network's gateway"
proxy_port="$(meta_get alpha proxy_port)"
assert_contains "$call" "--listen-port $proxy_port" "the proxy listens on the recorded port"
assert_ok "the proxy port ($proxy_port) is in the pj-sandbox range" test "$proxy_port" -ge 61022 -a "$proxy_port" -le 61099
assert_ok "the proxy port isn't the ssh port" test "$proxy_port" != "$(meta_get alpha ssh_port)"
alpha_pid="$(meta_get alpha proxy_pid)"
assert_ok "the record has the proxy's PID ($alpha_pid), and it's running" alive "$alpha_pid"
assert_contains "$(ps -p "$alpha_pid" -o command=)" "pjsb_policy_dir=$STATE_DIR/alpha/policy" "the recorded PID is that task's mitmdump"
assert_eq "deny" "$(meta_get alpha egress_mode)" "the record holds the egress mode"

# --- --egress ---

"$CLI" spawn beta --base none --egress observe >/dev/null 2>&1
assert_contains "$(proxy_call beta)" "--set pjsb_mode=observe" "--egress observe is passed to the proxy"
assert_eq "observe" "$(meta_get beta egress_mode)" "--egress observe is recorded"
beta_pid="$(meta_get beta proxy_pid)"
assert_ok "a second task gets its own proxy" test "$beta_pid" != "$alpha_pid"
assert_ok "a second task's proxy port isn't the first's" test "$(meta_get beta proxy_port)" != "$(meta_get alpha proxy_port)"

: > "$STUB_DIR/calls"
for mode in bogus DENY "" all; do
	if out="$("$CLI" spawn bad --base none --egress "$mode" 2>&1)"; then rc=0; else rc=$?; fi
	assert_exit_code 1 "$rc" "--egress '$mode' exits 1"
	assert_contains "$out" "--egress takes deny, observe or open" "--egress '$mode' names the valid modes"
done
if out="$("$CLI" spawn bad --base none --egress 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "--egress with no value exits 1"
assert_eq "" "$(cat "$STUB_DIR/calls")" "a bad --egress never reaches limactl"
assert_eq "" "$(proxy_call bad)" "a bad --egress starts no proxy"

# --- a proxy that won't start fails the spawn and leaves nothing behind ---

if out="$(MITMDUMP_FAIL=1 "$CLI" spawn dud --base none 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "spawn fails when mitmdump exits at once"
assert_contains "$out" "egress proxy" "the failure names the proxy"
assert_ok "a failed proxy leaves no state dir" test ! -e "$STATE_DIR/dud"

# --- rm stops exactly that task's proxy ---

if out="$("$CLI" rm alpha 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "rm exits 0 (output: $out)"
assert_not_ok "rm stops the task's proxy" alive "$alpha_pid"
assert_ok "rm leaves another task's proxy running" alive "$beta_pid"

# A recorded PID that now belongs to some other process is left alone.
sleep 300 &
bystander=$!
"$CLI" spawn gamma --base none >/dev/null 2>&1
gamma_pid="$(meta_get gamma proxy_pid)"
sed -i.bak "s/^proxy_pid=.*/proxy_pid=$bystander/" "$STATE_DIR/gamma/meta"
"$CLI" rm gamma >/dev/null 2>&1
assert_ok "rm never kills a recorded PID that isn't the task's mitmdump" alive "$bystander"
{ kill "$bystander" "$gamma_pid" && wait "$bystander"; } 2>/dev/null || true

# --- gc stops the proxy of a record it cleans up ---

grep -vxF pjsb-beta "$STUB_DIR/instances" > "$STUB_DIR/instances.new" || true
mv "$STUB_DIR/instances.new" "$STUB_DIR/instances"
if out="$(PJ_SANDBOX_GC_GRACE_MINUTES=0 "$CLI" gc 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "gc exits 0 (output: $out)"
assert_contains "$out" "deleted state beta" "gc cleans up the record whose VM is gone"
assert_not_ok "gc stops that record's proxy" alive "$beta_pid"

"$CLI" spawn delta --base none >/dev/null 2>&1
delta_pid="$(meta_get delta proxy_pid)"
grep -vxF pjsb-delta "$STUB_DIR/instances" > "$STUB_DIR/instances.new" || true
mv "$STUB_DIR/instances.new" "$STUB_DIR/instances"
PJ_SANDBOX_GC_GRACE_MINUTES=0 "$CLI" gc --dry-run >/dev/null 2>&1
assert_ok "gc --dry-run stops no proxy" alive "$delta_pid"

# --- the rendered Lima config carries the chosen spike's network ---

# The top-level vmType and networks keys, each with its indented or list
# lines, in file order.
network_section() {
	awk '
		/^[^ -]/ { keep = ($0 ~ /^(vmType|networks):/) }
		keep && NF
	' "$1"
}
spike_network="$(network_section "$PJ_SANDBOX_DIR/lima/spike/vmnet-hostonly.yaml")"
assert_contains "$spike_network" "networks:" "the spike config's network section is found"
if network_diff="$(diff <(printf '%s\n' "$spike_network") <(network_section "$STUB_DIR/rendered.yaml"))"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "the rendered config's network section matches lima/spike/vmnet-hostonly.yaml (diff: $network_diff)"

# --- the guest bootstrap points the guest at its proxy ---

# The bootstrap captured is delta's, the last spawn.
script="$(cat "$STUB_DIR/bootstrap.sh")"
proxy_url="http://192.168.106.1:$(meta_get delta proxy_port)"
assert_contains "$script" "PJSB_PROXY='$proxy_url'" "the bootstrap is handed the task's proxy URL"
assert_contains "$script" "/etc/profile.d/pjsb-proxy.sh" "login shells get the proxy environment from /etc/profile.d"
for var in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy; do
	assert_contains "$script" "export $var=\"\$PJSB_PROXY\"" "the login profile exports $var"
done
assert_contains "$script" 'export NO_PROXY="$PJSB_NO_PROXY"' "the login profile exports NO_PROXY"
assert_contains "$script" "PJSB_NO_PROXY='localhost,127.0.0.1,::1'" "NO_PROXY covers only the guest itself"
assert_contains "$script" "/etc/docker/daemon.json" "the Docker daemon's config is written"
assert_contains "$script" '"proxies"' "the Docker daemon gets a proxies setting"
assert_contains "$script" '"http-proxy": proxy, "https-proxy": proxy, "no-proxy": no_proxy' "the Docker proxies point at the task's proxy"
assert_contains "$script" "systemctl restart docker" "dockerd is restarted to pick its proxies up"
assert_contains "$script" "ip -4 route del default dev eth0" "the lockdown removes eth0's default route"
assert_contains "$script" "blackhole 192.168.5.3/32" "the lockdown blackholes Lima's own resolver"
assert_contains "$script" "systemctl enable --now pjsb-egress-lockdown.service" "the lockdown is a unit, so it holds across reboots"
lockdown_at="$(printf '%s\n' "$script" | grep -n 'enable --now pjsb-egress-lockdown' | cut -d: -f1 || true)"
zsh_at="$(printf '%s\n' "$script" | grep -n 'apt-get install -y zsh' | cut -d: -f1 || true)"
assert_ok "the lockdown comes after the bootstrap's own installs" test "$lockdown_at" -gt "$zsh_at"

# Only a plain http://<IPv4>:<port> URL is accepted into the script.
ca="$HOME/.config/pj-sandbox/ca/ca.pem"
for bad in "" "http://0.0.0.0:8080" "http://1.2.3.4:80'; reboot; '" "https://1.2.3.4:80" "http://host:80"; do
	if bad_out="$(. "$PJ_SANDBOX_DIR/lib/bootstrap.sh" && pj_sandbox_bootstrap_script "$ca" "$bad" 2>&1)"; then rc=0; else rc=$?; fi
	assert_exit_code 1 "$rc" "the bootstrap refuses proxy URL '$bad'"
done

# --- nothing listens on every interface ---

assert_not_contains "$(cat "$STUB_DIR/rendered.yaml")" "0.0.0.0" "the rendered Lima config binds nothing on 0.0.0.0"
assert_not_contains "$(cat "$STUB_DIR/mitmdump-calls")" "0.0.0.0" "no proxy command line binds 0.0.0.0"
assert_eq "$(grep -c . "$STUB_DIR/mitmdump-calls")" "$(grep -c -- '--listen-host 192.168.106.1 ' "$STUB_DIR/mitmdump-calls")" \
	"every proxy command line names its listen host"
for wildcard in 0.0.0.0 "::" ""; do
	: > "$STUB_DIR/mitmdump-calls"
	: > "$STUB_DIR/calls"
	if out="$(PJ_SANDBOX_PROXY_HOST="$wildcard" "$CLI" spawn wild --base none 2>&1)"; then rc=0; else rc=$?; fi
	if [ -z "$wildcard" ]; then
		# Empty falls back to the default, like every other namespace var.
		assert_exit_code 0 "$rc" "an empty PJ_SANDBOX_PROXY_HOST uses the default (output: $out)"
		assert_contains "$(cat "$STUB_DIR/mitmdump-calls")" "--listen-host 192.168.106.1 " "an empty PJ_SANDBOX_PROXY_HOST listens on the default"
		"$CLI" rm wild >/dev/null 2>&1
		continue
	fi
	assert_exit_code 1 "$rc" "PJ_SANDBOX_PROXY_HOST=$wildcard makes spawn fail"
	assert_eq "" "$(cat "$STUB_DIR/mitmdump-calls")" "PJ_SANDBOX_PROXY_HOST=$wildcard starts no proxy"
	assert_eq "" "$(grep '^start ' "$STUB_DIR/calls" || true)" "PJ_SANDBOX_PROXY_HOST=$wildcard is refused before any VM is started"
	assert_ok "PJ_SANDBOX_PROXY_HOST=$wildcard leaves no state dir" test ! -e "$STATE_DIR/wild"
done

assert_report
