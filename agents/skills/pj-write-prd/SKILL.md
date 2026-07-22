---
name: pj-write-prd
description: Converts an understood product idea (ideally after pj-clarify) into a structured issues/prd.md at the project root, documenting problem, solution, user stories, and key decisions. Use once the idea is well understood and before decomposing it into issues with pj-plan-issues.
tags: [workflow, planning]
---

# Write PRD

Purpose: turn a clarified idea into a single written source of truth,
`issues/prd.md`, that `pj-plan-issues` will later decompose into
implementable work.

## Process

1. If the request still feels vague or underspecified, ask a handful of
   clarifying questions inline first — don't require a separate
   `pj-clarify` pass, but don't skip straight to writing if things are
   still genuinely unclear either.

2. Explore the current repo before writing anything: existing structure,
   conventions, and utilities the solution should build on or reuse.
   Ground every decision in what's actually there, not assumptions.

3. Create `issues/prd.md` (create the `issues/` directory if it doesn't
   exist yet). If one already exists and this is an additive PRD for the
   same project, read it first and decide with the user whether to extend
   it or start a new dated/named PRD file alongside it — don't silently
   overwrite prior decisions.

4. Write it using exactly this section structure:

```markdown
## Problem Statement

- Concrete pain points or gaps, each grounded in something real (existing
  behavior, actual usage, a specific complaint) — not hypothetical.

## Solution

Prose describing the target end state: what will exist once this is done,
and how it addresses each problem above.

## User Stories

1. As a ___, I want ___, so that ___.
2. As a ___, I want ___, so that ___.
   (Numbered, one per distinct capability/behavior. These numbers get
   referenced later by issue files' "User stories addressed" section, so
   keep numbering stable once written — append, don't renumber.)

## Implementation Decisions

- **Short label**: the concrete choice made, and why — including
  alternatives explicitly rejected, when that's useful context later.

## Testing Decisions

State explicitly what testing approach applies to this effort (e.g. TDD
per issue via `pj-tdd`, or a deliberate decision to skip automated tests
and why). Don't leave this implicit.

## Out of Scope

- Things considered and explicitly excluded, and why — so the next reader
  doesn't relitigate them.

## Further Notes

Anything unresolved or deferred to implementation/planning time.
```

5. Confirm the written PRD with the user before treating it as final —
   summarize the User Stories list back to them, since that list is what
   `pj-plan-issues` will build issues against.

## Output

`issues/prd.md`, following the template above. Nothing else is created or
modified. Suggest `pj-plan-issues` as the next step.
