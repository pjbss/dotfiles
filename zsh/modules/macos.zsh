#!/bin/sh
# ported from oh-my-zsh macos plugin; audited against ~/.zsh_history (7,757
# commands reviewed) against all ~20 aliases/functions in the plugin (ofd,
# showfiles, hidefiles, btrestart, tab, split_tab, vsplit_tab, pfd, pfs, cdf,
# pushdf, pxd, cdx, quick-look, man-preview, vncviewer, rmdsstore, freespace,
# music, spotify, itunes) — none were used via their shortcuts. One instance
# of the underlying showfiles/hidefiles behavior was found (`defaults write
# com.apple.Finder AppleShowAllFiles true`, typed out directly rather than
# through the alias), but a single one-off invocation isn't evidence of a
# routine workflow worth porting as a shortcut, so nothing was ported.
#
# Guarded so this module only activates on Darwin (per PRD user story 5: the
# same repo should work cleanly on a Linux box). Currently a no-op
# everywhere, since the audit found nothing to port — this is where future
# macOS-only helpers should be added as they come up.
if [[ "$OSTYPE" == darwin* ]]; then
  : # nothing to port; see audit above
fi
