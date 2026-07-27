#!/bin/sh
install_link "$DOTFILES_HOME/vim" ~/.vim
install_link ~/.vim/vimrc ~/.vimrc

mkdir -p ~/tmp/vim/backup
mkdir -p ~/tmp/vim/swap

# Skipped inside a sandbox VM: this repo is mounted read-only there, and
# submodule init needs to write into .git/modules -- see
# DOTFILES_SANDBOX_GUEST in the root install.sh for the full rationale.
if [ -z "${DOTFILES_SANDBOX_GUEST:-}" ]; then
	git -C "$DOTFILES_HOME" submodule update --init
fi
