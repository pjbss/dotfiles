---
name: pj-improve-architecture
description: Periodic, read-only codebase health check focused on keeping code navigable and testable for future AI-agent-driven work (e.g. before/after a batch of pj-tdd issues, or weekly). Independent of the PRD/issues flow. Produces a report, not edits.
tags: [workflow, architecture]
---

# Improve Architecture

Purpose: sweep the codebase for accumulating friction that makes it harder
for an agent (or a human) to understand, change, or test — before it
compounds. This is read-only analysis and recommendations, never automatic
refactoring.

## Process

Explore the codebase and look for:

1. **Conceptual confusion points** — places where understanding one
   behavior requires bouncing across many small files or indirection
   layers, with no single place that explains the "why".
2. **Shallow modules** — many tiny files/functions each doing very little,
   forcing a reader (or agent) to hold a lot of files in their head at
   once to understand one behavior. Candidates for deepening: fewer, more
   capable modules behind a simpler interface.
3. **Tight coupling** — modules that can't be understood, changed, or
   tested independently of each other; changing one always drags several
   others along in lockstep.
4. **Testability gaps** — code that's hard to write a fast, isolated test
   against (hidden global state, hard-to-mock I/O, missing seams). These
   directly block `pj-tdd` from working well on the next issue that
   touches this code.

For each finding, present a concrete before/after: the current
interface/shape, and a proposed alternative, with the actual tradeoff
(what specifically gets easier, what it costs) — not a bare "this is bad".

Ask the user if they have a next PRD/issues round in mind, and prioritize
findings that would unblock or de-risk that work specifically, ahead of
generic cleanup.

## Output

A short written report in the conversation: numbered findings, each with
its before/after and tradeoff. No files are created or edited. The user
decides whether to turn a finding into an issue (via `pj-plan-issues`) or
act on it directly.
