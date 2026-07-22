---
name: pj-tdd
description: Implements one local issue file end-to-end via strict red-green-refactor TDD, then checks off its acceptance criteria and moves it to issues/done/. Use when starting implementation work on a specific issues/NNN-*.md file.
tags: [workflow, tdd, implementation]
---

# TDD Implement

Purpose: implement exactly one issue file at a time, test-first, and close
it out cleanly.

## Pick an issue

Pick (or accept from the user) exactly one issue file from `issues/` (not
`issues/done/`) whose `Blocked by` is either `None - can start immediately`
or where every referenced issue already lives in `issues/done/`. If every
remaining issue is still blocked, say so and stop rather than guessing at
one out of order.

## Before writing any code

1. Re-read the issue's `What to build` and `Acceptance criteria` in full,
   plus its Parent PRD, for context.
2. Confirm the interface/contract you intend to add or change (function
   signatures, CLI flags, file formats, etc.) and state it back before
   touching code.
3. Identify the discrete list of behaviors that need a test, mapped 1:1 to
   the acceptance criteria wherever possible.
4. Check whether this issue is actually implementable unattended. Flag
   (and stop, without touching real system state) any acceptance criteria
   that require acting on the real, non-sandboxed environment (a real
   `$HOME`, real cloud resources, anything standing guidance says must be
   sandboxed instead) or that require a human physically validating
   something (a visual UI check, driving a real terminal session). Do the
   safe portions and clearly list what's left for a human, rather than
   forcing those parts through.

## Red-green-refactor loop

Repeat per behavior identified above:

1. Write exactly one failing test for the next behavior. Run it and
   confirm it fails for the expected reason (not a typo or setup error).
2. Write the minimum implementation needed to make it pass. Run it and
   confirm it's green, and that no previously-passing test regressed.
3. Refactor if there's obvious duplication or a clear clarity win, keeping
   every test green throughout.
4. Move to the next behavior.

## Closing out

- **Full completion**: check off every `- [ ]` to `- [x]` in the issue
  file, run the full test suite once more, add a `## Resolution notes`
  section describing what was actually built/decided (especially anything
  that deviated from the original "What to build"), then `git mv` the file
  into `issues/done/`.
- **Partial completion** (some criteria are HITL-only per the flag above):
  leave those specific boxes unchecked, add a `## Notes (autonomous pass,
  <date>)` section explaining exactly what's left and why, and leave the
  file in `issues/` (not `issues/done/`) until a human finishes the rest.

Never invent acceptance criteria that aren't in the issue file. If the
issue turns out to be missing something essential to build it correctly,
stop and ask rather than silently expanding scope.
