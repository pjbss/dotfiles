---
name: pj-write-plan
description: Turns an approved PRD (issues/prd.md or issues/prd-<name>.md) into a human-approved plan document at issues/plan[-name].md -- interfaces, data models, data flow, global constraints, review focus, and an ordered stack of layers that each become one reviewable branch. Use after pj-write-prd and before pj-plan-issues.
tags: [workflow, planning]
---

# Write plan

Purpose: turn an approved PRD into the design a human reviews before any
code exists. The plan holds the decisions the implementer can't make alone:
interfaces, data models and data flow come first, and the stack of layers
fixes the order the work lands in. It stays code-light. Test assertions are
the specification, and `pj-tdd` writes the code.

## Process

1. Find the PRD: the path given as an argument, else `issues/prd.md`. Read
   its `Status:` line. Unless it says `approved`, refuse: tell the human
   the PRD is still a draft that needs approving first (`pj-write-prd`), and
   stop. Don't plan from a draft, even a nearly finished one.

2. Explore the codebase before writing, so the plan is grounded in what
   actually exists (current structure, seams, what's already reusable).
   Use sub-agents as needed to explore, but don't write any code or create
   any files while exploring. Keep track of file paths and line numbers:
   the plan cites them.

3. Name the plan after the PRD: `prd.md` → `issues/plan.md`, and
   `prd-<name>.md` → `issues/plan-<name>.md`. The test plan the header
   points at is named the same way: `issues/test-plan.md`, or
   `issues/test-plan-<name>.md`. If the plan already exists, read it and ask
   before replacing it.

4. Write the plan using the template below. The skill always writes
   `Status: draft`. Keep every header a plain `Key: value` line of its own,
   with a bare value, no backticks (`Trunk: main`, not ``Trunk: `main` ``),
   and keep the headings exact: `pj-plan-issues` and the issue loop read
   the `Status:`, `Trunk:` and `Test plan:` lines, the `## Stack` table and
   the `## Layer N` sections.

5. Run the self-checks below and fix what they find.

6. Present the plan for approval: summarize the Stack table, and name any
   layer flagged as oversized. Change the status line to
   `Status: approved (<today>)` only after the human explicitly approves in
   conversation. Anything short of that — silence, "looks good so far", a
   request for changes — leaves it `Status: draft`.

Editing an approved plan sets it back to `Status: draft` until the human
approves it again, whether the edit comes from this skill or a later
conversation. Downstream skills stop on a draft, so never leave an edited
plan marked approved.

## Template

```markdown
# Plan — <feature>

Status: draft | approved (YYYY-MM-DD)
PRD: <path>
Test plan: <path>
Trunk: <branch>
Branch prefix: <prefix>/

## Goal

One sentence.

## Architecture

The current shape, with `file:line` references, then the target shape and
what moves between them.

## Interfaces

Every new or changed contract, with exact signatures: functions, CLI flags
and exit codes, hook payloads, file formats.

## Data models

New or changed structures: fields, types, invariants, where each lives
(file, env var, git ref, JSON), who writes it and who reads it.

## Data flow

How data moves between the components above, for the main path and the
main failure path. Add a diagram only when more than two components
interact.

## Global constraints

One per line, with exact values copied from the PRD's Non-functional
Requirements.

## Review focus

At most 5 failure modes the PRD implies but no layer's tests exercise.

## Stack

| # | Branch | Delivers | Depends on | ~non-test lines |
|---|---|---|---|---|
| 1 | <prefix>/01-<slug> | US-1 (AC-1.1, AC-1.2) | trunk | 120 |
| 2 | <prefix>/02-<slug> | US-2 (AC-2.1) | 1 | 200 |

## Layer 1 — <name>

Branch: <prefix>/01-<slug>
Stands alone because: <why a reviewer could approve this layer by itself>
Files:
- Create: `path/to/new_file`
- Modify: `path/to/existing_file:120-145`
- Test: `path/to/thing_test.sh`
Interfaces: Consumes `…` · Produces `…` (as defined under ## Interfaces)
Data touched: <which models from ## Data models this layer creates or changes>
Tests (exact assertions):
- `<the assertion, as the test will state it>`
New pattern (optional): <the pattern's name>, then pseudo-code or a short
snippet showing its shape
Done when: AC-1.1, AC-1.2
Manual: <MT-n IDs in the test plan, or none>

## Layer 2 — <name>

(Same fields, one section per Stack row.)
```

In the Stack table, `#` is the layer number starting at 1. `Branch` is the
bare branch name `<prefix>/NN-<slug>`, without backticks, and each layer's
`Branch:` line repeats it exactly. `Delivers` cites the PRD's `US-n` and
`AC-n.k` IDs. `Depends on` is `trunk` for layer 1 and the previous layer's
number for every other layer. Mark an oversized layer in its
`~non-test lines` cell, e.g. `520 (over ~400)`.

## Self-checks

Before presenting the plan, check each of these and fix what fails:

- **Snippets name a new pattern.** Every snippet or pseudo-code block names
  the new pattern it demonstrates: something with no existing example in the
  codebase for the implementer to copy. If it can't, replace it with a
  `file:line` reference to the existing example.
- **The chain is linear, foundations first.** Layer N depends only on layer
  N−1, shared foundations sit at the bottom, and each layer is meant to pass
  the test suite on its own. Two truly independent groups of layers are two
  plans, not siblings in one.
- **Layers are the right size.** A layer is the smallest unit with its own
  test cycle that a reviewer could reject while approving its neighbours.
  Setup, scaffolding and docs fold into the layer that needs them.
- **Oversized layers are flagged.** Any layer over ~400 changed non-test
  lines is flagged in the Stack table and in the summary given to the human.
  It is a flag, not a refusal: the human decides whether to split it.
- **The plan stays code-light.** If code blocks make up most of the
  document, replace bodies with signatures and assertions. A plan longer
  than the code it describes has written the code instead.

## Output

`issues/plan.md` or `issues/plan-<name>.md`, following the template above,
marked approved only if the human approved it. Nothing else is created or
modified. Suggest `pj-plan-issues` as the next step.
