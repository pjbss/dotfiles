#!/bin/sh
# pj-hook-verify-edit.sh
#
# PostToolUse hook on Write/Edit. Syntax-checks a shell file the moment it's
# written, so a broken script surfaces as feedback on the edit that broke it
# rather than as a confusing failure several steps later.
#
# Advisory only -- always exits 0. A syntax error is worth telling the model
# about immediately, but the edit has already happened by the time a PostToolUse
# hook runs, so blocking here would achieve nothing except noise. The real gate
# is the Stop hook, which refuses to let a session finish with a red test suite.
#
# Scoped to shell files on purpose: this repo is shell, and a hook that tried to
# be a universal linter would either be wrong for most projects or slow for all
# of them. Per-project checks belong in that project's `make lint`.

set -eu

file_path="$(cat | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("tool_input", {}).get("file_path", "") or "")
except Exception:
    print("")
' 2>/dev/null || true)"

[ -n "$file_path" ] || exit 0
[ -f "$file_path" ] || exit 0

case "$file_path" in
	*.sh) interpreter="sh" ;;
	*.bash) interpreter="bash" ;;
	*.zsh) interpreter="zsh" ;;
	*)
		# No extension: fall back to the shebang, which is how the bin/
		# commands in this repo (no extension, mixed sh and zsh) get checked.
		case "$(head -1 "$file_path" 2>/dev/null)" in
			'#!'*zsh) interpreter="zsh" ;;
			'#!'*bash) interpreter="bash" ;;
			'#!'*sh) interpreter="sh" ;;
			*) exit 0 ;;
		esac
		;;
esac

command -v "$interpreter" >/dev/null 2>&1 || exit 0

if ! errors="$("$interpreter" -n "$file_path" 2>&1)"; then
	printf '%s' "$errors" | python3 -c '
import json, sys
print(json.dumps({"systemMessage": "Syntax error in the file just written:\n" + sys.stdin.read()}))
' 2>/dev/null || true
fi

exit 0
