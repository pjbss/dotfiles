#!/bin/bash
# proxy_policy_test.sh
#
# Runs the egress policy's Python unit tests (pj-sandbox/proxy/test_*.py,
# stdlib unittest) so they sit inside the `make test` contract like every
# other suite. The proxy is the only part of pj-sandbox written in Python, so
# a machine without python3 skips here with a clear message rather than
# failing the whole run. No bytecode is written, so the tree stays clean.

set -euo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROXY_DIR="$(cd -P "$TEST_DIR/../proxy" && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
	echo "SKIP: python3 not found; the proxy policy tests need it"
	exit 0
fi

cd "$PROXY_DIR"
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s . -p 'test_*.py' -v
