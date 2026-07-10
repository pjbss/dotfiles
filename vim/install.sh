#!/bin/sh
install_link "$DOTFILES_HOME/vim" ~/.vim
install_link ~/.vim/vimrc ~/.vimrc

mkdir -p ~/tmp/vim/backup
mkdir -p ~/tmp/vim/swap

git submodule update --init
