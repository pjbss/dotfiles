#!/bin/bash
# bootstrap_test.sh
#
# Tests for the guest bootstrap `pj-sandbox spawn` runs once the VM is up: the
# dotfiles reach the guest as a `git archive` streamed over ssh stdin (never a
# mount), and the bootstrap script installs them, writes the /etc/pj-sandbox
# marker and adds the guarded zsh handoff to the login file.
#
# The dotfiles are a temp repo (PJ_SANDBOX_DOTFILES_HOME) with a gitignored
# local/secret and a fake install.sh. A stub `ssh` records each call and runs
# its remote command under `sh -c` against a temp "guest" home, so the
# bootstrap really runs. The guest's `sudo`, `zsh` and `apt-get` are stubs.
# The bootstrap also installs the proxy CA's certificate, and only that, into
# the guest's trust store; the CA itself is made by spawn in the temp HOME.

set -euo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PJ_SANDBOX_DIR="$(cd -P "$TEST_DIR/.." && pwd)"
. "$TEST_DIR/../../test/assert.sh"
. "$TEST_DIR/stub_proxy.sh"

CLI="$PJ_SANDBOX_DIR/bin/pj-sandbox"

fixture="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "$fixture"' EXIT

unset PJ_SANDBOX_STATE_DIR PJ_SANDBOX_SSH_INCLUDE_FILE PJ_SANDBOX_SSH_CONFIG_FILE \
	PJ_SANDBOX_PORT_MIN PJ_SANDBOX_PORT_MAX PJ_SANDBOX_INSTANCE_PREFIX \
	XDG_STATE_HOME XDG_CONFIG_HOME GIT_CONFIG_GLOBAL GIT_DIR GIT_WORK_TREE \
	PJSANDBOX_ZSH_HANDED_OFF
export HOME="$fixture/home"
export STUB_DIR="$fixture/stub"
export GUEST_ROOT="$fixture/guest"
export GUEST_BIN="$fixture/guest-bin"
STATE_DIR="$HOME/.local/state/pj-sandbox"
mkdir -p "$HOME/.ssh" "$fixture/bin" "$GUEST_BIN" "$STUB_DIR" "$GUEST_ROOT/home" "$GUEST_ROOT/etc"
git config --global user.name tester
git config --global user.email tester@example.com
git config --global init.defaultBranch main

cat > "$fixture/bin/limactl" <<'STUB'
#!/bin/sh
case "$1" in
	start)
		for last in "$@"; do :; done
		cp "$last" "$STUB_DIR/rendered.yaml"
		;;
	ls)
		for name in "$@"; do :; done
		printf 'Host lima-%s\n  Hostname 127.0.0.1\n  Port 61022\n' "$name" > "$STUB_DIR/$name.ssh.config"
		echo "$STUB_DIR/$name.ssh.config"
		;;
	copy) ;;
	shell) cat > /dev/null ;;
	*) exit 3 ;;
esac
STUB

# ssh -F CONFIG HOST CMD...: records its argv and stdin (one numbered file of
# each per call), then runs CMD in the guest home.
cat > "$fixture/bin/ssh" <<'STUB'
#!/bin/bash
n=$(( $(ls "$STUB_DIR" | grep -c '^ssh-argv\.' || true) + 1 ))
printf '%s\n' "$@" > "$STUB_DIR/ssh-argv.$n"
[ "$1" = -F ] && shift 2
shift # host
tee "$STUB_DIR/ssh-stdin.$n" | HOME="$GUEST_ROOT/home" PATH="$GUEST_BIN:$PATH" sh -c "$*"
STUB

# The guest's sudo: `tee [-a] FILE` (making FILE's dir) and `mkdir -p DIR`
# land under GUEST_ROOT, anything else is only recorded.
cat > "$GUEST_BIN/sudo" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_DIR/sudo-calls"
case "$1" in
	tee)
		if [ "$2" = -a ]; then
			mkdir -p "$(dirname "$GUEST_ROOT$3")" && cat >> "$GUEST_ROOT$3"
		else
			mkdir -p "$(dirname "$GUEST_ROOT$2")" && cat > "$GUEST_ROOT$2"
		fi
		;;
	mkdir) mkdir -p "$GUEST_ROOT$3" ;;
esac
STUB
cat > "$GUEST_BIN/zsh" <<'STUB'
#!/bin/sh
echo "ZSH-HANDOFF $*"
STUB
chmod +x "$fixture/bin/"* "$GUEST_BIN/"*
# spawn starts the task's proxy; a stub stands in for mitmdump.
pj_test_stub_proxy "$fixture/bin"
export PJ_SANDBOX_PROXY_SETTLE=0
export PATH="$fixture/bin:$PATH"

# The dotfiles: one tracked file, a fake installer, and a gitignored secret.
dotfiles="$fixture/dotfiles"
git init -q "$dotfiles"
printf 'local/\n' > "$dotfiles/.gitignore"
printf 'tracked\n' > "$dotfiles/tracked.txt"
cat > "$dotfiles/install.sh" <<'SH'
#!/bin/sh
printf 'guest=%s\n' "${DOTFILES_SANDBOX_GUEST:-}" > "$HOME/install-ran"
SH
chmod +x "$dotfiles/install.sh"
git -C "$dotfiles" add .gitignore tracked.txt install.sh
git -C "$dotfiles" commit -q -m dotfiles
mkdir -p "$dotfiles/local"
printf 'hunter2\n' > "$dotfiles/local/secret"
export PJ_SANDBOX_DOTFILES_HOME="$dotfiles"

repo="$fixture/repo"
git init -q "$repo"
git -C "$repo" commit -q --allow-empty -m first

spawn() {
	(cd "$repo" && "$CLI" spawn "$@")
}

# --- a spawn streams the dotfiles archive to the guest ---

if out="$(spawn boot --base none 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 0 "$rc" "spawn exits 0 (output: $out)"

archive="$(grep -lxF 'mkdir -p "$HOME/dotfiles" && tar -xf - -C "$HOME/dotfiles"' "$STUB_DIR"/ssh-argv.* 2>/dev/null | head -1 || true)"
assert_ok "one ssh call extracts a tar stream into ~/dotfiles" test -n "$archive"
entries="$(tar -tf "${archive/ssh-argv/ssh-stdin}" < /dev/null 2>/dev/null || true)"
assert_contains "$entries" "tracked.txt" "the streamed archive has the tracked files"
assert_not_contains "$entries" "local/" "the streamed archive has no local/ entries"
assert_ok "the guest's ~/dotfiles has the tracked files" test -f "$GUEST_ROOT/home/dotfiles/tracked.txt"
assert_not_ok "the guest's ~/dotfiles has no local/" test -e "$GUEST_ROOT/home/dotfiles/local"

# --- the bootstrap script runs over ssh stdin, with fixed argv ---

script_call="$(grep -lx 'sh -s' "$STUB_DIR"/ssh-argv.* 2>/dev/null | head -1 || true)"
assert_ok "one ssh call runs the bootstrap as 'sh -s'" test -n "$script_call"
assert_eq "$(printf '%s\n' -F "$HOME/.ssh/pj-sandbox-next-config" pjsb-boot 'sh -s')" "$(cat "$script_call" 2>/dev/null || true)" \
	"the bootstrap's ssh argv carries no values, only the Host entry and 'sh -s'"
script="$(cat "${script_call/ssh-argv/ssh-stdin}" 2>/dev/null || true)"

# --- what the bootstrap does in the guest ---

assert_eq "guest=1" "$(cat "$GUEST_ROOT/home/install-ran" 2>/dev/null || true)" "the dotfiles installer runs with DOTFILES_SANDBOX_GUEST=1"
assert_contains "$(cat "$STUB_DIR/sudo-calls" 2>/dev/null || true)" "chsh -s $GUEST_BIN/zsh" "the guest user's login shell is changed to zsh"
assert_ok "the bootstrap writes /etc/pj-sandbox" test -f "$GUEST_ROOT/etc/pj-sandbox"
assert_contains "$script" "/etc/pj-sandbox" "the bootstrap script names /etc/pj-sandbox"

profile="$GUEST_ROOT/home/.profile"
assert_contains "$script" 'PJSANDBOX_ZSH_HANDED_OFF' "the bootstrap script's zsh handoff names the PJSANDBOX_ZSH_HANDED_OFF marker"
assert_contains "$(cat "$profile" 2>/dev/null || true)" '[ -z "$PJSANDBOX_ZSH_HANDED_OFF" ]' "the login file's handoff is guarded by PJSANDBOX_ZSH_HANDED_OFF"
assert_contains "$(cat "$profile" 2>/dev/null || true)" 'export PJSANDBOX_ZSH_HANDED_OFF=1' "the handoff exports the marker for every descendant"

# Sourcing the login file the way a fresh login would, and the way Claude
# Code's Bash tool does from inside that login (marker inherited).
login_out="$(env -u ZSH_VERSION -u PJSANDBOX_ZSH_HANDED_OFF PATH="$GUEST_BIN:$PATH" sh -c '. "$1"; echo NO-HANDOFF' sh "$profile" 2>&1 || true)"
assert_contains "$login_out" "ZSH-HANDOFF -l" "a top-level login hands off to 'zsh -l'"
assert_not_contains "$login_out" "NO-HANDOFF" "the handoff is an exec"
child_out="$(env -u ZSH_VERSION PJSANDBOX_ZSH_HANDED_OFF=1 PATH="$GUEST_BIN:$PATH" sh -c '. "$1"; echo NO-HANDOFF' sh "$profile" 2>&1 || true)"
assert_eq "NO-HANDOFF" "$child_out" "a shell that inherited the marker doesn't hand off again"

# --- the bootstrap points the guest at the task's proxy ---

proxy_port="$(sed -n 's/^proxy_port=//p' "$HOME/.local/state/pj-sandbox/boot/meta")"
proxy_profile="$GUEST_ROOT/etc/profile.d/pjsb-proxy.sh"
assert_ok "the guest gets /etc/profile.d/pjsb-proxy.sh" test -f "$proxy_profile"
assert_eq "http://192.168.106.1:$proxy_port|http://192.168.106.1:$proxy_port|localhost,127.0.0.1,::1|" \
	"$(env -i sh -c '. "$1"; printf "%s|%s|%s|%s" "$HTTPS_PROXY" "$http_proxy" "$NO_PROXY" "${PJSB_PROXY:-}"' sh "$proxy_profile")" \
	"a login shell sourcing it gets the task's proxy, and no leftover helper variables"
assert_contains "$(cat "$GUEST_ROOT/etc/environment" 2>/dev/null || true)" "HTTPS_PROXY=http://192.168.106.1:$proxy_port" \
	"/etc/environment carries the proxy for PAM sessions"
assert_contains "$(cat "$GUEST_ROOT/etc/apt/apt.conf.d/95pjsb-proxy" 2>/dev/null || true)" \
	"Acquire::https::Proxy \"http://192.168.106.1:$proxy_port\";" "apt goes through the proxy"
assert_contains "$(cat "$STUB_DIR/sudo-calls")" "systemctl enable --now pjsb-egress-lockdown.service" "the lockdown unit is enabled"

# --- the bootstrap trusts the proxy CA's certificate, never its key ---

ca_dir="$HOME/.config/pj-sandbox/ca"
guest_ca="$GUEST_ROOT/usr/local/share/ca-certificates/pjsb.crt"
assert_ok "spawn made the per-install CA" test -s "$ca_dir/ca.pem"
assert_contains "$script" "$(cat "$ca_dir/ca.pem" 2>/dev/null || echo NO-CA)" "the bootstrap script carries ca.pem's content"
key_body="$(grep -v -e '^-----' "$ca_dir/ca-key.pem" 2>/dev/null || true)"
assert_ok "the CA key has a body to look for" test -n "$key_body"
while IFS= read -r key_line; do
	[ -n "$key_line" ] || continue
	case "$script" in
		*"$key_line"*)
			assert_ok "the bootstrap script has no line of ca-key.pem" false
			break
			;;
	esac
done <<< "$key_body"
assert_not_contains "$script" "PRIVATE KEY" "the bootstrap script has no private key"
assert_eq "$(cat "$ca_dir/ca.pem" 2>/dev/null || echo NO-CA)" "$(cat "$guest_ca" 2>/dev/null || true)" \
	"the guest's /usr/local/share/ca-certificates/pjsb.crt is ca.pem"
assert_contains "$(cat "$STUB_DIR/sudo-calls" 2>/dev/null || true)" "update-ca-certificates" "the bootstrap runs update-ca-certificates"

# Handed the key, or a cert with a key appended, the script builder refuses
# rather than put either in the guest.
cat "$ca_dir/ca.pem" "$ca_dir/ca-key.pem" > "$fixture/cert-and-key.pem" 2>/dev/null || true
for bad in "$ca_dir/ca-key.pem" "$fixture/cert-and-key.pem" "$ca_dir/mitmproxy-ca.pem"; do
	if bad_out="$(. "$PJ_SANDBOX_DIR/lib/bootstrap.sh" && pj_sandbox_bootstrap_script "$bad" 2>&1)"; then rc=0; else rc=$?; fi
	assert_exit_code 1 "$rc" "the bootstrap script builder refuses $(basename "$bad")"
	assert_not_contains "$bad_out" "PRIVATE KEY" "refusing $(basename "$bad") prints no key"
done

for token in 'export GH_TOKEN' GITHUB_TOKEN CLAUDE_CODE_OAUTH_TOKEN; do
	assert_not_contains "$script" "$token" "the bootstrap script has no $token line"
done

# Running it again (by hand, say) adds no second handoff.
printf '%s\n' "$script" | HOME="$GUEST_ROOT/home" PATH="$GUEST_BIN:$PATH" sh -s >/dev/null 2>&1
assert_eq "1" "$(grep -c 'exec zsh -l' "$profile" 2>/dev/null || true)" "a second bootstrap run adds no second handoff"

# --- the bootstrap passes the guest-dash lint ---

printf '%s\n' "$script" > "$fixture/bootstrap.sh"
assert_ok "the bootstrap script parses under sh -n" sh -n "$fixture/bootstrap.sh"
if command -v dash >/dev/null 2>&1; then
	assert_ok "the bootstrap script parses under dash -n" dash -n "$fixture/bootstrap.sh"
fi
if command -v shellcheck >/dev/null 2>&1; then
	assert_ok "the bootstrap script passes shellcheck as sh" shellcheck -s sh "$fixture/bootstrap.sh"
fi

# --- still nothing mounted ---

rendered="$(cat "$STUB_DIR/rendered.yaml")"
assert_eq "1" "$(printf '%s\n' "$rendered" | grep -c '^mounts: \[\]$')" "the rendered Lima config still has 'mounts: []'"
assert_eq "" "$(printf '%s\n' "$rendered" | grep 'location:' || true)" "the rendered Lima config mounts nothing, dotfiles included"

# --- a failed bootstrap fails the spawn, and leaves no record ---

git -C "$dotfiles" rm -q tracked.txt install.sh
git -C "$dotfiles" commit -q -m "no installer"
rm -rf "$GUEST_ROOT/home/dotfiles"
if out="$(spawn broken --base none 2>&1)"; then rc=0; else rc=$?; fi
assert_exit_code 1 "$rc" "spawn exits 1 when the bootstrap fails"
assert_contains "$out" "bootstrap" "the failure says the bootstrap failed"
assert_not_ok "a failed bootstrap writes no state record" test -e "$STATE_DIR/broken/meta"

assert_report
