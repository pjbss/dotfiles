#!/bin/sh
# claude profile: run as the guest user after the bootstrap. Ported from the
# guest bootstrap in bin/pj-sbx-spawn.
#
# Seeds ~/.claude.json so headless runs work at once. Accepting the bypass
# permissions disclaimer interactively didn't reliably persist on a later
# launch. bypassPermissionsModeAccepted is the field `claude --bg`'s
# disclaimer check reads, and hasCompletedOnboarding skips the onboarding
# wizard. Any keys already in the file are kept.
set -eu
claude_version="$(claude --version 2>/dev/null | awk '{print $1}')"
python3 -c '
import json, os, sys
path = os.path.expanduser("~/.claude.json")
d = json.load(open(path)) if os.path.exists(path) else {}
d.update(hasCompletedOnboarding=True, lastOnboardingVersion=sys.argv[1], bypassPermissionsModeAccepted=True)
json.dump(d, open(path, "w"), indent=2)
' "$claude_version"
