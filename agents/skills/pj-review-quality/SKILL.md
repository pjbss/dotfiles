---
name: pj-review-quality
description: Reviews one issue's implementation for code quality -- readability, simplicity, reuse, consistency, leftovers, test readability -- and writes a verdict file at issues/reviews/NNN-slug.quality.md. The second review lens beside pj-review (spec and correctness). Use after pj-tdd finishes an issue.
tags: [workflow, review]
---

# Review an implemented issue for quality

Purpose: check that the change is as simple and readable as it can be while
meeting its criteria, in a context that did not write it. `pj-review` has
already asked whether it does the right thing; this lens asks whether the
next person can follow it and change it. Run against exactly one issue and
one diff range.

You are reviewing, not implementing. Do not fix anything you find — say what
the simpler version is precisely enough that the next pass can make it.

## Inputs

The same as `pj-review`:

- The issue file, in `issues/` or `issues/done/`.
- The change: either the staged change (`git diff --cached`, which includes
  new files) in an unattended run, or a given commit range when reviewing
  after the fact. If you weren't given either, ask rather than guessing.

## Process

1. Read the issue's `What to build` and `Acceptance criteria`, so you know
   the smallest change that would meet them.

2. Read the code around the change, not just the diff: the rest of each file
   it touches, and the helpers and libraries nearby. Reuse and consistency
   can't be judged from the diff alone.

3. Go through the checklist:
   - **Readability**: names say what a thing is or does; each function does
     one thing; control flow is flat; comments explain why, not what.
   - **Simplicity**: the smallest change that meets the criteria. No
     speculative options or parameters, nothing built for a case no
     criterion has, no abstraction with a single caller.
   - **Reuse**: existing helpers are used rather than re-implemented. The
     model case is `has_test_target`, defined at both
     `bin/pj-run-issues:296` and `bin/pj-affected-tests:72` after an earlier
     review flagged the duplicate and approved it anyway.
   - **Consistency**: the change follows the conventions of the code around
     it (naming, error handling, file layout, comment style).
   - **Dead code and debug leftovers**: unused functions or variables,
     commented-out code, stray debug output.
   - **Test readability**: one behaviour per test, each named for the
     behaviour it proves.

4. Guard against over-finding. A reviewer asked to find problems will always
   find something, and fixing every nit adds the very complexity this lens
   exists to prevent.
   - Every finding names the concrete simpler alternative: the existing
     helper to call, the parameter to delete, the shorter name. A finding
     that can't name one isn't a finding.
   - Don't propose new abstractions. Suggesting a new layer, wrapper or
     helper with one caller is the failure this lens catches in others.
   - "No findings" is a valid and expected outcome. Say so briefly.

5. Triage every finding with the severities defined in `pj-review`
   (`[blocking]`, `[note]`, `[pre-existing]`), and pick the verdict by its
   rule. Duplicated code and unrequested abstraction are `[blocking]` there,
   so this lens can block; a naming nit is a `[note]`.

## Output

Write `issues/reviews/NNN-slug.quality.md` (creating `issues/reviews/` if
needed), beside `pj-review`'s `issues/reviews/NNN-slug.md`, starting with
exactly this line, as the first line of the file:

```
Verdict: approved
```

or

```
Verdict: changes-requested
```

The issue loop parses that line the same way it parses `pj-review`'s — keep
it first, exact, and lowercase-hyphenated. Then:

```markdown
## Reviewed

`issues/NNN-slug.md` at <commit sha, or "staged">

## Findings

1. **[blocking] <short label>** — `path/to/file.sh:LINE`
   What's wrong, and the concrete simpler alternative.
2. **[note] <short label>** — `path/to/file.sh:LINE`
   ...
```

If there are no findings, write `None.` under `## Findings` and approve.
