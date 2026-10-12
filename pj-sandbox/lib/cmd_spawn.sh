# cmd_spawn.sh
#
# pj-sandbox spawn <task> --base <name> [--agent <name>[,<name>...]] [--ports <guest>[,<guest>...]] [--from <ref>] [--egress deny|observe|open]
# pj-sandbox spawn --base list | --help
#
# Run inside a git repo. Makes or reuses the host branch TASK (a new one
# starts from --from, else refs/sandbox/TASK/TASK, else HEAD), bundles it,
# and boots a pjsb- Lima VM for TASK from lima/template.yaml with no host
# directories mounted. The bundle is copied in and cloned to /workspace on
# the guest's own disk (lib/git_transport.sh). Then it writes the VM's ssh
# Host entry, copies in and installs the dotfiles (lib/bootstrap.sh), and
# writes its state record. The bootstrap also installs the per-install proxy
# CA's certificate (lib/ca.sh), which spawn makes the first time it's needed. The record is written last, so a task only exists
# once its VM is up, cloned and bootstrapped.
# --base names a template from templates/ or local/pj-sandbox/templates/
# (lib/base_template.sh); its provisioning and copied-in files are rendered
# into the Lima config, and one that asks for host mounts is refused.
# --agent picks agent profiles from profiles/ (lib/profiles.sh), every one by
# default. The core provision step (lima/core-provision.yaml) and each chosen
# profile's provision.sh are rendered ahead of the base template, their
# allowlists and inject rules are merged into <state dir>/<task>/policy/ for
# the proxy, and their post-bootstrap.sh scripts run after the bootstrap. A
# directory template's `allowlist` and the repo's
# <git common dir>/pj-sandbox/allowlist are merged in after the profiles'.
# Once the VM is up, spawn starts the task's egress proxy (lib/proxy.sh) in
# --egress mode (default deny) on the host-only network that is the guest's
# only route, and the bootstrap points the guest at it and closes the rest
# (pj-sandbox/docs/spike-egress.md, "Findings"). The proxy's PID, port and
# mode go in the state record, and a failure after it starts stops it.

. "$PJ_SANDBOX_HOME/lib/namespace.sh"
. "$PJ_SANDBOX_HOME/lib/state.sh"
. "$PJ_SANDBOX_HOME/lib/ports.sh"
. "$PJ_SANDBOX_HOME/lib/render.sh"
. "$PJ_SANDBOX_HOME/lib/ssh_config.sh"
. "$PJ_SANDBOX_HOME/lib/git_transport.sh"
. "$PJ_SANDBOX_HOME/lib/bootstrap.sh"
. "$PJ_SANDBOX_HOME/lib/base_template.sh"
. "$PJ_SANDBOX_HOME/lib/profiles.sh"
. "$PJ_SANDBOX_HOME/lib/ca.sh"
. "$PJ_SANDBOX_HOME/lib/tokens.sh"
. "$PJ_SANDBOX_HOME/lib/proxy.sh"

# Where the bundle lands in the guest, and where it's cloned to.
PJ_SANDBOX_GUEST_WORKSPACE=/workspace

# The built-in --base templates. Local ones, which win a name collision, are
# in PJ_SANDBOX_TEMPLATES_DIR (lib/namespace.sh).
PJ_SANDBOX_BUILTIN_TEMPLATES_DIR="$PJ_SANDBOX_HOME/templates"

PJ_SANDBOX_PROFILES_DIR="$PJ_SANDBOX_HOME/profiles"

_pj_sandbox_spawn_usage() {
	echo "Usage: pj-sandbox spawn <task> --base <name> [--agent <name>[,<name>...]] [--ports <guest>[,<guest>...]] [--from <ref>] [--egress deny|observe|open]" >&2
}

_pj_sandbox_spawn_names_block() {
	pj_sandbox_base_template_names_block "$PJ_SANDBOX_BUILTIN_TEMPLATES_DIR" "$PJ_SANDBOX_TEMPLATES_DIR"
}

_pj_sandbox_spawn_help() {
	_pj_sandbox_spawn_usage 2>&1
	_pj_sandbox_spawn_names_block
	pj_sandbox_profile_names_block "$PJ_SANDBOX_PROFILES_DIR"
}

# _pj_sandbox_valid_ports CSV
#
# True if CSV is one or more comma-separated port numbers, 1-65535.
_pj_sandbox_valid_ports() {
	case "$1" in
		"" | ,* | *, | *,,*) return 1 ;;
	esac
	for port in $(printf '%s\n' "$1" | tr ',' ' '); do
		case "$port" in
			*[!0-9]*) return 1 ;;
		esac
		[ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
	done
}

# _pj_sandbox_spawn_drop_bundle
#
# Removes spawn's host bundle, and the task's state dir if that leaves it
# empty (it has no meta until spawn's last step).
_pj_sandbox_spawn_drop_bundle() {
	rm -f "$bundle"
	rmdir "$PJ_SANDBOX_STATE_DIR/$task" 2>/dev/null || true
}

# _pj_sandbox_spawn_abort
#
# Undoes spawn's host-side work after a failure before the VM is cloned:
# the proxy, if it was started, the bundle, the merged policy and the
# proxy's logs, and the state dir they leave empty.
_pj_sandbox_spawn_abort() {
	_pj_sandbox_spawn_stop_proxy
	rm -rf "$PJ_SANDBOX_STATE_DIR/$task/policy"
	rm -f "$PJ_SANDBOX_STATE_DIR/$task/egress.log" "$PJ_SANDBOX_STATE_DIR/$task/proxy.log"
	_pj_sandbox_spawn_drop_bundle
}

# _pj_sandbox_spawn_stop_proxy
#
# Stops the proxy this spawn started, if any. With no record written yet,
# nothing else would ever find it.
_pj_sandbox_spawn_stop_proxy() {
	pj_sandbox_proxy_kill "$proxy_pid" "$PJ_SANDBOX_STATE_DIR/$task/policy"
	proxy_pid=""
}

cmd_spawn() {
	task=""
	have_task=no
	base=""
	guest_ports=""
	from=""
	egress_mode=deny
	agents_csv="$(pj_sandbox_profile_names "$PJ_SANDBOX_PROFILES_DIR" | paste -sd , -)"
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--base | --ports | --from | --agent | --egress)
				if [ "$#" -lt 2 ]; then
					_pj_sandbox_spawn_usage
					return 1
				fi
				case "$1" in
					--base) base="$2" ;;
					--ports) guest_ports="$2" ;;
					--from) from="$2" ;;
					--agent) agents_csv="$2" ;;
					--egress) egress_mode="$2" ;;
				esac
				shift 2
				;;
			--help | -h)
				_pj_sandbox_spawn_help
				return 0
				;;
			-*)
				echo "pj-sandbox: spawn: unknown option '$1'" >&2
				_pj_sandbox_spawn_usage
				return 1
				;;
			*)
				if [ "$have_task" = yes ]; then
					_pj_sandbox_spawn_usage
					return 1
				fi
				task="$1"
				have_task=yes
				shift
				;;
		esac
	done

	if [ "$base" = list ]; then
		pj_sandbox_base_template_list "$PJ_SANDBOX_BUILTIN_TEMPLATES_DIR" "$PJ_SANDBOX_TEMPLATES_DIR"
		return 0
	fi
	if [ "$have_task" = no ] || [ -z "$base" ]; then
		_pj_sandbox_spawn_usage
		return 1
	fi
	if ! template="$(pj_sandbox_base_template_path "$PJ_SANDBOX_BUILTIN_TEMPLATES_DIR" "$PJ_SANDBOX_TEMPLATES_DIR" "$base")"; then
		echo "pj-sandbox: spawn: unknown base '$base'" >&2
		_pj_sandbox_spawn_names_block >&2
		return 1
	fi
	template_mounts="$(pj_sandbox_base_template_mounts_path "$template")"
	if [ -n "$template_mounts" ]; then
		echo "pj-sandbox: spawn: base '$base' has $template_mounts, but pj-sandbox allows no host mounts (list host files in the template's 'files' manifest to copy them in instead)" >&2
		return 1
	fi
	if [ -n "$guest_ports" ] && ! _pj_sandbox_valid_ports "$guest_ports"; then
		echo "pj-sandbox: spawn: --ports takes comma-separated port numbers (1-65535), got '$guest_ports'" >&2
		return 1
	fi
	case "$egress_mode" in
		deny | observe | open) ;;
		*)
			echo "pj-sandbox: spawn: --egress takes deny, observe or open, got '$egress_mode'" >&2
			return 1
			;;
	esac
	pj_sandbox_proxy_valid_host "$PJ_SANDBOX_PROXY_HOST" || return 1
	agents="$(pj_sandbox_profiles_resolve "$PJ_SANDBOX_PROFILES_DIR" "$agents_csv")" || return 1
	pj_sandbox_state_valid_task "$task" || return 1
	pj_sandbox_git_valid_branch "$task" || return 1

	if pj_sandbox_state_exists "$task"; then
		echo "pj-sandbox: spawn: task '$task' already exists (see 'pj-sandbox status $task')" >&2
		return 1
	fi

	repo="$(pj_sandbox_git_repo)" || return 1
	pj_sandbox_git_prepare_branch "$repo" "$task" "$from" || return 1

	instance="$(pj_sandbox_instance_name "$task")"
	ssh_port="$(pj_sandbox_allocate_port)" || return 1
	mappings=""
	if [ -n "$guest_ports" ]; then
		mappings="$(pj_sandbox_allocate_ports "$guest_ports" "$ssh_port")" || return 1
	fi
	proxy_port="$(pj_sandbox_allocate_port "$ssh_port $(printf '%s\n' "$mappings" | cut -s -d: -f2)")" || return 1
	proxy_pid=""

	# The bundle goes in the task's state dir, which has no meta yet, so a
	# failure from here until the record is written must remove it.
	bundle="$PJ_SANDBOX_STATE_DIR/$task/$instance.bundle"
	guest_bundle="/tmp/$instance.bundle"
	mkdir -p "$PJ_SANDBOX_STATE_DIR/$task" || return 1
	if ! pj_sandbox_git_bundle "$repo" "$task" "$bundle"; then
		echo "pj-sandbox: spawn: 'git bundle create' failed for branch '$task'" >&2
		_pj_sandbox_spawn_drop_bundle
		return 1
	fi
	# Beside the profiles' allowlists, a directory template's and the repo's
	# own go into the merge (where `allowlist suggest --write` saves). The
	# repo's lives in its git dir, which is never bundled, so the guest can't
	# widen its own next policy by committing one.
	template_allowlist=""
	[ ! -d "$template" ] || template_allowlist="$template/allowlist"
	repo_allowlist="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)/pj-sandbox/allowlist" || {
		_pj_sandbox_spawn_abort
		return 1
	}
	if ! pj_sandbox_profiles_write_policy "$PJ_SANDBOX_PROFILES_DIR" "$agents" "$PJ_SANDBOX_STATE_DIR/$task/policy" \
		${template_allowlist:+"$template_allowlist"} "$repo_allowlist"; then
		_pj_sandbox_spawn_abort
		return 1
	fi
	if ! pj_sandbox_ca_ensure "$PJ_SANDBOX_CONFIG_DIR"; then
		_pj_sandbox_spawn_abort
		return 1
	fi

	render_dir="$(mktemp -d)" || {
		_pj_sandbox_spawn_abort
		return 1
	}
	config="$render_dir/$instance.yaml"
	provision="$render_dir/provision.yaml"
	template_provision="$(pj_sandbox_base_template_provision_path "$template")"
	if ! cat "$PJ_SANDBOX_HOME/lima/core-provision.yaml" > "$provision" ||
		! pj_sandbox_profiles_provision_yaml "$PJ_SANDBOX_PROFILES_DIR" "$agents" >> "$provision" ||
		! { [ -z "$template_provision" ] || cat "$template_provision"; } >> "$provision" ||
		! pj_sandbox_base_template_files_provision_yaml "$(pj_sandbox_base_template_files_path "$template")" >> "$provision" ||
		! pj_sandbox_render_lima_config "$PJ_SANDBOX_HOME/lima/template.yaml" "$ssh_port" "$mappings" "$provision" > "$config"; then
		rm -rf "$render_dir"
		_pj_sandbox_spawn_abort
		return 1
	fi

	if ! limactl start --name "$instance" --tty=false "$config"; then
		rm -rf "$render_dir"
		_pj_sandbox_spawn_abort
		echo "pj-sandbox: spawn: 'limactl start' failed for $instance" >&2
		return 1
	fi
	rm -rf "$render_dir"

	# Only now: the host's address on the host-only network exists once a
	# VM on it is up.
	if ! proxy_pid="$(pj_sandbox_proxy_start "$PJ_SANDBOX_STATE_DIR/$task" "$egress_mode" \
		"$PJ_SANDBOX_PROXY_HOST" "$proxy_port" "$PJ_SANDBOX_CONFIG_DIR")"; then
		proxy_pid=""
		_pj_sandbox_spawn_abort
		echo "pj-sandbox: spawn: the egress proxy for '$task' didn't start" >&2
		return 1
	fi

	if ! limactl copy "$bundle" "$instance:$guest_bundle" ||
		! pj_sandbox_git_guest_script |
		limactl shell --workdir / "$instance" sh -s -- "$guest_bundle" "$PJ_SANDBOX_GUEST_WORKSPACE" "$task"; then
		_pj_sandbox_spawn_abort
		echo "pj-sandbox: spawn: cloning branch '$task' into $instance:$PJ_SANDBOX_GUEST_WORKSPACE failed" >&2
		return 1
	fi
	_pj_sandbox_spawn_drop_bundle

	if ! lima_ssh_config="$(limactl ls --format='{{.SSHConfigFile}}' "$instance")" ||
		! pj_sandbox_ssh_write_entry "$PJ_SANDBOX_SSH_INCLUDE_FILE" "$instance" \
			"$(pj_sandbox_ssh_render_host_block "$instance" "$lima_ssh_config")" ||
		! pj_sandbox_ssh_ensure_include "$PJ_SANDBOX_SSH_INCLUDE_FILE" "$PJ_SANDBOX_SSH_CONFIG_FILE"; then
		_pj_sandbox_spawn_stop_proxy
		return 1
	fi

	if ! pj_sandbox_bootstrap_guest "$instance" "$PJ_SANDBOX_SSH_INCLUDE_FILE" "$PJ_SANDBOX_DOTFILES_HOME" \
		"$PJ_SANDBOX_CONFIG_DIR/ca/ca.pem" "http://$PJ_SANDBOX_PROXY_HOST:$proxy_port"; then
		_pj_sandbox_spawn_stop_proxy
		echo "pj-sandbox: spawn: bootstrapping dotfiles in $instance failed" >&2
		return 1
	fi
	if ! pj_sandbox_profiles_post_bootstrap "$PJ_SANDBOX_PROFILES_DIR" "$agents" "$instance" "$PJ_SANDBOX_SSH_INCLUDE_FILE"; then
		_pj_sandbox_spawn_stop_proxy
		return 1
	fi

	pj_sandbox_state_write "$task" \
		"task=$task" \
		"instance=$instance" \
		"repo=$repo" \
		"branch=$task" \
		"base=$base" \
		"agents=$(printf '%s\n' "$agents" | paste -sd , -)" \
		"ssh_port=$ssh_port" \
		"ports=$(printf '%s\n' "$mappings" | paste -sd , -)" \
		"created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		"egress_mode=$egress_mode" \
		"proxy_port=$proxy_port" \
		"proxy_pid=$proxy_pid" || {
		_pj_sandbox_spawn_stop_proxy
		return 1
	}

	echo "pj-sandbox: spawned '$task' as $instance (ssh $instance)"
	if [ -n "$mappings" ]; then
		printf '%s\n' "$mappings" | while IFS=: read -r guest host; do
			echo "  guest port $guest -> 127.0.0.1:$host"
		done
	fi
}
