#!/bin/bash
# gh_stack_provision_test.sh
#
# Tests that every sandbox VM gets the gh-stack extension, pinned, so
# pj-run-issues' stack mode can run where the loop actually runs. Without it
# the loop could only ever refuse a stacked issue inside the documented flow.
#
# The extension installs per user (under ~/.local/share/gh/extensions), so it
# needs a `mode: user` provision step rather than the existing system one. It
# has to work in a --no-creds VM, where there are no gh credentials at all,
# and it must not read them in a VM that has them. Its version is pinned in
# one place: the stub gh the stack-mode tests run against
# (agents/test/stubs/gh) encodes that version's behaviour.
#
# The step's behaviour is tested by running the script itself, extracted from
# the rendered config, against a recording `gh` -- checking for strings in
# the script couldn't tell a wrapped gh call from an unwrapped one.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"
DOTFILES_HOME="$(cd -P "$SANDBOX_DIR/.." && pwd)"

. "$DOTFILES_HOME/test/assert.sh"
. "$SANDBOX_DIR/lib/task.sh"

template="$SANDBOX_DIR/lima-template.yaml"

fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

# user_steps RENDERED -- the body of every `mode: user` provision item
# (its `script: |` line and the indented script under it).
user_steps() {
	printf '%s\n' "$1" | awk '
		/^- mode: / { in_user = ($0 == "- mode: user"); next }
		/^[^ ]/ { in_user = 0 }
		in_user { print }
	'
}

with_creds="$(sandbox_render_lima_config "$template" 60022 /wt "" /df /gd "" "" "" "" yes)"
without_creds="$(sandbox_render_lima_config "$template" 60022 /wt "" /df /gd "" "" "" "" no)"

# --- present in every rendering ---

for variant in with_creds without_creds; do
	assert_contains "$(user_steps "${!variant}")" "gh extension install github/gh-stack --pin" \
		"the rendered config ($variant) installs gh-stack in a mode: user step"
done
assert_eq "1" "$(grep -c '0\.3\.0' "$template")" "the pinned version appears exactly once in the template"

# --- what the step actually does ---

script="$fixture_root/step.sh"
user_steps "$with_creds" | sed '/^  script: |$/d; s/^    //' > "$script"

# A recording gh: logs every call with the tokens and config dir it saw,
# reports gh-stack $STUB_V for `stack --version`, and succeeds otherwise.
stub_bin="$fixture_root/bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/gh" <<'STUB'
#!/bin/sh
printf '%s|token=%s|github_token=%s|config=%s\n' "$*" "${GH_TOKEN-unset}" "${GITHUB_TOKEN-unset}" "${GH_CONFIG_DIR-unset}" >> "$GH_LOG"
[ "$*" = "stack --version" ] && echo "gh stack version $STUB_V"
exit 0
STUB
chmod +x "$stub_bin/gh"

# run_step INSTALLED_VERSION -- runs the step as the VM would, with tokens in
# the environment and a home whose gh config holds credentials. Sets $rc,
# $log (one line per gh call) and $home_config.
run_step() {
	local home="$fixture_root/home-$1"
	mkdir -p "$home/.config/gh"
	printf 'github.com:\n    oauth_token: SECRET\n' > "$home/.config/gh/hosts.yml"
	log="$fixture_root/gh-$1.log"
	: > "$log"
	if (cd "$home" && HOME="$home" PATH="$stub_bin:$PATH" GH_TOKEN=SECRET GITHUB_TOKEN=SECRET \
		GH_LOG="$log" STUB_V="$1" sh "$script") >/dev/null 2>&1; then rc=0; else rc=$?; fi
	home_config="$home/.config/gh"
}

# no_credentials_used LABEL -- every logged gh call ran with both token
# variables unset and an explicit config dir that isn't the home's.
no_credentials_used() {
	assert_eq "" "$(grep -v '|token=unset|github_token=unset|' "$log" || true)" \
		"every gh call ($1) runs with GH_TOKEN and GITHUB_TOKEN unset"
	assert_eq "" "$(grep -e '|config=unset$' -e "|config=$home_config\$" "$log" || true)" \
		"every gh call ($1) runs against an explicit config dir, never ~/.config/gh"
}

run_step 0.2.0
assert_exit_code 0 "$rc" "the step succeeds when an older gh-stack is installed"
assert_eq "1" "$(grep -c '^extension install github/gh-stack --pin v0.3.0|' "$log" || true)" \
	"it installs the pinned v0.3.0, exactly once"
no_credentials_used "older version installed"

run_step 0.3.0
assert_exit_code 0 "$rc" "the step succeeds when the pinned version is already installed"
assert_contains "$(cat "$log")" "stack --version|" "it checks the installed version"
assert_eq "0" "$(grep -c '^extension' "$log" || true)" "and touches no extension then: a re-boot is a cheap no-op"
no_credentials_used "pinned version installed"

assert_report
