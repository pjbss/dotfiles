# issues.sh
#
# Reading and querying the local issue tree that `pj-plan-issues` writes and
# `pj-tdd` consumes (agents/skills/pj-plan-issues/SKILL.md defines the file
# template these functions parse). Meant to be sourced, not executed.
#
# Until now that tree was prose only: the dependency graph lived in a
# `## Blocked by` section, and "is this issue ready" was decided by a human
# reading whether every blocker file had physically been moved into
# `issues/done/`. That rule is exactly right -- it just wasn't executable, so
# nothing could drain the queue unattended, and nothing could tell you a
# blocker pointed at an issue that never existed.
#
# The filesystem stays the source of truth: no index, no database, no state
# file to fall out of sync. `issues/` is deliberately gitignored working state,
# so anything derived from it is recomputed on every call rather than cached.
#
# An issue file is `issues/NNN-kebab-slug.md`, with a leading three-digit
# number. That pattern is what distinguishes an issue from the PRD(s) sitting
# beside it (`issues/prd.md`, `issues/prd-<name>.md`), which are not work items
# and must never show up in the queue.

# pj_issues_number FILE
#
# Echoes an issue file's zero-padded number (the `NNN` of `NNN-slug.md`), or
# nothing if the basename isn't shaped like an issue file.
pj_issues_number() {
	basename "$1" | sed -n 's/^\([0-9][0-9][0-9]\)-.*\.md$/\1/p'
}

# pj_issues_is_issue_file FILE
#
# True for `NNN-slug.md`, false for a PRD or any other stray markdown.
pj_issues_is_issue_file() {
	[ -n "$(pj_issues_number "$1")" ]
}

# pj_issues_section FILE HEADING
#
# Echoes the body of the `## HEADING` section, up to the next `##` heading or
# end of file. Empty (and exit 1) if the section is absent -- which is how
# validation distinguishes "section missing" from "section present but empty".
pj_issues_section() {
	body="$(awk -v heading="## $2" '
		$0 == heading { in_section = 1; next }
		in_section && /^## / { exit }
		in_section { print }
	' "$1")"

	printf '%s\n' "$body"

	grep -qxF "## $2" "$1"
}

# pj_issues_blockers FILE
#
# Echoes one blocker issue *basename* per line (e.g. `003-foo.md`), read from
# the file's `## Blocked by` section. Echoes nothing for an unblocked issue.
#
# Matched on the backticked `issues/NNN-slug.md` reference rather than on the
# "Blocked by" prose around it, so the surrounding wording is free to vary --
# and so the literal template line `None - can start immediately`, which
# contains no such reference, naturally yields no blockers with no special
# case for it.
pj_issues_blockers() {
	pj_issues_section "$1" "Blocked by" 2>/dev/null |
		grep -o 'issues/[0-9][0-9][0-9]-[A-Za-z0-9._-]*\.md' |
		sed 's|^issues/||' |
		sort -u
}

# pj_issues_state FILE ISSUES_DIR
#
# Echoes `done`, `ready`, or `blocked`. An issue is done when it lives under
# ISSUES_DIR/done/, and ready when every issue its `## Blocked by` names is
# itself done -- the rule pj-tdd/SKILL.md states in prose, made executable.
#
# A blocker naming a file that exists nowhere is treated as *not* satisfied
# (so the issue reads as blocked rather than silently ready). `validate`
# reports that case as the authoring error it is.
pj_issues_state() {
	issue_file="$1"
	issues_dir="$2"

	case "$issue_file" in
		"$issues_dir"/done/*) echo done; return 0 ;;
	esac

	for blocker in $(pj_issues_blockers "$issue_file"); do
		if [ ! -f "$issues_dir/done/$blocker" ]; then
			echo blocked
			return 0
		fi
	done

	echo ready
}

# pj_issues_scan ISSUES_DIR
#
# Echoes every open issue file path (ISSUES_DIR/NNN-*.md), number-sorted.
# PRDs, `done/`, and anything not shaped like an issue file are excluded.
pj_issues_scan() {
	find "$1" -maxdepth 1 -type f -name '*.md' 2>/dev/null |
		while read -r candidate; do
			pj_issues_is_issue_file "$candidate" && echo "$candidate"
		done |
		sort
}

# pj_issues_scan_done ISSUES_DIR
pj_issues_scan_done() {
	find "$1/done" -maxdepth 1 -type f -name '*.md' 2>/dev/null |
		while read -r candidate; do
			pj_issues_is_issue_file "$candidate" && echo "$candidate"
		done |
		sort
}

# pj_issues_next ISSUES_DIR
#
# Echoes the path of the lowest-numbered ready issue and returns 0, or echoes
# nothing and returns 1 when nothing is ready. Lowest-numbered rather than
# arbitrary so a run is reproducible: the same tree always drains in the same
# order, which matters when a failed run has to be re-read after the fact.
pj_issues_next() {
	for issue_file in $(pj_issues_scan "$1"); do
		if [ "$(pj_issues_state "$issue_file" "$1")" = ready ]; then
			echo "$issue_file"
			return 0
		fi
	done

	return 1
}

# pj_issues_unchecked_criteria FILE
#
# Echoes each unchecked `- [ ]` acceptance criterion. Used to catch an issue
# filed into done/ with work left on it -- the one inconsistency the
# filesystem-as-state design can't rule out structurally.
pj_issues_unchecked_criteria() {
	pj_issues_section "$1" "Acceptance criteria" 2>/dev/null |
		sed -n 's/^- \[ \] *//p'
}

# pj_issues_validate_file FILE ISSUES_DIR
#
# Echoes one problem per line, returns non-zero if there were any. Checks the
# things that silently break an unattended run: a missing section the loop
# reads, a blocker pointing at a file that doesn't exist, an empty acceptance
# criteria list (nothing for the reviewer to check against), and unfinished
# criteria on an issue already filed as done.
pj_issues_validate_file() {
	issue_file="$1"
	issues_dir="$2"
	problems=0

	for heading in "What to build" "Acceptance criteria" "Blocked by"; do
		if ! grep -qxF "## $heading" "$issue_file"; then
			echo "$issue_file: missing '## $heading' section"
			problems=$((problems + 1))
		fi
	done

	if [ -z "$(pj_issues_section "$issue_file" "Acceptance criteria" 2>/dev/null | sed -n 's/^- \[[ x]\] *//p')" ]; then
		echo "$issue_file: no acceptance criteria -- nothing for a reviewer to verify against"
		problems=$((problems + 1))
	fi

	for blocker in $(pj_issues_blockers "$issue_file"); do
		if [ ! -f "$issues_dir/$blocker" ] && [ ! -f "$issues_dir/done/$blocker" ]; then
			echo "$issue_file: blocked by 'issues/$blocker', which doesn't exist"
			problems=$((problems + 1))
		fi

		if [ "$blocker" = "$(basename "$issue_file")" ]; then
			echo "$issue_file: blocks itself"
			problems=$((problems + 1))
		fi
	done

	case "$issue_file" in
		"$issues_dir"/done/*)
			unchecked="$(pj_issues_unchecked_criteria "$issue_file")"
			if [ -n "$unchecked" ]; then
				echo "$issue_file: in done/ with unchecked acceptance criteria"
				problems=$((problems + 1))
			fi
			;;
	esac

	[ "$problems" -eq 0 ]
}

# pj_issues_find_cycle ISSUES_DIR
#
# Echoes the basenames still standing after repeatedly stripping every issue
# whose blockers are all satisfied -- i.e. the members of a dependency cycle,
# or anything transitively stuck behind one. Echoes nothing when the graph is
# acyclic.
#
# Done by iterative peeling rather than a depth-first search because POSIX sh
# has no recursion-friendly data structures, and the graphs here are tens of
# nodes at most.
pj_issues_find_cycle() {
	issues_dir="$1"

	remaining=""
	for issue_file in $(pj_issues_scan "$issues_dir"); do
		remaining="$remaining $(basename "$issue_file")"
	done

	satisfied=""
	for issue_file in $(pj_issues_scan_done "$issues_dir"); do
		satisfied="$satisfied $(basename "$issue_file")"
	done

	while :; do
		peeled=""
		still_stuck=""

		for name in $remaining; do
			blocked=0
			for blocker in $(pj_issues_blockers "$issues_dir/$name"); do
				# A blocker naming a file that exists nowhere is an
				# authoring error, not a cycle -- validate reports it
				# separately. Ignoring it here keeps this function's
				# output meaning exactly "these are in a cycle".
				[ -f "$issues_dir/$blocker" ] || continue

				case " $satisfied " in
					*" $blocker "*) ;;
					*) blocked=1 ;;
				esac
			done

			if [ "$blocked" -eq 0 ]; then
				satisfied="$satisfied $name"
				peeled=1
			else
				still_stuck="$still_stuck $name"
			fi
		done

		remaining="$still_stuck"
		[ -n "$peeled" ] || break
	done

	for name in $remaining; do
		echo "$name"
	done
}

# --- Plans and stacked issues ----------------------------------------------
#
# pj-write-plan writes issues/plan[-name].md: `Key: value` header lines, a
# `## Stack` table with one row per layer, and one `## Layer N` section each.
# pj-plan-issues cuts one issue per layer, adding `## Branch` (the layer's
# bare branch name) and `## Plan section` (`` `issues/plan.md` Layer N ``).
# The helpers below read those, for `validate` here and the loop's stack mode.

# pj_issues_doc_status FILE
#
# Echoes the first word after `Status: ` on the document's first `Status:`
# line -- `draft`, `approved` or `final` -- or nothing. Found by key rather than
# by line number: it is line 1 of a PRD but sits under a title in a plan.
pj_issues_doc_status() {
	sed -n 's/^Status: \([a-z][a-z]*\).*/\1/p' "$1" | head -n 1
}

# pj_issues_doc_header FILE KEY
#
# Echoes the value of the first `KEY: value` line, or nothing. Matched
# literally (KEY may contain a space, e.g. `Test plan`); only the first match
# counts, so prose further down that happens to start with the key can't
# override the header.
pj_issues_doc_header() {
	awk -v prefix="$2: " 'index($0, prefix) == 1 { print substr($0, length(prefix) + 1); exit }' "$1"
}

# pj_issues_plan_layer_branch PLAN N
#
# Echoes the Branch cell of row N in the plan's `## Stack` table, or nothing.
pj_issues_plan_layer_branch() {
	pj_issues_section "$1" "Stack" 2>/dev/null |
		awk -F'|' -v layer="$2" '
			{
				number = $2; branch = $3
				gsub(/^[ \t]+|[ \t]+$/, "", number)
				gsub(/^[ \t]+|[ \t]+$/, "", branch)
			}
			number == layer { print branch; exit }
		'
}

# pj_issues_first_line FILE HEADING -- the first non-blank line of a section,
# trimmed of surrounding whitespace.
pj_issues_first_line() {
	pj_issues_section "$1" "$2" 2>/dev/null |
		awk 'NF { gsub(/^[ \t]+|[ \t]+$/, ""); print; exit }'
}

# pj_issues_branch FILE -- the issue's `## Branch`, or nothing if unstacked.
pj_issues_branch() {
	pj_issues_first_line "$1" "Branch"
}

# pj_issues_plan_ref FILE -- the plan path its `## Plan section` names, as
# written (`issues/plan-x.md`), or nothing.
pj_issues_plan_ref() {
	pj_issues_first_line "$1" "Plan section" |
		sed -n 's/^`\(issues\/[^`]*\.md\)`.*/\1/p'
}

# pj_issues_plan_file ISSUES_DIR FILE -- the issue's plan as a path under
# ISSUES_DIR (`issues/plan-x.md` -> ISSUES_DIR/plan-x.md), or nothing if
# unstacked. Doesn't check that the file exists.
pj_issues_plan_file() {
	pf_ref="$(pj_issues_plan_ref "$2")"
	[ -z "$pf_ref" ] || printf '%s/%s\n' "$1" "${pf_ref#issues/}"
}

# pj_issues_plan_layer FILE -- the N of its `## Plan section`'s `Layer N`.
pj_issues_plan_layer() {
	pj_issues_first_line "$1" "Plan section" |
		sed -n 's/.*Layer \([0-9][0-9]*\).*/\1/p'
}

# pj_issues_stack_problem MESSAGE -- prints one validate_stack problem and
# counts it. Variables here are prefixed `vs_` because POSIX sh has no
# `local`, and the helpers validate_stack calls set unprefixed globals.
pj_issues_stack_problem() {
	echo "$1"
	vs_problems=$((vs_problems + 1))
}

# pj_issues_validate_stack ISSUES_DIR
#
# Echoes one problem per line, naming the issue file and the rule broken, and
# returns non-zero if there were any. Does nothing for an unstacked tree: the
# rules apply only once some open issue has a `## Branch`, and then:
#
# - every open issue is a stack layer (a non-empty `## Branch`), all naming
#   the same plan in `## Plan section`, and that plan exists;
# - branch names are unique across the plan's open and done issues (the
#   order and Stack-row rules below cover open issues only);
# - `Blocked by` forms one chain: at most one blocker each, no blocker shared,
#   each layer blocked by the open issue just below it, and only the lowest
#   open layer unblocked or sitting on a done issue;
# - issue numbers follow layer order, and each branch equals its layer's
#   `Branch` cell in the plan's `## Stack` table.
#
# The loop builds one branch per layer on top of the one below, so any of
# these going wrong means a stack built in the wrong order or onto the wrong
# branch -- caught here, before a run starts, rather than halfway through it.
pj_issues_validate_stack() {
	vs_dir="$1"
	vs_open="$(pj_issues_scan "$vs_dir")"
	vs_problems=0

	vs_stacked=""
	for vs_file in $vs_open; do
		if grep -qxF "## Branch" "$vs_file"; then
			vs_stacked=1
		fi
	done
	[ -n "$vs_stacked" ] || return 0

	# Every open issue is a layer of one plan, and the plan exists.
	vs_plan=""
	vs_plan_first=""
	for vs_file in $vs_open; do
		if [ -z "$(pj_issues_branch "$vs_file")" ]; then
			pj_issues_stack_problem "$vs_file: no '## Branch' -- once any open issue is a stack layer, every open issue must be one"
		fi

		vs_ref="$(pj_issues_plan_ref "$vs_file")"
		if [ -z "$vs_ref" ]; then
			pj_issues_stack_problem "$vs_file: no '## Plan section' naming its plan and layer"
		elif [ -z "$vs_plan" ]; then
			vs_plan="$vs_ref"
			vs_plan_first="$vs_file"
		elif [ "$vs_ref" != "$vs_plan" ]; then
			pj_issues_stack_problem "$vs_file: names plan '$vs_ref', but $vs_plan_first names '$vs_plan' -- a stack has one plan"
		fi
	done

	vs_plan_file=""
	if [ -n "$vs_plan" ]; then
		if [ -f "$(pj_issues_plan_file "$vs_dir" "$vs_plan_first")" ]; then
			vs_plan_file="$(pj_issues_plan_file "$vs_dir" "$vs_plan_first")"
		else
			pj_issues_stack_problem "$vs_plan_first: plan '$vs_plan' doesn't exist"
		fi
	fi

	# Branch names are unique across the plan's issues, open and done, in
	# issue-number order: a done layer's branch already exists in git, so a
	# new layer reusing its name would collide with it.
	vs_members=""
	for vs_file in $vs_open $(pj_issues_scan_done "$vs_dir"); do
		if [ -n "$vs_plan" ] && [ "$(pj_issues_plan_ref "$vs_file")" = "$vs_plan" ]; then
			vs_members="$vs_members $vs_file"
		fi
	done
	vs_members="$(for vs_file in $vs_members; do echo "$(basename "$vs_file") $vs_file"; done | sort | cut -d' ' -f2)"

	vs_seen=""
	for vs_file in $vs_members; do
		vs_branch="$(pj_issues_branch "$vs_file")"
		[ -n "$vs_branch" ] || continue
		vs_other="$(printf '%s\n' "$vs_seen" | awk -v b="$vs_branch" '$1 == b { print $2; exit }')"
		if [ -n "$vs_other" ]; then
			pj_issues_stack_problem "$vs_file: branch '$vs_branch' is also used by $vs_other -- branch names must be unique"
		fi
		vs_seen="$vs_seen
$vs_branch $vs_file"
	done

	# Open issues follow the plan's layer order and match its Stack rows. Done
	# issues are left out: a plan replaced in place has new rows that the
	# previous stack's done issues no longer match, and that's not an error.
	vs_prev_layer=""
	for vs_file in $vs_open; do
		[ "$(pj_issues_plan_ref "$vs_file")" = "$vs_plan" ] || continue
		vs_branch="$(pj_issues_branch "$vs_file")"
		vs_layer="$(pj_issues_plan_layer "$vs_file")"
		if [ -z "$vs_layer" ]; then
			pj_issues_stack_problem "$vs_file: '## Plan section' names no 'Layer N'"
			continue
		fi
		if [ -n "$vs_prev_layer" ] && [ "$vs_layer" -le "$vs_prev_layer" ]; then
			pj_issues_stack_problem "$vs_file: Layer $vs_layer comes after Layer $vs_prev_layer in issue order -- issues must be numbered in the plan's layer order"
		fi
		vs_prev_layer="$vs_layer"

		[ -n "$vs_plan_file" ] || continue
		vs_row="$(pj_issues_plan_layer_branch "$vs_plan_file" "$vs_layer")"
		if [ -z "$vs_row" ]; then
			pj_issues_stack_problem "$vs_file: the plan has no Stack row $vs_layer"
		elif [ -n "$vs_branch" ] && [ "$vs_branch" != "$vs_row" ]; then
			pj_issues_stack_problem "$vs_file: branch '$vs_branch' differs from the plan's Stack row $vs_layer ('$vs_row')"
		fi
	done

	# Blocked by forms a single chain, each open layer on the one below it.
	vs_prev=""
	vs_blocker_seen=""
	for vs_file in $vs_open; do
		vs_blockers="$(pj_issues_blockers "$vs_file")"
		vs_count=0
		vs_open_blocker=""
		for vs_blocker in $vs_blockers; do
			vs_count=$((vs_count + 1))
			if [ -f "$vs_dir/$vs_blocker" ]; then
				vs_open_blocker="$vs_blocker"
			fi

			vs_other="$(printf '%s\n' "$vs_blocker_seen" | awk -v b="$vs_blocker" '$1 == b { print $2; exit }')"
			if [ -n "$vs_other" ]; then
				pj_issues_stack_problem "$vs_file: shares its blocker '$vs_blocker' with $vs_other -- the stack must be a single chain"
			fi
			vs_blocker_seen="$vs_blocker_seen
$vs_blocker $vs_file"
		done

		if [ "$vs_count" -gt 1 ]; then
			pj_issues_stack_problem "$vs_file: blocked by $vs_count issues -- a stack layer is blocked only by the layer below it"
		fi

		if [ -z "$vs_prev" ]; then
			if [ -n "$vs_open_blocker" ]; then
				pj_issues_stack_problem "$vs_file: the lowest open layer is blocked by open '$vs_open_blocker' -- it may only sit on a done issue, or nothing"
			fi
		elif [ -z "$vs_open_blocker" ]; then
			pj_issues_stack_problem "$vs_file: only the lowest open layer may be unblocked or blocked by a done issue -- this one belongs on '$vs_prev'"
		elif [ "$vs_count" -eq 1 ] && [ "$vs_open_blocker" != "$vs_prev" ]; then
			pj_issues_stack_problem "$vs_file: blocked by '$vs_open_blocker', but the layer below it is '$vs_prev'"
		fi

		vs_prev="$(basename "$vs_file")"
	done

	[ "$vs_problems" -eq 0 ]
}
