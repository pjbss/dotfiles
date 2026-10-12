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

# pj_sandbox_bootstrap_guest INSTANCE SSH_CONFIG DOTFILES_HOME CA_PEM
#
# Streams the dotfiles archive into the guest's ~/dotfiles, then runs
# pj_sandbox_bootstrap_script CA_PEM there, both over
# `ssh -F SSH_CONFIG INSTANCE`.
pj_sandbox_bootstrap_guest() {
	pj_sandbox_dotfiles_archive "$3" |
		ssh -F "$2" "$1" 'mkdir -p "$HOME/dotfiles" && tar -xf - -C "$HOME/dotfiles"' || return 1
	script="$(pj_sandbox_bootstrap_script "$4")" || return 1
	printf '%s\n' "$script" | ssh -F "$2" "$1" 'sh -s'
}

# pj_sandbox_bootstrap_script CA_PEM
#
# Prints the script the guest runs as `sh -s`. It's POSIX sh, since the guest
# runs it under dash.
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

	echo "set -eu"
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
SCRIPT
}
