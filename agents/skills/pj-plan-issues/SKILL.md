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
   (current structure, seams, what's already reusable). Use sub-agents
   as needed to explore the codebase, but do not write any code or 
   create any files while exploring. Make sure that you understand the 
   codebase and you keep track of file paths and line numbers for any 
   references you make to the user.

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

5. Every acceptance criterion must be provable by an automated test or by
   reading the repo. A check that needs a person to look at something,
   click something, or drive a real terminal session is **not** written as
   a criterion — it becomes an entry in `issues/manual-tests.md` (step 7).
   No agent can tick such a box, so an issue holding one never reaches
   `issues/done/` and `pj-run-issues` stops with the whole queue still
   behind it. Separating the two here is what keeps the queue drainable.

6. File name: `issues/NNN-kebab-case-slug.md`. Write each issue using
   exactly this template:

```markdown
## Parent PRD

`issues/prd.md`

## What to build

A specific, scoped description of the slice, referencing which part(s) of
the PRD's Solution/Implementation Decisions it comes from. Include any
relevant code references (file paths, line numbers) to help the implementer find the
right place to start.

## Acceptance criteria

- [ ] Concrete, testable/verifiable condition
- [ ] Another one

## Blocked by

- Blocked by `issues/NNN-other-slug.md`

(Or, if nothing blocks it: `None - can start immediately`)

## User stories addressed

- User story N
```

7. Collect every human-only check set aside in step 5 into
   `issues/manual-tests.md`, one entry each, naming the issue it came from.
   Write the file only if there is at least one such check. If it already
   exists, read it first and continue its numbering — `MT-N` numbers get
   referenced from issue resolution notes later, so append, never renumber.
   Use exactly this template:

```markdown
# Manual test plan

Checks that no automated test can make. `pj-run-issues` never runs these —
work through them by hand once the branch is done.

## MT-1 — <short name>

Source: `issues/003-worktree-segment.md` (user story 2)

1. Step to perform.
2. Next step.

**Expect:** the specific observable outcome that means this passed.
```

8. After writing all the issue files for this PRD (or this planning pass,
   if the PRD is large enough to plan incrementally), print a short
   summary table: issue number, slug, and what blocks it — so the
   dependency graph is visible at a glance before implementation starts.
   List the `MT-N` entries written alongside it: the manual surface is
   cheapest to argue with now, before anything has been built on it.

## Output

One `issues/NNN-slug.md` file per vertical slice, following the template
above, plus `issues/manual-tests.md` when any part of the work can only be
confirmed by a person. This skill is planning-only — it never implements
anything. Suggest `pj-tdd` as the next step, pointing at whichever issue(s)
have no remaining blockers.
