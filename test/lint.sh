#!/bin/sh
# lint.sh
#
# Syntax-checks every shell source in this repo with the interpreter it's
# actually written for, and runs shellcheck over the ones it understands when
# shellcheck happens to be installed (it's an optional convenience, never a
# hard dependency -- a machine without it still gets the syntax pass).
#
# Interpreter selection is by shebang, not by extension: `bin/` holds a mix of
# `#!/bin/sh` and `#!/bin/zsh` scripts, and a zsh script (`(N)` glob
# qualifiers, `${(%):-%x}`) is a syntax error to `sh -n`. Files with no shebang
# are the sourced `lib/*.sh` fragments, which are POSIX sh by convention.
#
# Not every source here is shell any more: agents/lib/stream_render.py parses
# the event stream pj-run-issues renders. Left to the fallback it would be
# handed to `sh -n`, which rejects Python outright -- so it would have been
# either a permanent lint failure or, worse, quietly excluded from the only
# syntax gate this repo has.
#
# Vendored vim bundles and the gitignored local/ tree are skipped -- neither is
# this repo's code to lint.
#
# Usage: test/lint.sh [--help|-h]

set -eu

SOURCE="$0"
while [ -h "$SOURCE" ]; do SOURCE="$(readlink "$SOURCE")"; done
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
DOTFILES_HOME="$(cd -P "$TEST_DIR/.." && pwd)"

for arg in "$@"; do
	case "$arg" in
		--help | -h)
			sed -n '2,/^$/p' "$SOURCE" | sed 's/^# \{0,1\}//'
			exit 0
			;;
	esac
done

cd "$DOTFILES_HOME"

# lint_python FILE
#
# Syntax-checks a Python source. `ast.parse` rather than `python3 -m
# py_compile`, whose side effect is a __pycache__ directory littered into the
# tree it was asked to check.
lint_python() {
	python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' "$1"
}

# lint_interpreter FILE
#
# Echoes the syntax-check command for FILE, or nothing if it should be skipped
# (e.g. a zsh script on a machine with no zsh).
lint_interpreter() {
	# Extension wins over shebang for .zsh: several of those files carry a
	# `#!/bin/sh` line despite being sourced by zsh and using zsh-only syntax
	# (`pj-sbx-ssh()` -- a hyphenated function name -- in
	# zsh/modules/sandbox.zsh). They're sourced, never executed, so the
	# shebang there is decoration.
	case "$1" in
		*.zsh)
			command -v zsh >/dev/null 2>&1 && echo "zsh -n"
			return 0
			;;
	esac

	case "$1" in
		*.py)
			command -v python3 >/dev/null 2>&1 && echo "lint_python"
			return 0
			;;
	esac

	case "$(head -1 "$1")" in
		'#!'*zsh) command -v zsh >/dev/null 2>&1 && echo "zsh -n" ;;
		'#!'*bash) echo "bash -n" ;;
		'#!'*python*) command -v python3 >/dev/null 2>&1 && echo "lint_python" ;;
		*) echo "sh -n" ;;
	esac
}

failures=0
checked=0

# Every shell source this repo owns: the bin/ commands, the sourced libs, each
# module's install.sh, the zsh config, and the test files themselves.
files="$(
	{
		find bin -type f || true
		find sandbox/lib agents/lib test -type f -name '*.sh' 2>/dev/null || true
		find agents/lib -type f -name '*.py' 2>/dev/null || true
		find sandbox/test zsh/modules/test agents/test -type f -name '*.sh' 2>/dev/null || true
		find zsh -type f -name '*.zsh' || true
		echo install.sh
		find . -mindepth 2 -maxdepth 2 -name install.sh -not -path './vim/bundle/*' -not -path './local/*' || true
	} 2>/dev/null | sed 's|^\./||' | sort -u
)"

for file in $files; do
	[ -f "$file" ] || continue

	interpreter="$(lint_interpreter "$file")"
	[ -n "$interpreter" ] || continue

	checked=$((checked + 1))
	if ! $interpreter "$file" 2>&1; then
		echo "LINT FAIL: $file ($interpreter)"
		failures=$((failures + 1))
	fi

	# macOS's /bin/sh is bash in POSIX mode, which happily accepts bashisms
	# (arrays, `<(...)`, `local`) that the sandbox guest's real dash rejects at
	# runtime. Where dash is installed, check `#!/bin/sh` scripts against it
	# too, so a portability break is caught here instead of inside a VM.
	if [ "$interpreter" = "sh -n" ] && command -v dash >/dev/null 2>&1; then
		if ! dash -n "$file" 2>&1; then
			echo "LINT FAIL: $file (dash -n)"
			failures=$((failures + 1))
		fi
	fi
done

if command -v shellcheck >/dev/null 2>&1; then
	for file in $files; do
		[ -f "$file" ] || continue

		case "$file" in
			*.zsh | *.py) continue ;;
		esac

		case "$(head -1 "$file")" in
			'#!'*zsh) continue ;;
		esac

		if ! shellcheck -x "$file"; then
			echo "SHELLCHECK FAIL: $file"
			failures=$((failures + 1))
		fi
	done
else
	echo "lint: shellcheck not installed -- syntax check only"
fi

command -v dash >/dev/null 2>&1 || echo "lint: dash not installed -- POSIX portability of /bin/sh scripts unchecked"

echo "lint: checked $checked file(s), $failures failure(s)"
[ "$failures" -eq 0 ]
