#!/bin/sh
# for all directories run their install.sh
SOURCE="$0"
while [ -h "$SOURCE" ] ; do SOURCE="$(readlink "$SOURCE")"; done
DOTFILES_HOME="$( cd -P "$( dirname "$SOURCE" )" && pwd )"

# install_link src dst
#
# Safely and idempotently symlinks dst -> src:
# - no-ops if dst is already a symlink pointing at src
# - if dst exists as a real file/dir (or a symlink pointing elsewhere), it is
#   backed up with a timestamped suffix before the symlink is created
install_link() {
	src="$1"
	dst="$2"

	if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
		return 0
	fi

	if [ -e "$dst" ] || [ -L "$dst" ]; then
		backup="$dst.dotfiles-backup.$(date +%Y%m%d%H%M%S)"
		mv "$dst" "$backup"
		echo "install_link: backed up $dst -> $backup"
	fi

	ln -s "$src" "$dst"
	echo "install_link: linked $dst -> $src"
}

# detect_package_manager
#
# Echoes the first available package manager, checked in priority order
# (Homebrew, then apt, then dnf). Echoes nothing if none are found.
detect_package_manager() {
	if command -v brew >/dev/null 2>&1; then
		echo brew
	elif command -v apt-get >/dev/null 2>&1; then
		echo apt
	elif command -v dnf >/dev/null 2>&1; then
		echo dnf
	fi
}

# ensure_installed cmd pkg
#
# No-ops if `cmd` is already on PATH. Otherwise installs `pkg` using the
# package manager detect_package_manager finds, or fails with a clear
# message (rather than an obscure error or a silent skip) if none is
# available.
ensure_installed() {
	cmd="$1"
	pkg="$2"

	if command -v "$cmd" >/dev/null 2>&1; then
		return 0
	fi

	pm="$(detect_package_manager)"
	case "$pm" in
		brew)
			echo "ensure_installed: installing $pkg via Homebrew"
			brew install "$pkg"
			;;
		apt)
			echo "ensure_installed: installing $pkg via apt"
			sudo apt-get update && sudo apt-get install -y "$pkg"
			;;
		dnf)
			echo "ensure_installed: installing $pkg via dnf"
			sudo dnf install -y "$pkg"
			;;
		*)
			echo "ensure_installed: no supported package manager found (checked: brew, apt, dnf) -- please install '$pkg' manually" >&2
			return 1
			;;
	esac
}

# external tools required by dotfiles modules
ensure_installed fzf fzf

for sub_dir in "$DOTFILES_HOME"/*/; do
	module_name="$(basename "$sub_dir")"

	# pj-sandbox-spawn runs this same install.sh inside a spawned sandbox VM
	# (with DOTFILES_SANDBOX_GUEST=1) to give the guest the same aliases as
	# the host. Skip the sandbox module itself in that case -- there's no
	# sense installing Lima inside a Lima VM.
	if [ "$module_name" = "sandbox" ] && [ -n "${DOTFILES_SANDBOX_GUEST:-}" ]; then
		continue
	fi

	if [ -f "$sub_dir/install.sh" ]; then
		. "$sub_dir/install.sh"
	fi
done

# Runs in a sandbox VM guest too (DOTFILES_SANDBOX_GUEST=1): ~/.claude and
# ~/.copilot are ordinary writable directories there, not mounts, so this
# renders the guest's own copy of skills/subagents straight from this repo
# (mounted read-only at ~/dotfiles by pj-sandbox-spawn), same as on the host.
"$DOTFILES_HOME/bin/dotfiles-sync-agents"
