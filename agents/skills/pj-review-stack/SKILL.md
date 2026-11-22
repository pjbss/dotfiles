---
name: pj-review-stack
description: Reviews a finished stack of branches as a whole -- the full diff from trunk to top against the PRD, the plan and every per-layer review -- for what per-layer review structurally can't see, naming the layer that owns each finding. Writes issues/reviews/stack[-name].md. Use once every layer of a planned stack has been built and reviewed, before the stack is published.
tags: [workflow, review]
---

# Review a whole stack

Purpose: each layer was reviewed on its own, through both lenses. What none
of those reviews could see is the stack as one change: an interface the plan
defined that two layers implement differently, duplication that only appears
across layers, an abstraction a later layer made redundant, and the
`[note]` findings every layer's review carried forward instead of fixing.
This review sees the whole and says, for each problem, which layer owns the
fix.

You are reviewing, not implementing. Do not change anything you find.

## Inputs

Read all of these before forming a view:

- The PRD (the plan's `PRD:` header names it): its Implementation
  Decisions and Out of Scope above all.
- The plan: especially `## Review focus` (the failure modes no layer's
  tests exercise) and `## Interfaces` (the contracts the layers share), and
  the `## Stack` table for the layer order.
- The test plan: the draft test plan the plan's `Test plan:` header names.
- Every per-layer review file for the plan's issues, both lenses: the
  spec review `issues/reviews/NNN-slug.md` and the quality review, its
  `.quality.md` sibling -- including their `[note]` findings, which were
  carried forward to here.
- `git diff <trunk>...<top>`: the whole change at once.
- `git log` per layer (`git log <lower>..<layer>` for each branch in the
  Stack table), so each finding can be traced to the layer that introduced
  it.

## Checks

These are what per-layer review structurally can't see. Go through each:

- **Cross-layer correctness**: the plan's interfaces honoured at the seams
  between layers, with matching signatures, formats and exit codes on both
  sides, and no behaviour that breaks only when the layers combine.
- **Whole-diff simplicity**: duplication across layers, an abstraction or
  helper a later layer made redundant, scaffolding a lower layer needed that
  nothing uses any more, and naming drift between layers (the same thing
  called two names).
- **Layer integrity**: each layer still makes sense as its own pull request
  -- it builds, its tests pass on their own, and a reviewer could approve it
  without the layers above it.
- **Carried-over notes**: every carried-over `[note]` from the per-layer
  reviews is either fixed somewhere in the stack, or explicitly accepted with
  a reason a person can disagree with. None is silently dropped.
- **PRD decisions and Out of Scope**: nothing in the stack quietly reverses
  a recorded decision or builds something the PRD ruled out.

Triage every finding with the severities defined in `pj-review`
(`[blocking]`, `[note]`, `[pre-existing]`). The verdict is
`changes-requested` exactly when at least one finding is `[blocking]`. Every
finding has a `Layer: <branch>` line naming the stack branch that owns the
fix -- the lowest layer the fix belongs in, since a fix there flows up to
every layer above it. Write it exactly `Layer: <branch>`: the bare branch
name from the Stack table, without backticks, on the line after the
finding's label. The fix pass reads that line to know which branch to work
on.

## Output

Write the verdict file named after the plan: `issues/reviews/stack.md` for
`issues/plan.md`, `issues/reviews/stack-<name>.md` for
`issues/plan-<name>.md` (creating `issues/reviews/` if needed). Its first
line is exactly one of:

```
Verdict: approved
```

```
Verdict: changes-requested
```

The issue loop parses that line, as it does every review's. Then:

```markdown
## Reviewed

<trunk>...<top> (<n> layers), `make test` per layer: <passed | not run>

## Findings

1. **[blocking] <short label>** — `path/to/file.sh:LINE`
   Layer: <prefix>/NN-<slug>
   What's wrong across the layers, and what would fix it.

## Carried-over notes

### <NNN-slug>: <the note's short label>

fixed — <where in the stack>

### <NNN-slug>: <another note's short label>

accepted: <reason>
```

If there are no findings, write `None.` under `## Findings`. If no layer
carried a note forward, write `None.` under `## Carried-over notes`.
