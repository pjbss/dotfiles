---
name: pj-plan-issues
description: Cuts an approved plan (issues/plan.md or issues/plan-<name>.md) into one local issue file per stack layer under issues/, each carrying its branch, its plan section, acceptance criteria citing the PRD's IDs, and a blocked-by on the layer below. Use after pj-write-plan, before starting implementation with pj-tdd.
tags: [workflow, planning]
---

# Plan Issues

Purpose: turn an approved plan into issue files that `pj-tdd` can pick up one
at a time, one per stack layer, so the issue queue and the stack are the same
sequence. The plan already decided the slicing and the order; this skill
makes it executable.

## Process

1. Find the plan: the path given as an argument, else `issues/plan.md`, and
   read it in full. Read its `Status:` line. Unless it says `approved`,
   refuse: tell the user the plan still needs approving (`pj-write-plan`)
   and stop. If there is no plan at all, tell the user to write one with
   `pj-write-plan` first and stop. Read the PRD its `PRD:` header names
   too: the issues cite its `US-n` and `AC-n.k` IDs.

2. Explore the codebase so each issue's pointers are grounded in what
   actually exists. Use sub-agents as needed to explore the codebase, but
   do not write any code or create any files while exploring. Keep track
   of file paths and line numbers for any references you make.

3. Cut exactly one issue per `## Layer N` section of the plan, numbered in
   layer order: layer 1 gets the lowest number. Don't split or merge
   layers here; if a layer looks wrong, say so and send it back to the
   plan instead.

4. Number issues sequentially, zero-padded to 3 digits. Before assigning
   the next number, scan both `issues/` and `issues/done/` for the current
   highest number in use and continue from there — never reuse or
   renumber an existing issue.

5. Every acceptance criterion must be provable by an automated test or by
   reading the repo. Cite the PRD's `AC-n.k` IDs the layer's `Done when:`
   line names, refined into something a test can check where needed. A
   check that needs a person to look at something, click something, or
   drive a real terminal session is **not** written as a criterion — it
   belongs in the plan's test plan (the file its `Test plan:` header names),
   as a manual case in the shape `pj-write-test-plan` defines. Make sure the
   layer's `Manual:` cases are there; add any that are missing. No agent can
   tick such a box, so an issue holding one never reaches `issues/done/`
   and the issue loop stops with the whole queue still behind it.

6. `## Blocked by` names only the previous layer's issue. Layer 1's issue
   is `None - can start immediately`. The chain this forms is what
   `pj-issues validate` checks.

7. File name: `issues/NNN-kebab-case-slug.md`, the slug taken from the
   layer's name. Write each issue using exactly this template:

```markdown
## Parent PRD

`issues/prd.md`

## Branch

<prefix>/NN-<slug>

## Plan section

`issues/plan.md` Layer N

## What to build

Build the plan section above. Add only what is specific to this issue and
not already in the plan: a starting point in the code (file paths, line
numbers), a gotcha found while exploring. Don't restate the plan, so the two
can't drift apart.

## Acceptance criteria

- [ ] AC-n.k: concrete, testable condition (refined from the PRD where needed)
- [ ] Another one

## Blocked by

- Blocked by `issues/NNN-previous-layer.md`

(Or, for layer 1: `None - can start immediately`)

## User stories addressed

- US-n
```

   `## Parent PRD` is the plan's `PRD:` header. `## Branch` is the layer's
   bare branch name, exactly as in the plan's `## Stack` table: no
   backticks. `## Plan section` is one line, the plan's path in backticks
   then `Layer N`, e.g. `` `issues/plan-export.md` Layer 2 ``.

8. After writing all the issue files, print a short summary table: issue
   number, branch, slug, and what blocks it — so the stack is visible at a
   glance before implementation starts. List the manual cases in the test
   plan alongside it: the manual surface is cheapest to argue with now,
   before anything has been built on it.

## Output

One `issues/NNN-slug.md` file per plan layer, following the template above,
plus any manual cases added to the plan's test plan. This skill is
planning-only — it never implements anything. Run `pj-issues validate` to
confirm the chain, and suggest `pj-tdd` on the layer-1 issue as the next
step.
