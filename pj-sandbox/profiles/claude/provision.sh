#!/bin/sh
# claude profile: install Claude Code as an npm global (node comes from
# lima/core-provision.yaml). Run as root at provision time; {{.User}} is
# filled in by Lima.
#
# The npm prefix is handed to the guest user afterwards: the CLI runs as that
# user, and its own auto-updater rewrites files under the prefix, which fails
# with npm's no_permissions while root owns it. A sandbox has one guest user,
# so this costs nothing.
set -eux
if ! command -v claude >/dev/null 2>&1; then
  npm install -g @anthropic-ai/claude-code
fi
npm_prefix="$(npm config get prefix)"
chown -R {{.User}}:"$(id -gn {{.User}})" "$npm_prefix/lib/node_modules" "$npm_prefix/bin" 2>/dev/null || true
