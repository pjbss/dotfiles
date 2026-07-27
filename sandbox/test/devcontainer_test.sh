#!/bin/bash
# devcontainer_test.sh
#
# Plain-shell unit tests for sandbox/lib/devcontainer.sh (devcontainer.json
# discovery for `pj-sandbox-spawn`, issue 008). No test framework
# dependency, same minimal assert style as task_test.sh/list_test.sh.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"

. "$SANDBOX_DIR/lib/devcontainer.sh"

failures=0

assert_eq() {
	expected="$1"
	actual="$2"
	message="$3"

	if [ "$expected" != "$actual" ]; then
		echo "FAIL: $message (expected '$expected', got '$actual')"
		failures=$((failures + 1))
	else
		echo "PASS: $message"
	fi
}

fixture_root="$(mktemp -d)"

# --- no devcontainer.json anywhere ---

if sandbox_devcontainer_config_path "$fixture_root" >/dev/null; then
	echo "FAIL: sandbox_devcontainer_config_path fails when no devcontainer.json exists"
	failures=$((failures + 1))
else
	echo "PASS: sandbox_devcontainer_config_path fails when no devcontainer.json exists"
fi

# --- .devcontainer/devcontainer.json ---

mkdir -p "$fixture_root/.devcontainer"
echo '{}' > "$fixture_root/.devcontainer/devcontainer.json"

assert_eq "$fixture_root/.devcontainer/devcontainer.json" "$(sandbox_devcontainer_config_path "$fixture_root")" \
	"sandbox_devcontainer_config_path finds .devcontainer/devcontainer.json"

rm -rf "$fixture_root/.devcontainer"

# --- .devcontainer.json at project root ---

echo '{}' > "$fixture_root/.devcontainer.json"

assert_eq "$fixture_root/.devcontainer.json" "$(sandbox_devcontainer_config_path "$fixture_root")" \
	"sandbox_devcontainer_config_path finds .devcontainer.json at the project root"

# --- both present: .devcontainer/devcontainer.json takes priority ---

mkdir -p "$fixture_root/.devcontainer"
echo '{}' > "$fixture_root/.devcontainer/devcontainer.json"

assert_eq "$fixture_root/.devcontainer/devcontainer.json" "$(sandbox_devcontainer_config_path "$fixture_root")" \
	"sandbox_devcontainer_config_path prefers .devcontainer/devcontainer.json over .devcontainer.json"

rm -rf "$fixture_root"

echo "$failures failure(s)"
[ "$failures" -eq 0 ]
