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
