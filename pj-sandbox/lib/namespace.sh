# namespace.sh
#
# Every runtime namespace pj-sandbox claims on the host, in one place. Each is
# chosen so it can't collide with the old sandbox/ + pj-sbx-* tooling running
# side by side, and each can be overridden by an environment variable so tests
# never touch the real ones. Meant to be sourced, not executed.
#
# The sourcer must set PJ_SANDBOX_DOTFILES_HOME (the dotfiles checkout root)
# unless it sets PJ_SANDBOX_TEMPLATES_DIR itself: a sourced POSIX sh file has
# no portable way to find its own path.

# Lima instance names start with this, so `pj-sbx-*` (which slugs task names
# with no prefix at all) never matches one of these VMs.
PJ_SANDBOX_INSTANCE_PREFIX="${PJ_SANDBOX_INSTANCE_PREFIX:-pjsb-}"

# The old tools discover sandboxes through ~/.ssh/pj-sandbox-config.
PJ_SANDBOX_SSH_INCLUDE_FILE="${PJ_SANDBOX_SSH_INCLUDE_FILE:-$HOME/.ssh/pj-sandbox-next-config}"

# The user's own ssh config, which gets one Include line for the file above.
PJ_SANDBOX_SSH_CONFIG_FILE="${PJ_SANDBOX_SSH_CONFIG_FILE:-$HOME/.ssh/config}"

# ssh/forward ports. The old range is 60022-60099.
PJ_SANDBOX_PORT_MIN="${PJ_SANDBOX_PORT_MIN:-61022}"
PJ_SANDBOX_PORT_MAX="${PJ_SANDBOX_PORT_MAX:-61099}"

# Where each task's egress proxy listens: the host's address on Lima's
# socket_vmnet host-only network (the "host" network's gateway in
# $LIMA_HOME/_config/networks.yaml), the guest's only route off its own disk.
# Never a wildcard address (lib/proxy.sh refuses one).
PJ_SANDBOX_PROXY_HOST="${PJ_SANDBOX_PROXY_HOST:-192.168.106.1}"

PJ_SANDBOX_CONFIG_DIR="${PJ_SANDBOX_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/pj-sandbox}"

# Per-task state lives in $PJ_SANDBOX_STATE_DIR/<task>/.
PJ_SANDBOX_STATE_DIR="${PJ_SANDBOX_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/pj-sandbox}"

PJ_SANDBOX_TEMPLATES_DIR="${PJ_SANDBOX_TEMPLATES_DIR:-${PJ_SANDBOX_DOTFILES_HOME:?set PJ_SANDBOX_DOTFILES_HOME or PJ_SANDBOX_TEMPLATES_DIR before sourcing namespace.sh}/local/pj-sandbox/templates}"

# pj_sandbox_instance_name TASK_NAME
#
# A deterministic, Lima-valid instance name for a free-text task name: the
# prefix plus the task name lowercased, with each run of characters outside
# [a-z0-9] collapsed to one '-' and leading/trailing '-' trimmed. Lima names
# must match ^[A-Za-z0-9]+(?:[._-][A-Za-z0-9]+)*$. Copied from
# sandbox_instance_name in sandbox/lib/task.sh rather than sourced, so the two
# can change independently.
pj_sandbox_instance_name() {
	slug="$(printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"

	if [ -z "$slug" ]; then
		slug="sandbox-task"
	fi

	echo "$PJ_SANDBOX_INSTANCE_PREFIX$slug"
}
