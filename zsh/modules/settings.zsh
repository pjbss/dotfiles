#!/bin/sh
# auotomatically enter directories without cd
setopt auto_cd

#use vim as an editor
export  EDITOR=vim

# expand functions in the prompt
setopt prompt_subst

# ignore duplicate history entries
setopt histignoredups

# keep tons of history
export HISTSIZE=4096

# automatically pushd
setopt auto_pushd
export dirstacksize=5

# try to correct command line spelling
setopt CORRECT CORRECT_ALL

# enable extended globbing
setopt EXTENDED_GLOB

# load colors
autoload colors; colors;
