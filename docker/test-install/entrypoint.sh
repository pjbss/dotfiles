#!/bin/sh
# Copies the read-only bind-mounted repo into the sandbox user's own $HOME,
# runs install.sh twice (to exercise idempotency), then drops into an
# interactive shell so the result can be inspected by hand -- all inside a
# throwaway container, never touching the real machine's home directory.
set -e

if [ ! -d /dotfiles-src ]; then
	echo "dotfiles-test-entrypoint: expected the repo bind-mounted read-only at /dotfiles-src" >&2
	exit 1
fi

cp -R /dotfiles-src /home/tester/dotfiles
chown -R tester:tester /home/tester/dotfiles

exec su - tester -c '
	set -e
	cd ~/dotfiles

	echo "=== install.sh (1st run) ==="
	./install.sh
	echo

	echo "=== install.sh (2nd run, confirming idempotency) ==="
	./install.sh
	echo

	echo "Sandbox \$HOME is $HOME -- this is NOT your real home directory."
	echo "Inspect ~/.zshrc, ~/.gitconfig, ~/.vimrc, prompt segments, etc, then exit when done."
	exec zsh
'
