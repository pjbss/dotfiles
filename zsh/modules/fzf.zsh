#!/bin/sh
# fzf key bindings and completion, sourced directly from fzf's own zsh
# integration (`fzf --zsh`) rather than oh-my-zsh's fzf plugin wrapper, per
# PRD "Feature porting methodology". Guarded so this is a no-op if fzf isn't
# installed (installer in issues/002-installer-dependency-detection.md is
# responsible for ensuring it is), and also a no-op if the installed fzf
# predates `--zsh` support (added in fzf 0.48 -- older package-manager
# builds, e.g. Debian/Ubuntu's apt package, don't have it).
#
# Also requires a real controlling terminal (-t 0): fzf's generated init
# guards its key-bindings on `[[ -o interactive ]]` alone, but a shell can be
# forced interactive (e.g. `zsh -i -c ...`, as some tooling does) without a
# tty attached. In that case `-o interactive` is true but there's nothing
# for zle to bind to, and `zle -N` throws "can't change option: zle".
if (( $+commands[fzf] )) && [[ -t 0 ]]; then
  fzf_zsh_init="$(fzf --zsh 2> /dev/null)"
  [[ -n "$fzf_zsh_init" ]] && eval "$fzf_zsh_init"
  unset fzf_zsh_init
fi
