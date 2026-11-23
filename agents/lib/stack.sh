# stack.sh
#
# Reading the gh-stack extension's view of the current stack. pj-run-issues
# (stack mode), pj-stack-verify and the stack review both need the layers in
# stack order, so the parsing lives once, here. Meant to be sourced; POSIX sh
# plus python3, which the loop already depends on for its stream renderer.

# pj_stack_layers -- reads `gh stack view --json` on stdin and prints its
# branch names, one per line, bottom layer first: the order gh-stack v0.3.0
# lists `branches` in (confirmed against the real extension). Fails on input
# that isn't that JSON.
pj_stack_layers() {
	python3 -c '
import json, sys
for branch in json.load(sys.stdin)["branches"]:
    print(branch["name"])
'
}

# pj_stack__findings MODE FILE [BRANCH] -- walks the `## Findings` section of a
# pj-review-stack verdict file. A finding starts at a numbered bold label
# (`1. **[blocking] label** — ...`) and runs until the next one or the next
# section; its owner is the first `Layer: <branch>` line inside it. Only
# `[blocking]` findings are reported. MODE `index` prints `BRANCH<TAB>LABEL`
# per finding (BRANCH empty when it has no Layer: line); MODE `layer` prints
# the full text of the findings BRANCH owns, separated by blank lines.
pj_stack__findings() {
	awk -v mode="$1" -v want="${3:-}" '
		function flush() {
			if (text != "" && blocking) {
				if (mode == "index") {
					print owner "\t" label
				} else if (owner == want) {
					if (printed) print ""
					print text
					printed = 1
				}
			}
			text = ""; blocking = 0; owner = ""; label = ""
		}
		/^## / { flush(); in_findings = ($0 == "## Findings"); next }
		!in_findings { next }
		/^[0-9]+\. \*\*\[/ {
			flush()
			blocking = ($0 ~ /^[0-9]+\. \*\*\[blocking\]/)
			text = $0
			label = $0
			sub(/^[0-9]+\. \*\*\[[a-z-]*\] */, "", label)
			sub(/\*\*.*/, "", label)
			next
		}
		text != "" {
			text = text "\n" $0
			if (owner == "" && $0 ~ /^ *Layer: /) {
				owner = $0
				sub(/^ *Layer: */, "", owner)
				sub(/[ \t]+$/, "", owner)
			}
		}
		END { flush() }
	' "$2"
}

# pj_stack_blocking_findings FILE -- `BRANCH<TAB>LABEL` per blocking finding
# in a pj-review-stack verdict file; BRANCH is empty for one with no Layer:.
pj_stack_blocking_findings() {
	pj_stack__findings index "$1"
}

# pj_stack_layer_findings FILE BRANCH -- the full text of the blocking
# findings BRANCH owns, for the fix prompt of that one layer.
pj_stack_layer_findings() {
	pj_stack__findings layer "$1" "$2"
}
