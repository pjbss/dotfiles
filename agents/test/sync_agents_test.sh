#!/bin/bash
# sync_agents_test.sh
#
# Tests for bin/dotfiles-sync-agents -- the render engine that is the single
# delivery path for skills, subagents, hooks and settings, on the host and
# (because install.sh runs it in the guest too) inside every spawned sandbox.
# It had no tests at all before this, while being the one script whose failure
# mode is "an agent silently runs with the wrong instructions".
#
# Works against a synthetic dotfiles tree in a tmpdir rather than this repo:
# the script derives its source root from its own location, so copying it into
# a fake tree is what makes it possible to test deleting a skill (pruning)
# without deleting a real one. $HOME is redirected per run and never touched.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
DOTFILES_HOME="$(cd -P "$TEST_DIR/../.." && pwd)"

. "$DOTFILES_HOME/test/assert.sh"

fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

fake_dotfiles="$fixture_root/dotfiles"
fake_home="$fixture_root/home"

mkdir -p "$fake_dotfiles/bin" "$fake_dotfiles/agents/skills" "$fake_dotfiles/agents/claude-only/hooks" \
	"$fake_dotfiles/agents/claude-only/subagents" "$fake_dotfiles/agents/claude-only/commands" \
	"$fake_home/.claude"
cp "$DOTFILES_HOME/bin/dotfiles-sync-agents" "$fake_dotfiles/bin/"

write_skill() {
	mkdir -p "$fake_dotfiles/agents/skills/$1"
	printf -- '---\nname: %s\ndescription: A test skill.\ntags: [test]\n---\n\nBody.\n' "$1" \
		> "$fake_dotfiles/agents/skills/$1/SKILL.md"
}

run_sync() {
	if out="$(HOME="$fake_home" COPILOT_HOME="$fake_home/.copilot" \
		"$fake_dotfiles/bin/dotfiles-sync-agents" 2>&1)"; then
		rc=0
	else
		rc=$?
	fi
}

write_skill alpha
write_skill beta
printf -- '---\nname: a-subagent\ndescription: x\ntools: Read\n---\n\nBody.\n' \
	> "$fake_dotfiles/agents/claude-only/subagents/a-subagent.md"
printf '#!/bin/sh\nexit 0\n' > "$fake_dotfiles/agents/claude-only/hooks/a-hook.sh"
printf -- '---\ndescription: x\n---\n\nBody.\n' > "$fake_dotfiles/agents/claude-only/commands/a-command.md"
printf '{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "true"}]}]}}\n' \
	> "$fake_dotfiles/agents/claude-only/settings.json"

# A settings file with live user state, exactly as a real one would be.
printf '{"model": "opus[1m]", "tui": {"theme": "dark"}}\n' > "$fake_home/.claude/settings.json"

# --- first render ---

run_sync
assert_exit_code 0 "$rc" "a first sync succeeds"
assert_ok "a skill is rendered for Claude Code" test -f "$fake_home/.claude/skills/alpha/SKILL.md"
assert_ok "a skill is rendered for Copilot CLI" test -f "$fake_home/.copilot/skills/alpha/SKILL.md"
assert_ok "a subagent is rendered" test -f "$fake_home/.claude/agents/a-subagent.md"
assert_ok "a command is rendered" test -f "$fake_home/.claude/commands/a-command.md"
assert_ok "a hook script is rendered" test -f "$fake_home/.claude/hooks/a-hook.sh"
assert_ok "a rendered hook script is executable -- Claude Code execs it directly" test -x "$fake_home/.claude/hooks/a-hook.sh"

assert_contains "$(cat "$fake_home/.copilot/skills/alpha/SKILL.md")" "name: alpha" "the Copilot copy keeps name/description"
assert_not_contains "$(cat "$fake_home/.copilot/skills/alpha/SKILL.md")" "tags:" "the Copilot copy drops the tags field it has no equivalent for"

# --- the settings merge must not eat live user state ---

settings="$(cat "$fake_home/.claude/settings.json")"
assert_contains "$settings" '"model"' "merging hooks preserves an existing model setting"
assert_contains "$settings" '"theme"' "merging hooks preserves existing nested tui settings"
assert_contains "$settings" '"Stop"' "the managed hooks block is merged in"
assert_ok "the pre-existing settings file was backed up before being rewritten" \
	bash -c "ls '$fake_home/.claude/'settings.json.dotfiles-backup.* >/dev/null 2>&1"

# --- a second run is a no-op on settings ---

backups_before="$(ls "$fake_home/.claude/" | grep -c 'settings.json.dotfiles-backup' || true)"
run_sync
backups_after="$(ls "$fake_home/.claude/" | grep -c 'settings.json.dotfiles-backup' || true)"
assert_eq "$backups_before" "$backups_after" "re-running does not make a second backup when the hooks are already current"
assert_contains "$out" "already current" "re-running says the hooks are already current"

# --- pruning: a skill removed from the repo is removed from the render ---

rm -rf "$fake_dotfiles/agents/skills/beta"
run_sync
assert_not_ok "a skill deleted from the repo is pruned from ~/.claude/skills" test -d "$fake_home/.claude/skills/beta"
assert_not_ok "a skill deleted from the repo is pruned from the Copilot render too" test -d "$fake_home/.copilot/skills/beta"
assert_ok "the remaining skill is untouched by the prune" test -f "$fake_home/.claude/skills/alpha/SKILL.md"
assert_contains "$out" "pruned" "pruning says what it removed"

# --- pruning never touches what this script didn't write ---

mkdir -p "$fake_home/.claude/skills/hand-authored"
printf -- '---\nname: hand-authored\ndescription: not from dotfiles\n---\n' \
	> "$fake_home/.claude/skills/hand-authored/SKILL.md"
printf '#!/bin/sh\n' > "$fake_home/.claude/hooks/hand-authored-hook.sh"

run_sync
assert_ok "a hand-authored skill sitting alongside the managed ones survives a sync" \
	test -f "$fake_home/.claude/skills/hand-authored/SKILL.md"
assert_ok "a hand-authored hook survives a sync" test -f "$fake_home/.claude/hooks/hand-authored-hook.sh"

# --- pruning applies to subagents and hooks too (the old no-prune bug) ---

rm -f "$fake_dotfiles/agents/claude-only/subagents/a-subagent.md"
rm -f "$fake_dotfiles/agents/claude-only/hooks/a-hook.sh"
run_sync
assert_not_ok "a subagent deleted from the repo is pruned" test -f "$fake_home/.claude/agents/a-subagent.md"
assert_not_ok "a hook deleted from the repo is pruned" test -f "$fake_home/.claude/hooks/a-hook.sh"

# --- a hand-broken settings file is reported, not overwritten ---

printf '{ this is not json\n' > "$fake_home/.claude/settings.json"
printf '{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "changed"}]}]}}\n' \
	> "$fake_dotfiles/agents/claude-only/settings.json"

run_sync
assert_exit_code 1 "$rc" "a settings file that isn't valid JSON fails the sync rather than being silently replaced"
assert_contains "$out" "not valid JSON" "the failure says what's wrong"
assert_contains "$(cat "$fake_home/.claude/settings.json")" "this is not json" "the unparseable settings file is left exactly as found"

assert_report
