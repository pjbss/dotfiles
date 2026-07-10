#!/bin/sh
# for all directories run their install.sh
SOURCE="${BASH_SOURCE[0]}"
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

for sub_dir in $DOTFILES_HOME/*/; do
	if [ -f $sub_dir/install.sh ]; then
		source $sub_dir/install.sh
	fi
done
