#!/bin/sh
# fzf key bindings and completion, sourced directly from fzf's own zsh
# integration (`fzf --zsh`) rather than oh-my-zsh's fzf plugin wrapper, per
# PRD "Feature porting methodology". Guarded so this is a no-op if fzf isn't
# installed (installer in issues/002-installer-dependency-detection.md is
# responsible for ensuring it is), and also a no-op if the installed fzf
# predates `--zsh` support (added in fzf 0.48 -- older package-manager
# builds, e.g. Debian/Ubuntu's apt package, don't have it).
if (( $+commands[fzf] )); then
  fzf_zsh_init="$(fzf --zsh 2> /dev/null)"
  [[ -n "$fzf_zsh_init" ]] && eval "$fzf_zsh_init"
  unset fzf_zsh_init
fi
