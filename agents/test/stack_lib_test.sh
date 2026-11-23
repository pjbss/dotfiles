#!/bin/bash
# stack_lib_test.sh
#
# Unit tests for agents/lib/stack.sh: the layer order from `gh stack view
# --json`, and the parsing of a whole-stack review's blocking findings by
# the layer that owns each one -- what the loop's fix phase works from. A
# finding the parser misattributes would be fixed in the wrong layer, so the
# shapes pj-review-stack writes are pinned here.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
TEST_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
DOTFILES_HOME="$(cd -P "$TEST_DIR/../.." && pwd)"

. "$DOTFILES_HOME/test/assert.sh"
. "$DOTFILES_HOME/agents/lib/stack.sh"

fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

# --- layers ---

json='{"trunk": "main", "currentBranch": "w/02", "branches": [{"name": "w/01"}, {"name": "w/02"}, {"name": "w/03"}]}'
assert_eq "w/01 w/02 w/03" "$(printf '%s' "$json" | pj_stack_layers | tr '\n' ' ' | sed 's/ $//')" \
	"pj_stack_layers lists branches bottom first"
assert_not_ok "pj_stack_layers fails on input that isn't the JSON" sh -c '. "$1"; echo nope | pj_stack_layers' _ "$DOTFILES_HOME/agents/lib/stack.sh"

# --- blocking findings by layer ---

review="$fixture_root/stack.md"
cat > "$review" <<'REVIEW'
Verdict: changes-requested

## Reviewed

main...w/03 (3 layers)

## Findings

1. **[blocking] Seam mismatch** — `bin/a.sh:10`
   Layer: w/01
   Layer 1 writes JSON, layer 2 reads lines.
   Make layer 1 write lines.
2. **[note] Naming drift** — `bin/b.sh:3`
   Layer: w/02
   Called "slug" here and "name" there.
3. **[blocking] Duplicated helper** — `bin/c.sh:7`
   Layer: w/02
   Re-implements has_test_target.
4. **[blocking] Orphan finding** — `bin/d.sh:1`
   No owner given.
5. **[blocking] Another layer-1 fix** — `bin/e.sh:2`
   Layer: w/01
   Second thing in layer 1.

## Carried-over notes

### 001-a: something

Layer: w/03
accepted: not a finding, and not in ## Findings
REVIEW

index="$(pj_stack_blocking_findings "$review")"
assert_eq "4" "$(printf '%s\n' "$index" | grep -c . || true)" "every blocking finding is indexed, and only those"
assert_contains "$index" "$(printf 'w/01\tSeam mismatch')" "a finding is indexed by its Layer: branch and label"
assert_contains "$index" "$(printf 'w/02\tDuplicated helper')" "each blocking finding gets its own owner"
assert_contains "$index" "$(printf '\tOrphan finding')" "a blocking finding with no Layer: line is indexed with an empty owner"
assert_not_contains "$index" "Naming drift" "[note] findings are not indexed"
assert_not_contains "$index" "w/03" "a Layer: line outside ## Findings is ignored"

layer1="$(pj_stack_layer_findings "$review" w/01)"
assert_contains "$layer1" "Seam mismatch" "a layer's findings include its first blocking finding"
assert_contains "$layer1" "Make layer 1 write lines." "with the finding's full text"
assert_contains "$layer1" "Another layer-1 fix" "and every other blocking finding it owns"
assert_not_contains "$layer1" "Duplicated helper" "but not another layer's"
assert_not_contains "$layer1" "Naming drift" "and not a note"

layer2="$(pj_stack_layer_findings "$review" w/02)"
assert_contains "$layer2" "Re-implements has_test_target." "layer 2's findings hold its blocking finding"
assert_not_contains "$layer2" "Naming drift" "even a note naming the same layer is left out"
assert_eq "" "$(pj_stack_layer_findings "$review" w/03)" "a layer with no blocking findings gets nothing"

printf 'Verdict: approved\n\n## Findings\n\nNone.\n' > "$fixture_root/clean.md"
assert_eq "" "$(pj_stack_blocking_findings "$fixture_root/clean.md")" "a review with no findings indexes nothing"

assert_report
