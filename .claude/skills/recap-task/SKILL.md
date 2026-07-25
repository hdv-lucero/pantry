---
name: recap-task
description: Write the recap for a just-completed task to .claude/tasks_recap/, capturing what was built, every judgment call made, and the verified numbers a later reviewer will reproduce.
argument-hint: <task-number>
---

Write the recap for Task $ARGUMENTS. If no task number was given, infer it from the work
just completed in this session.

This file is not a changelog — it is the input to `/review-task`, which reads the design
doc and the working tree and **re-runs every number in it**. Write only claims that
survive that. The recap's job is to make the work checkable and to surface the decisions
a reviewer would otherwise have to reverse-engineer from the diff.

## Before writing

1. Re-read the Task $ARGUMENTS text and acceptance check in `claude-code-initial-tasks.md`.
2. Re-read the `pantry-app-design-doc.md` sections that task cites — the recap must claim
   fidelity to what the doc actually says, not to your memory of it.
3. Run the verification commands **now**, in this session, and use their real output:

   ```sh
   docker compose run --rm app bin/rails test          # full suite
   docker compose run --rm app bin/rails test <path>   # the task's focused tests
   docker compose run --rm app bin/rubocop
   docker compose run --rm app bin/brakeman --no-pager
   ```

   Plus whatever else the acceptance check demands (seeding twice for idempotency, a
   console check, a system test run). Never carry a count forward from earlier in the
   conversation — re-run it.

Write to `.claude/tasks_recap/task-$ARGUMENTS-<kebab-slug>.md`. Keep the
`task-N-*.md` prefix; `/review-task` globs for it.

## Sections

**Header** — completion date, branch, the design-doc sections that govern the task, and
the task text quoted verbatim as a blockquote.

**Files touched** — a table of every file created or modified and what it holds. This is
the scope claim a reviewer spot-checks against the tree, so it must be exhaustive,
including regenerated files (`db/schema.rb`) and files the generator wrote that you then
replaced. State plainly if no gems were added.

**Acceptance** — a table mapping each clause of the task's acceptance check to what
actually happened, with the real numbers (test counts, row counts, offense counts).
Follow it with the exact commands to reproduce them.

**Fidelity to the doc** — for schema tasks, column-by-column against the doc's
`create_table`; for behavior tasks, the specific §-rules implemented. Say explicitly what
was *not* added beyond it (no extra columns, no extra indexes).

**Surface** — the public API this task adds: constants, enums, scopes, class and instance
methods, validations, jobs, routes. One line each. Include the semantics a reviewer can't
infer from the name (boundary conditions, null handling, ordering) and note which are
test-covered.

**Decisions a reviewer should weigh** — the heart of the recap, one subsection per
judgment call. For each: what was decided, why the doc supports it, which test covers it,
and **what to delete if the reviewer disagrees**. Include every decision that went beyond
the literal task text and label it as such. If the doc was ambiguous, quote the ambiguous
line. If the task genuinely conflicted with the doc, CLAUDE.md says stop and flag rather
than resolve — the recap records that you flagged it, not how you patched around it.

**Deliberately not done** — work a reviewer might read as an omission: explicit task
boundaries respected ("no UI yet"), things deferred to a named later task, and anything
the doc's schema implies is absent on purpose. Absent code should read as discipline.

**What the next task inherits** — the entry points, data, and gotchas Task N+1 will build
on, including anything it must be careful to route through (normalization, broadcasts).

**Open questions** — real unresolved tensions only, each parked at the specific future
task that will settle it. Not a wishlist.

## Rules

- Every number is from a command run in this session. If you can't reproduce it, cut it.
- Disclose undisclosed decisions. Anything a reviewer would be annoyed to discover in the
  diff belongs in the recap — especially work outside the task's literal scope.
- Note known limits of your own solutions (empirical lists that aren't exhaustive,
  heuristics that will need revisiting).
- Report faithfully. A skipped step, a failing test, or an unmet acceptance clause goes in
  the recap as such — `/review-task` will find it anyway, and the recap's value is that it
  was honest first.
- Recap only. Don't fix, refactor, or extend the code while writing it.
