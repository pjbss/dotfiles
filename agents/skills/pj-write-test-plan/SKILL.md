---
name: pj-write-test-plan
description: Owns the QA test plan for a planned feature (issues/test-plan[-name].md) -- drafts it alongside the plan so every acceptance criterion has a planned automated test or a manual case, then finalizes it after the stack review from what the per-layer reviews actually recorded. Use from pj-write-plan's last step (draft), and once the stack has been reviewed (finalize).
tags: [workflow, planning]
---

# Write test plan

Purpose: one document a person can test the feature from, and the one place
human-only checks go for planned work. It traces every acceptance criterion
to either an automated test or a manual case, so nothing is silently left
unverified. It is drafted with the plan, so the human approves the design
and the manual surface together, and finalized after the stack review from
recorded evidence only.

The skill has two modes. Run the one asked for; if it isn't clear, a test
plan that doesn't exist yet means draft, and one marked `Status: draft`
after the stack has been reviewed means finalize.

## Draft mode

1. Read the plan: the path given as an argument, else `issues/plan.md`.
   Its `Test plan:` header names the file to write, and its `PRD:` header
   names the PRD. Read both. The plan doesn't have to be approved yet:
   `pj-write-plan` drafts the test plan before asking for approval. If the
   test plan already exists, read it and ask before replacing it.

2. Write the test plan with the template below. The skill writes it with
   `Status: draft`, and fills the header's `Stack:` line from the plan's
   `## Stack` table, without commits yet.

3. Fill the Traceability table so that every `AC-n.k` in the PRD has a row,
   and each row has a planned automated test or a manual case (or both).
   A planned test comes from a layer's "Tests (exact assertions)" and is
   written as `planned: Layer N`, since no file exists yet. A criterion
   with neither is a gap: add a manual case if a person can check it,
   otherwise report the gap so the plan gets a test for it. Don't leave
   the row empty.

4. Write a manual case for every check only a person can make (a visual
   check, driving a real terminal session). The plan's per-layer `Manual:`
   lines name these IDs, so keep the two in step.

5. Seed the exploratory charters with one charter per `## Review focus` item
   in the plan, each one's `From:` line naming the item it came from.

6. List anything deliberately left untested under Known limitations, with
   the reason.

## Finalize mode

Run after the stack review, when every layer's spec review exists.

1. Read the test plan (the path given, else the one named by the
   `Test plan:` header of `issues/plan.md`) and the plan its `Plan:` header
   names.

2. Fill each criterion's Automated test cell only from the "tested by
   `file:line`" entries that the per-layer spec reviews recorded: the
   `issues/reviews/NNN-slug.md` files of the issues whose `## Plan section`
   names this plan, in the format `pj-review` writes under "Acceptance
   criteria" (not the `.quality.md` files). Replace each `planned:` entry
   with what the review recorded.

3. Record each layer's commit: run `git rev-parse <branch>` for every branch
   in the plan's `## Stack` table, and write the short hash after each
   branch on the `Stack:` line, e.g. `Stack: main ← f/01-parse (3f2a91c) ←
   f/02-apply (8be04d7)`. If a branch doesn't resolve, don't finalize:
   report which one and leave `Status: draft`.

4. Never invent a test location. A criterion with no recorded test and no
   manual case stays blank and is listed under Known limitations, even when
   a likely-looking test exists: the point of the column is that a
   reviewer saw the test prove the criterion.

5. Set `Status: final (<today>)`. Leave the manual cases' result lines and
   the sign-off for the person testing.

## Template

```markdown
# Test plan — <feature>

Status: draft | final (YYYY-MM-DD)
Plan: <path>
Stack: <trunk> ← <layer branches…>

## 1. Scope

What each layer changed, one line per layer. Then what is out of scope,
copied from the PRD.

## 2. Environment & preconditions

OS, tool versions, fixtures, how to get the build (check out the top
branch), and how to reset state between runs.

## 3. Traceability

| Story | Criterion | Automated test | Manual |
|---|---|---|---|
| US-1 | AC-1.1 | agents/test/thing_test.sh:42 | — |
| US-1 | AC-1.2 | — | MT-1 |

## 4. Manual test cases

### MT-1 — <name>

Source: US-1 · Layer: <prefix>/01-<slug>
Preconditions: <state the system must be in first>

| # | Step | Expected |
|---|---|---|
| 1 | <action> | <what passing looks like> |

Result: ☐ pass ☐ fail · Notes:

## 5. Exploratory charters

### EC-1 — Explore <area> with <resources> to discover <risk>

From: plan Review focus #1
Timebox: 30 min
Findings:

## 6. Known limitations / not tested

- <criterion or area>: <why it isn't covered>

## 7. Sign-off

Tested by: · Date: · Build (top commit): · Outcome:
```

Header values are bare, without backticks, one `Key: value` per line. Each
header line and heading is exact, because the issue loop reads the
`Status:` line.

`MT-n` and `EC-n` numbering is per test plan, starting at 1 and append-only:
a later `pj-tdd` pass that moves a criterion here takes the next free
number, and a dropped case keeps its ID. References elsewhere always name
the file with the ID (`issues/test-plan.md` MT-3), since another test plan
has its own MT-3.

## Output

Draft mode: the test plan the plan's `Test plan:` header names, with
`Status: draft`. Finalize mode: the same file, with recorded test
locations, layer commits, and `Status: final (<today>)`. Nothing else is
created or modified.
