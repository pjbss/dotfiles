#!/bin/sh
# fzf key bindings and completion, sourced directly from fzf's own zsh
# integration (`fzf --zsh`) rather than oh-my-zsh's fzf plugin wrapper, per
# PRD "Feature porting methodology". Guarded so this is a no-op if fzf isn't
# installed (installer in issues/002-installer-dependency-detection.md is
# responsible for ensuring it is).
if (( $+commands[fzf] )); then
  source <(fzf --zsh)
fi
