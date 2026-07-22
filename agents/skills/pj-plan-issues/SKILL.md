---
name: pj-plan-issues
description: Decomposes issues/prd.md into small, independently-implementable local issue files under issues/, each with acceptance criteria and blocked-by dependency metadata. Use after pj-write-prd, before starting implementation with pj-tdd.
tags: [workflow, planning]
---

# Plan Issues

Purpose: turn `issues/prd.md` into a set of small, concrete, dependency-
ordered issue files that `pj-tdd` can pick up one at a time.

## Process

1. Require `issues/prd.md` to exist — read it in full first. If it doesn't
   exist, tell the user to run `pj-write-prd` first and stop.

2. Explore the codebase so slices are grounded in what actually exists
   (current structure, seams, what's already reusable).

3. Decompose the PRD into **vertical slices**: each issue should deliver
   one coherent, independently testable piece of user-visible behavior,
   cutting through every layer it touches (e.g. "add worktree-count prompt
   segment" — function, wiring, and visible output, together). Do **not**
   create horizontal slices (e.g. "add all the data models" then "add all
   the views") — those hide integration risk and create a false sense of
   progress when "done".

4. Number issues sequentially, zero-padded to 3 digits. Before assigning
   the next number, scan both `issues/` and `issues/done/` for the current
   highest number in use and continue from there — never reuse or
   renumber an existing issue.

5. File name: `issues/NNN-kebab-case-slug.md`. Write each issue using
   exactly this template:

```markdown
## Parent PRD

`issues/prd.md`

## What to build

A specific, scoped description of the slice, referencing which part(s) of
the PRD's Solution/Implementation Decisions it comes from.

## Acceptance criteria

- [ ] Concrete, testable/verifiable condition
- [ ] Another one

## Blocked by

- Blocked by `issues/NNN-other-slug.md`

(Or, if nothing blocks it: `None - can start immediately`)

## User stories addressed

- User story N
```

6. After writing all the issue files for this PRD (or this planning pass,
   if the PRD is large enough to plan incrementally), print a short
   summary table: issue number, slug, and what blocks it — so the
   dependency graph is visible at a glance before implementation starts.

## Output

One `issues/NNN-slug.md` file per vertical slice, following the template
above. This skill is planning-only — it never implements anything. Suggest
`pj-tdd` as the next step, pointing at whichever issue(s) have no
remaining blockers.
