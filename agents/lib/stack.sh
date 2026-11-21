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
