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
- The change itself. In an unattended run it is not committed yet -- the work
  is reviewed before it is committed, so it arrives staged, and `git diff
  --cached` shows all of it including new files. Reviewing it by hand after the
  fact instead, you'll be given a diff range: the single commit that closed the
  issue (`git show`, or `git diff <base>..HEAD`). If you weren't given either,
  ask rather than guessing at a range.

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

   Two related cases, checked here too. A criterion no automated test
   *could* prove never belonged in the issue — it belonged in the
   manual-test file, and leaving it as a criterion is what stalls an
   unattended run. If the issue has a `## Plan section`, that is the test
   plan named by the `Test plan:` header of the plan it points at. For an
   issue with no `## Plan section`, it is `issues/manual-tests.md`. When
   `## Resolution notes` says a criterion was moved there, open that file
   and confirm the `MT-n` entry is really there (and, in a test plan, that
   the criterion's Traceability row names it): otherwise "moved to manual
   tests" is a way to retire a criterion nobody ever verified.

4. Then review the change on its own merits:
   - **Correctness**: what input or state makes this behave wrong? Prefer one
     concrete failing scenario to a general worry.
   - **Scope**: anything in the diff that no acceptance criterion asked for.
     Unrequested scope is a finding — it's work nobody reviewed the need for.

   How the code reads (naming, simplicity, reuse, consistency) is the
   quality lens's job, `pj-review-quality`, not this one.

5. Check that the tests prove something. For each test in the change, ask:
   would it fail if the implementation were reverted? If you can't convince
   yourself it would, the criterion it stands for is unsupported. Where it's
   cheap and safe, demonstrate it: break the implementation in a scratch
   copy, run the test, and see it fail — never by editing the real tree. An
   empirically confirmed weak test is worth far more than a suspected one.
   Also look for a test that asserts a mechanism (a function was called, a
   file exists) instead of an outcome, and for one that is green for the
   wrong reason: a `set -e` exit before the assertions, a subshell
   swallowing a failure, a fixture that silently wasn't created.

6. Run the test suite yourself (`make test`). Do not take a green claim on
   trust; a review that didn't run the tests should say so explicitly.

7. Triage every finding with one of the severities below.

## Triage

Every finding gets exactly one severity, in its bold label. `pj-review-quality`
uses these same definitions.

- **`[blocking]`**: a correctness bug (a failing or unrun `make test` and a
  quietly reversed PRD decision included), an unsupported or unprovable acceptance
  criterion (including one the resolution notes claim was moved to a manual
  case that isn't there), duplication of existing code, unrequested scope or
  abstraction, or code that can't be followed without the author's
  explanation.
- **`[note]`**: real but minor. It never blocks. It is carried to the stack
  review, which must fix it or explicitly accept it.
- **`[pre-existing]`**: not caused by this change. It never blocks, and is
  listed for `pj-improve-architecture`. A problem this change caused is never
  `[pre-existing]`, however old the code around it.

The verdict is `changes-requested` exactly when at least one finding is
`[blocking]`, and `approved` otherwise, notes or not.

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

`issues/NNN-slug.md` at <commit sha, or "staged">, `make test`: <passed | failed | not run>

## Findings

1. **[blocking] <short label>** — `path/to/file.sh:LINE`
   What's wrong, the concrete case where it goes wrong, and what would fix it.
2. **[note] <short label>** — `path/to/file.sh:LINE`
   ...

## Acceptance criteria

- [x] Criterion text — satisfied by `file:line`, tested by `test_file:line`
- [ ] Criterion text — **claimed but unsupported**: no test asserts this
```

Pick the verdict by the triage rule above: `changes-requested` if any
finding is `[blocking]`, otherwise `approved`.

If there is nothing to say, say so briefly. A review that pads itself with
generic advice trains the next reader to skim it.
