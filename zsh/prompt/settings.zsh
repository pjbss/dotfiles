#!/bin/sh
ZSH_THEME_GIT_PROMPT_PREFIX=" [%{$fg_bold[magenta]%}"
ZSH_THEME_GIT_PROMPT_SUFFIX="%{$reset_color%}]"
ZSH_THEME_GIT_PROMPT_DIRTY="%{$fg_bold[green]%}!"
ZSH_THEME_GIT_PROMPT_UNTRACKED="%{$fg_bold[green]%}?"
ZSH_THEME_GIT_PROMPT_CLEAN=""
ZSH_THEME_GIT_PROMPT_WORKTREE_PREFIX=" %{$fg_bold[yellow]%}("
ZSH_THEME_GIT_PROMPT_WORKTREE_SUFFIX=")%{$reset_color%}"
ZSH_THEME_GIT_PROMPT_AHEAD_BEHIND_PREFIX=" %{$fg_bold[cyan]%}"
ZSH_THEME_GIT_PROMPT_AHEAD_BEHIND_SUFFIX="%{$reset_color%}"
ZSH_THEME_GIT_PROMPT_AHEAD="↑"
ZSH_THEME_GIT_PROMPT_BEHIND="↓"
ZSH_THEME_PYTHON_PROMPT_PREFIX=" %{$fg_bold[blue]%}("
ZSH_THEME_PYTHON_PROMPT_SUFFIX=")%{$reset_color%}"
ZSH_THEME_AWS_PROMPT_PREFIX=" %{$fg_bold[red]%}["
ZSH_THEME_AWS_PROMPT_SUFFIX="]%{$reset_color%}"

PROMPT='%{$fg_bold[magenta]%}%n%{$reset_color%}@%{$fg_bold[cyan]%}$(box_name)%{$reset_color%}:%{$fg_bold[green]%}%~%{$reset_color%}$(git_prompt_info)$(git_prompt_worktree_name)$(git_prompt_ahead_behind)$(python_prompt_info)$(aws_prompt_info) $ '
RPROMPT='%{$fg_bold[magenta]%}%?%{$reset_color%} %D %t'

# setup the prompt with pretty colors
setopt prompt_subst
