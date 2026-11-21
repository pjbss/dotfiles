---
name: pj-write-prd
description: Converts an understood product idea (ideally after pj-clarify) into a structured, human-approved PRD at issues/prd.md (or issues/prd-<name>.md), documenting problem, solution, user stories with acceptance-criteria IDs, and key decisions. Use once the idea is well understood and before planning it with pj-write-plan.
tags: [workflow, planning]
---

# Write PRD

Purpose: turn a clarified idea into a single written source of truth, a PRD
under `issues/`, that `pj-write-plan` turns into a plan and
`pj-plan-issues` then cuts into implementable work. Its stories and criteria carry stable IDs so later
documents can trace back to them, and nothing downstream starts from it
until the human has approved it.

## Process

1. If the request still feels vague or underspecified, ask a handful of
   clarifying questions inline first — don't require a separate
   `pj-clarify` pass, but don't skip straight to writing if things are
   still genuinely unclear either.

2. Explore the current repo before writing anything: existing structure,
   conventions, and utilities the solution should build on or reuse.
   Ground every decision in what's actually there, not assumptions.

3. Name the PRD and create it (create the `issues/` directory if it doesn't
   exist yet). It is `issues/prd.md`, or `issues/prd-<name>.md` when another
   PRD already occupies `issues/prd.md`, where `<name>` is a short
   kebab-case name for this effort. Follow this rule exactly: the plan and
   test plan take their names from the PRD's (`prd-<name>.md` →
   `plan-<name>.md` → `test-plan-<name>.md`). If a PRD already exists and
   this is additive work for the same project, read it first and decide
   with the user whether to extend it or write `issues/prd-<name>.md`
   alongside it — don't silently overwrite prior decisions.

4. Write it using exactly this section structure. The skill always writes
   `Status: draft` as the first line; the template shows the two values
   that line can hold. Keep it a plain line, not YAML front matter — other
   skills and the issue loop grep for it, the same way they read the plan's.

```markdown
Status: draft | approved (YYYY-MM-DD)

## Problem Statement

- Concrete pain points or gaps, each grounded in something real (existing
  behavior, actual usage, a specific complaint) — not hypothetical.

## Solution

Prose describing the target end state: what will exist once this is done,
and how it addresses each problem above.

## User Stories

- **US-1**: As a ___, I want ___, so that ___.
  - **AC-1.1**: WHEN ___ THE SYSTEM SHALL ___.
  - **AC-1.2**: ___ (behavioral and testable; EARS phrasing like the line
    above is allowed, not required).
- **US-2**: As a ___, I want ___, so that ___.
  - **AC-2.1**: ___

(One story per distinct capability/behavior, each with 1–4 acceptance
criteria nested under it. Plans, issue files and the test plan cite these
IDs, so keep both `US-n` and `AC-n.k` stable once written — append, don't
renumber.)

## Non-functional Requirements

- **Performance / Compatibility / Security**: each constraint, with the
  exact value where one exists (a time limit, a supported version, a
  permission boundary). The plan's *Global constraints* copies from here.

## Implementation Decisions

- **Short label**: the concrete choice made, and why — including
  alternatives explicitly rejected, when that's useful context later.

## Testing Decisions

State explicitly what testing approach applies to this effort (e.g. TDD
per issue via `pj-tdd`, or a deliberate decision to skip automated tests
and why). Don't leave this implicit.

Then state what about this effort can only be confirmed by a person — a
visual check, driving a real terminal session, anything no test can assert.
Those go into the plan's test plan (`pj-write-test-plan`), drafted alongside
the plan, never into an issue's acceptance criteria: an issue carrying a
criterion no agent can check never completes unattended, and stalls the
whole queue behind it.

## Out of Scope

- Things considered and explicitly excluded, and why — so the next reader
  doesn't relitigate them.

## Further Notes

Anything unresolved or deferred to implementation/planning time.
```

5. Ask the human to approve the written PRD. Summarize the user stories
   back with their criteria IDs (`US-1`: …, `AC-1.1`: …), since that list
   is what everything downstream is built and tested against. Change the
   first line to `Status: approved (<today>)` only after the human
   explicitly approves in conversation. Anything short of that — silence,
   "looks good so far", a request for changes — leaves it `Status: draft`.

Editing an approved PRD sets it back to `Status: draft`, whether the edit
comes from this skill or a later conversation, until the human approves it
again. A downstream skill seeing `draft` is supposed to stop, so never leave
an edited PRD marked approved.

## Output

`issues/prd.md` or `issues/prd-<name>.md`, following the template above,
marked approved only if the human approved it. Nothing else is created or
modified. Suggest `pj-write-plan` as the next step.
