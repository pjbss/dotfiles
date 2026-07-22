---
name: pj-clarify
description: Turns a vague product idea into a shared understanding through rigorous clarifying questions, before any planning document or code exists. Use at the very start of a new feature/idea, before pj-write-prd. Produces no files — conversation only.
tags: [workflow, planning]
---

# Clarify

Purpose: remove ambiguity from a vague request before committing anything
to a PRD or to code. This is a conversation-only skill — it never creates
or edits a file, and it never writes implementation code.

## Process

1. **Restate the request** back to the user in your own words first, so
   any baseline misunderstanding surfaces immediately, before spending
   effort on deeper questions built on a wrong premise.

2. **Explore the codebase before asking the user anything.** Look for
   existing modules, conventions, related features, and prior art that
   could answer a question outright. Never ask the user something the
   code can already tell you.

3. **Ask questions in focused batches**, not one at a time. Cover, as
   relevant to the request:
   - Scope boundaries — what's explicitly in vs. out
   - Edge cases and failure modes
   - Who/what is affected (users, callers, other systems)
   - Non-functional constraints (performance, security, compatibility)
   - Integration points with existing code/data
   - What "done" looks like, and how it'll be tested

4. **Follow the branches each answer opens.** An answer often implies 2-3
   follow-up questions of its own — chase those down before moving to the
   next topic, rather than working through a flat, pre-planned list.

5. **Keep going until answers stop changing the shape of the solution.**
   Don't stop after one round just because a round happened. A vague idea
   often needs several passes before the picture is stable.

6. Do not write any code or create any files during this skill.

## Output

There is no artifact — the result is a shared understanding captured in
the conversation itself. When the picture feels stable (new questions stop
changing the answer), say so explicitly and suggest moving on to
`pj-write-prd` to turn it into a PRD.
