# color.sh
#
# Minimal ANSI color-code variables for pj-sbx-spawn's user-facing usage/
# error output, so a missing/invalid argument reads more like a small
# formatted message than a single dense line. Meant to be sourced, not
# executed directly.

# sandbox_color_supported
#
# Returns 0 if ANSI color output should be used: both stdout and stderr
# are attached to a real terminal, and $NO_COLOR (https://no-color.org) is
# unset/empty. Requiring *both* streams to be terminals (rather than just
# whichever one a given message happens to print to) keeps color from
# leaking into one stream when the other is redirected/captured (e.g. this
# repo's own tests, which capture a spawned script's combined `2>&1`
# output via command substitution -- never a real terminal, so this is
# always false there, regardless of $NO_COLOR).
#
# Split out as its own function, rather than inlined into
# sandbox_color_init below, so tests can override it (the same
# shell-function-shadowing trick task_test.sh already uses for `limactl`)
# without needing a real attached terminal.
sandbox_color_supported() {
	[ -z "${NO_COLOR:-}" ] && [ -t 1 ] && [ -t 2 ]
}

# sandbox_color_init
#
# Sets C_BOLD/C_RED/C_CYAN/C_YELLOW/C_RESET to real ANSI escape sequences
# if sandbox_color_supported, or to empty strings otherwise -- so callers
# can unconditionally wrap text in "${C_RED}...${C_RESET}" and get either a
# colored or a plain result, with no branching of their own. Called once,
# at the bottom of this file, when sourced normally; callable again after
# a test shadows sandbox_color_supported to force either branch.
sandbox_color_init() {
	if sandbox_color_supported; then
		C_BOLD="$(printf '\033[1m')"
		C_RED="$(printf '\033[31m')"
		C_CYAN="$(printf '\033[36m')"
		C_YELLOW="$(printf '\033[33m')"
		C_RESET="$(printf '\033[0m')"
	else
		C_BOLD=""
		C_RED=""
		C_CYAN=""
		C_YELLOW=""
		C_RESET=""
	fi
}

sandbox_color_init
