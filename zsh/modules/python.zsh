#!/bin/sh
# ported from oh-my-zsh python plugin; audited against ~/.zsh_history (7,757
# commands reviewed) against all 8 aliases/functions in the plugin (py,
# pyfind, pyclean, pyuserpaths, pygrep, pyserver, vrun, mkv) — none were
# used. This user always activates virtualenvs directly via
# `source venv/bin/activate` (or equivalent) rather than the plugin's `vrun`/
# `mkv` shortcuts, and never invoked the other aliases/functions. File exists
# (and is sourced by the module loader) to document that the audit happened
# and concluded "nothing to port," per the PRD's usage-based porting
# methodology, rather than silently skipping the module.
