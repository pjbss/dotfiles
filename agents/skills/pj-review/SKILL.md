---
name: pj-review
description: Reviews one issue's implementation against its acceptance criteria and writes a verdict file under issues/reviews/. Use after pj-tdd finishes an issue, especially in an unattended run where nobody watched the work happen.
tags: [workflow, review]
---

# Review an implemented issue

Purpose: check that what was actually built matches what the issue asked for,
in a context that did not write it. Run against exactly one issue and one diff
range.

You are reviewing, not implementing. Do not fix anything you find — say what's
wrong precisely enough that the next pass can fix it.

## Inputs

- The issue file. In a normal run it has just been moved to `issues/done/`,
  so check both `issues/` and `issues/done/`.
- A diff range, usually the single commit that closed the issue
  (`git show`, or `git diff <base>..HEAD`). If you weren't given one, ask
  rather than guessing at a range.

## Process

1. Read the issue's `What to build` and `Acceptance criteria` **before**
   reading the diff. Reading the diff first makes it far too easy to
   rationalize what's there as what was asked for.

2. Read the Parent PRD's `Implementation Decisions` and `Testing Decisions`.
   An implementation that quietly reverses a decision recorded there is a
   finding even when it passes every acceptance criterion.

3. For each `- [x]` acceptance criterion, find the specific change in the diff
   that satisfies it and the specific test that proves it. A checked box with
   no corresponding test is an **unsupported claim** — report it as such. This
   is the single most valuable thing this review does: nothing else in the
   pipeline distinguishes "built and verified" from "marked done".

4. Then review the change on its own merits, in this order:
   - **Correctness**: what input or state makes this behave wrong? Prefer one
     concrete failing scenario to a general worry.
   - **Tests**: do they assert the behavior, or merely that the code ran?
     Would they fail if the implementation were reverted?
   - **Scope**: anything in the diff that no acceptance criterion asked for.
     Unrequested scope is a finding — it's work nobody reviewed the need for.
   - **Fit**: does it match the conventions of the code around it, and reuse
     what's already there rather than reimplementing it?

5. Run the test suite yourself (`make test`). Do not take a green claim on
   trust; a review that didn't run the tests should say so explicitly.

## Output

Write `issues/reviews/NNN-slug.md` (creating `issues/reviews/` if needed),
starting with exactly this line, as the first line of the file:

```
Verdict: approved
```

or

```
Verdict: changes-requested
```

That line is parsed by `pj-run-issues` to decide whether to continue — keep it
first, exact, and lowercase-hyphenated. Then:

```markdown
## Reviewed

`issues/NNN-slug.md` at <commit sha>, `make test`: <passed | failed | not run>

## Findings

1. **<short label>** — `path/to/file.sh:LINE`
   What's wrong, the concrete case where it goes wrong, and what would fix it.

## Acceptance criteria

- [x] Criterion text — satisfied by `file:line`, tested by `test_file:line`
- [ ] Criterion text — **claimed but unsupported**: no test asserts this
```

Use `changes-requested` for: a failing or unrun test suite, an unsupported
acceptance criterion, a correctness bug, or a reversed PRD decision. Style
preferences alone are not grounds for it — note them under Findings and
approve.

If there is nothing to say, say so briefly. A review that pads itself with
generic advice trains the next reader to skim it.
