#!/bin/sh
# gh profile: run as the guest user after the bootstrap.
#
# Points git's github.com credential helper at $GH_TOKEN, which the guest's
# login file sets to the gh placeholder; the host proxy swaps the real token
# in. The variable is read each time git asks, never copied into the config,
# so with --no-creds (no GH_TOKEN) git gets no password at all. The empty
# helper first clears any helper inherited from the dotfiles' git config.
set -eu
git config --global --replace-all credential.https://github.com.helper ''
git config --global --add credential.https://github.com.helper \
	'!f() { if [ "$1" = get ] && [ -n "${GH_TOKEN:-}" ]; then printf "username=x-access-token\npassword=%s\n" "$GH_TOKEN"; fi; }; f'
