#!/bin/sh
GITCONFIG_MARKER="# dotfiles: managed block from $DOTFILES_HOME/git/gitconfig.partial"

if [ -e ~/.gitconfig ] && grep -qF "$GITCONFIG_MARKER" ~/.gitconfig 2>/dev/null; then
	return 0
fi

if [ -e ~/.gitconfig ]; then
	backup=~/.gitconfig.dotfiles-backup.$(date +%Y%m%d%H%M%S)
	cp ~/.gitconfig "$backup"
	echo "git/install.sh: backed up ~/.gitconfig -> $backup"
fi

{
	echo "$GITCONFIG_MARKER"
	cat "$DOTFILES_HOME/git/gitconfig.partial"
	echo "[include]"
	echo "	path = $DOTFILES_HOME/local/gitconfig.local"
} >> ~/.gitconfig
