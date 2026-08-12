# base_template.sh
#
# `--base <name>` resolution for `pj-sbx-spawn` (issue 003): each valid
# name is a file under sandbox/templates/, so adding a new one is a
# one-file change with no lookup table to keep in sync. Meant to be
# sourced, not executed directly.

# sandbox_base_template_path TEMPLATES_DIR NAME
#
# Prints TEMPLATES_DIR/NAME and returns 0 if that file exists, meaning NAME
# is a valid `--base` value. Prints nothing and returns 1 otherwise -- this
# also covers a comma-separated/multi-value NAME (e.g. "python3.12,node20"),
# since no template file is ever named that: exactly one template applies
# per sandbox, by construction rather than extra parsing.
sandbox_base_template_path() {
	templates_dir="$1"
	name="$2"

	candidate="$templates_dir/$name"

	if [ -f "$candidate" ]; then
		echo "$candidate"
		return 0
	fi

	return 1
}

# sandbox_base_template_list TEMPLATES_DIR
#
# Prints every valid `--base` name in TEMPLATES_DIR, one per line, sorted.
# Derived straight from the directory's contents (issue 004's `--base
# list`), so dropping in a new template file needs no other code change to
# show up here.
sandbox_base_template_list() {
	templates_dir="$1"

	ls -1 "$templates_dir" | sort
}
