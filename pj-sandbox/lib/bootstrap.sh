# bootstrap.sh
#
# The guest bootstrap spawn runs once the VM is up and the repo is cloned:
# trust the proxy CA, copy the dotfiles in, install them, mark the VM as a
# sandbox, and hand bash logins off to zsh. Ported from bin/pj-sbx-spawn minus its token forwarding
# (credentials are brokered by the host proxy, never put in the guest) and
# minus its read-only ~/dotfiles mount. Meant to be sourced, not executed.
#
# Both ssh calls have fixed argv. ssh joins its command argv into one string
# for the remote shell to re-split, so any value placed there can be mangled
# (see sandbox_guest_auth_preamble in sandbox/lib/task.sh). The archive and
# the script both arrive on stdin, and the script needs no values from the
# host. A value it needs later belongs in shell assignments prepended to the
# script, never in argv.

# pj_sandbox_dotfiles_archive DOTFILES_HOME
#
# Prints a tar of DOTFILES_HOME's HEAD. `git archive` only includes tracked
# files, so the gitignored local/ tree (and anything else untracked) is never
# sent.
pj_sandbox_dotfiles_archive() {
	git -C "$1" archive --format=tar HEAD
}

# Where the guest's trust store gets the proxy CA's certificate.
PJ_SANDBOX_GUEST_CA=/usr/local/share/ca-certificates/pjsb.crt

# Where the guest's proxy environment for login shells goes.
PJ_SANDBOX_GUEST_PROXY_PROFILE=/etc/profile.d/pjsb-proxy.sh

# pj_sandbox_bootstrap_guest INSTANCE SSH_CONFIG DOTFILES_HOME CA_PEM PROXY_URL
#
# Streams the dotfiles archive into the guest's ~/dotfiles, then runs
# pj_sandbox_bootstrap_script CA_PEM PROXY_URL there, both over
# `ssh -F SSH_CONFIG INSTANCE`.
pj_sandbox_bootstrap_guest() {
	script="$(pj_sandbox_bootstrap_script "$4" "$5")" || return 1
	pj_sandbox_dotfiles_archive "$3" |
		ssh -F "$2" "$1" 'mkdir -p "$HOME/dotfiles" && tar -xf - -C "$HOME/dotfiles"' || return 1
	printf '%s\n' "$script" | ssh -F "$2" "$1" 'sh -s'
}

# pj_sandbox_bootstrap_script CA_PEM PROXY_URL
#
# Prints the script the guest runs as `sh -s`. It's POSIX sh, since the guest
# runs it under dash.
#
# PROXY_URL is the task's proxy, http://<IPv4>:<port> (lib/proxy.sh). It's
# the one host value the script needs, so it's checked to be exactly that
# shape and put in a shell assignment at the top. The script's last step,
# after its own installs, points the guest at the proxy and closes the rest
# (pj-sandbox/docs/spike-egress.md, "Findings"):
#   - HTTP(S)_PROXY and NO_PROXY for login shells (PJ_SANDBOX_GUEST_PROXY_PROFILE)
#     and for PAM sessions (/etc/environment), apt's proxy, and the Docker
#     daemon's "proxies" setting (dockerd is restarted to pick it up)
#   - a pjsb-egress-lockdown unit, enabled now and at every boot, that
#     deletes eth0's default route and blackholes Lima's resolver at
#     192.168.5.3, which is on eth0's own subnet. lima0, the host-only
#     network, is then the only route. A networkd drop-in also stops eth0's
#     DHCP from handing the route back. All of it is inside the guest, so
#     root can undo it: the accepted gap in the findings.
#
# CA_PEM is the proxy CA's certificate (lib/ca.sh). Its content is put in the
# script as a quoted heredoc and installed as PJ_SANDBOX_GUEST_CA, first, so
# everything after it (apt included) already trusts the proxy. Only ca.pem is
# ever read here; the key never leaves the host. A file that isn't exactly
# one PEM certificate is refused, so nothing else can ride along.
#
# The zsh handoff goes in the bash login file, not just chsh: every ssh
# session to a Lima VM is multiplexed over the ControlMaster connection opened
# at boot, which keeps whatever passwd said back then. Bash re-reads its login
# file on every login.
#
# The handoff is guarded by PJSANDBOX_ZSH_HANDED_OFF, exported just before the
# exec so every descendant inherits it, and not by $ZSH_VERSION alone. An
# agent's shell tool may source this same login file for each shell it
# spawns, and without the marker each of those would `exec zsh -l` and hang
# waiting for a terminal it doesn't have.
#
# /etc/pj-sandbox is the marker pj-run-issues and the pj-hook-* guards check
# to know they're in a sandbox. It's a mode switch, not a security control:
# the guest user has sudo and can remove it.
pj_sandbox_bootstrap_script() {
	if ! awk '
		/^-----BEGIN CERTIFICATE-----$/ { begins++; inside = 1; next }
		/^-----END CERTIFICATE-----$/ { ends++; inside = 0; next }
		!inside && NF { stray = 1 }
		END { exit !(begins == 1 && ends == 1 && !inside && !stray) }
	' "$1" 2>/dev/null; then
		echo "pj-sandbox: '$1' isn't a single PEM certificate" >&2
		return 1
	fi
	if ! printf '%s\n' "$2" | grep -Eqx 'http://[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]{1,5}' ||
		[ "${2#http://0.0.0.0:}" != "$2" ]; then
		echo "pj-sandbox: proxy URL '$2' isn't http://<IPv4 address>:<port>" >&2
		return 1
	fi

	echo "set -eu"
	echo
	echo "PJSB_PROXY='$2'"
	echo "PJSB_NO_PROXY='localhost,127.0.0.1,::1'"
	echo "PJSB_PROXY_PROFILE=$PJ_SANDBOX_GUEST_PROXY_PROFILE"
	echo
	echo "sudo mkdir -p $(dirname "$PJ_SANDBOX_GUEST_CA")"
	echo "sudo tee $PJ_SANDBOX_GUEST_CA >/dev/null <<'PJSB_CA'"
	cat "$1"
	echo "PJSB_CA"
	echo "sudo update-ca-certificates >/dev/null"
	cat <<'SCRIPT'

if ! command -v zsh >/dev/null 2>&1; then
	sudo apt-get update
	sudo apt-get install -y zsh
fi
DOTFILES_SANDBOX_GUEST=1 "$HOME/dotfiles/install.sh"
sudo chsh -s "$(command -v zsh)" "$(whoami)"

printf 'pj-sandbox guest\n' | sudo tee /etc/pj-sandbox >/dev/null

bash_login_file="$HOME/.profile"
[ -f "$HOME/.bash_login" ] && bash_login_file="$HOME/.bash_login"
[ -f "$HOME/.bash_profile" ] && bash_login_file="$HOME/.bash_profile"

if ! grep -qF "pj-sandbox: hand off to zsh" "$bash_login_file" 2>/dev/null; then
	cat >> "$bash_login_file" <<'PROFILE'

# pj-sandbox: hand off to zsh here, since chsh never reaches this VM's
# multiplexed ssh sessions. Guarded by an inherited marker, not just
# $ZSH_VERSION, so a tool that sources this file to start a child shell
# (an agent's shell tool may) isn't hijacked into a terminal-less zsh.
if [ -z "$ZSH_VERSION" ] && [ -z "$PJSANDBOX_ZSH_HANDED_OFF" ] && command -v zsh >/dev/null 2>&1; then
	export PJSANDBOX_ZSH_HANDED_OFF=1
	exec zsh -l
fi
PROFILE
fi

# Egress, last, so the installs above went out the way the VM booted.
{
	printf "PJSB_PROXY='%s'\n" "$PJSB_PROXY"
	printf "PJSB_NO_PROXY='%s'\n" "$PJSB_NO_PROXY"
	cat <<'PROFILE'
# pj-sandbox: this guest's only way out is its task's egress proxy.
export HTTP_PROXY="$PJSB_PROXY"
export HTTPS_PROXY="$PJSB_PROXY"
export http_proxy="$PJSB_PROXY"
export https_proxy="$PJSB_PROXY"
export NO_PROXY="$PJSB_NO_PROXY"
export no_proxy="$PJSB_NO_PROXY"
unset PJSB_PROXY PJSB_NO_PROXY
PROFILE
} | sudo tee "$PJSB_PROXY_PROFILE" >/dev/null

sudo sed -i -E '/^(HTTPS?_PROXY|https?_proxy|NO_PROXY|no_proxy)=/d' /etc/environment
for var in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy; do
	printf '%s=%s\n' "$var" "$PJSB_PROXY"
done | sudo tee -a /etc/environment >/dev/null
printf 'NO_PROXY=%s\nno_proxy=%s\n' "$PJSB_NO_PROXY" "$PJSB_NO_PROXY" | sudo tee -a /etc/environment >/dev/null

printf 'Acquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\n' "$PJSB_PROXY" "$PJSB_PROXY" |
	sudo tee /etc/apt/apt.conf.d/95pjsb-proxy >/dev/null

sudo mkdir -p /etc/docker
sudo python3 - "$PJSB_PROXY" "$PJSB_NO_PROXY" <<'PY'
import json, os, sys
path = "/etc/docker/daemon.json"
proxy, no_proxy = sys.argv[1], sys.argv[2]
d = json.load(open(path)) if os.path.exists(path) else {}
d["proxies"] = {"http-proxy": proxy, "https-proxy": proxy, "no-proxy": no_proxy}
with open(path, "w") as f:
    json.dump(d, f, indent=2)
PY
if command -v dockerd >/dev/null 2>&1; then
	sudo systemctl restart docker
fi

sudo tee /usr/local/sbin/pjsb-egress-lockdown >/dev/null <<'LOCKDOWN'
#!/bin/sh
# pj-sandbox: leave lima0 (the host-only network) as the only route out.
# eth0 stays up, since ssh rides it, but loses its default route, and Lima's
# resolver on eth0's subnet is blackholed.
while ip -4 route del default dev eth0 2>/dev/null; do :; done
ip -4 route replace blackhole 192.168.5.3/32
LOCKDOWN
sudo chmod 755 /usr/local/sbin/pjsb-egress-lockdown
sudo tee /etc/systemd/system/pjsb-egress-lockdown.service >/dev/null <<'UNIT'
[Unit]
Description=pj-sandbox: leave the host-only network as the only route out
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/pjsb-egress-lockdown

[Install]
WantedBy=multi-user.target
UNIT
sudo mkdir -p /etc/systemd/network/10-netplan-eth0.network.d
printf '[DHCPv4]\nUseRoutes=false\nUseDNS=false\n' |
	sudo tee /etc/systemd/network/10-netplan-eth0.network.d/pjsb-egress.conf >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable --now pjsb-egress-lockdown.service
SCRIPT
}
