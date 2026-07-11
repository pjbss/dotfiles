#!/bin/sh
# ported from oh-my-zsh aws plugin; audited against ~/.zsh_history (7,757
# commands reviewed) against the plugin's profile-switching helpers (asp,
# acp, asr, agp, agr, aws_change_access_key) — none were used. This user
# sets $AWS_PROFILE inline per-command (e.g. `AWS_PROFILE=wl-dev aws sso
# login`) rather than using the plugin's profile-switching shortcuts, so
# those are not ported. (Showing the active $AWS_PROFILE in the prompt is
# a separate slice — see zsh/prompt/functions.zsh.)
#
# AWS CLI completion is a non-alias behavior that IS used every time `aws`
# is tab-completed, so it's ported directly: aws-cli v2 ships its own
# completer binary (aws_completer), which just needs zsh's bashcompinit
# shim wired up.
if (( $+commands[aws_completer] )); then
  autoload -Uz bashcompinit && bashcompinit
  complete -C aws_completer aws
fi
