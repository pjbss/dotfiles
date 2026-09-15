---
name: pj-commit
description: Writes one commit per completed issue, with a subject that says what changed and a body that says why. Use when closing out an issue, and any time a commit message needs writing.
tags: [workflow, git]
---

# Commit

Purpose: leave a history that can be reviewed one issue at a time, months
later, by someone who wasn't there.

## Scope of a commit

One issue, one commit. That's what makes the review step tractable: the
reviewer gets exactly the change that claims to satisfy exactly one set of
acceptance criteria.

If you find yourself wanting to commit half an issue, or two issues together,
the issue was decomposed wrong — say so rather than papering over it with
commit boundaries that don't match the work.

## Message format

```
<imperative subject, <= 72 chars, no trailing period>

<Body: what was wrong or missing, and why this is the fix. Wrap at 72.
Prefer explaining the reasoning that isn't recoverable from the diff --
the alternative you rejected, the failure this prevents, the surprising
constraint you hit -- over restating what changed.>

Issue: issues/NNN-slug.md
```

- **Subject**: imperative mood ("Add", "Fix", "Guard"), naming the behavior
  that changed, not the files touched. `Fix pj-sbx-teardown stranding
  sandboxes when the Lima VM is already gone` — not `update teardown`.
- **Body**: required for anything but a typo. The diff already says what
  changed; the body is the only place the *why* can live. If a real failure
  prompted the change, describe it concretely, including how it was confirmed.
- **`Issue:` trailer**: the issue file this closes. Note `issues/` is
  gitignored working state, so this is a reference for the person reading the
  history during the run, not a link that survives in the repo.

## Before committing

1. `git status` and `git diff --staged` — review your own change first. Stage
   deliberately; never `git add -A` without reading what it swept up.
2. Confirm nothing unrelated snuck in: stray debug output, a reformatted file
   nobody asked about, a credential or token of any kind.
3. `make test` must be green. A commit is a claim that the tree works.

## Never

- Never `git push`. Pushing is a separate, human decision, and inside a
  sandbox there are deliberately no push credentials at all.
- Never amend or rebase a commit that isn't yours from this run.
- Never commit the `issues/` tree. It's gitignored on purpose.
