---
name: review-task
description: Review a completed task's recap against the design doc, the task definition, and the current codebase, reproducing every checkable claim instead of taking it on faith.
argument-hint: <task-number>
---

Review Task $ARGUMENTS end-to-end. If no task number was given, use the
highest-numbered recap in `.claude/tasks_recap/`.

## Gather the three sources

1. `claude-code-initial-tasks.md` — the Task $ARGUMENTS text and its acceptance check.
2. `pantry-app-design-doc.md` — read the sections the task and recap cite (don't skim;
   the doc is the source of truth for every decision).
3. `.claude/tasks_recap/task-$ARGUMENTS-*.md` — the recap written after implementation.

## Verify against the working tree

- Read every file the recap claims was touched. Confirm the described state matches
  the code as it is right now — the recap may have drifted from later edits.
- **Reproduce every checkable claim.** Never repeat a number from the recap without
  running it: full test suite, the task's focused tests, rubocop, brakeman
  (all via `docker compose run --rm app ...` — there is no Ruby on the host), and any
  reproduce steps the recap lists (seed idempotency, console checks, etc.). Compare
  actual counts and output against the recap's claims.
- Spot-check scope: nothing touched beyond the claimed file list, and explicit task
  boundaries respected (e.g. "no UI yet" means no controllers/routes/views). If the
  repo has commits, diff; if not, spot-check the likely leak points.

## Weigh the judgment calls

- For each decision the recap discloses, judge it against the design doc: is it a
  doc-consistent reading, or an improvised resolution of a conflict? CLAUDE.md says
  conflicts must be flagged, not resolved — call out any that weren't.
- Check undisclosed decisions too: anything in the code the recap *didn't* mention
  that a reviewer should have been told about.
- Sanity-check the recap's open questions: are they real, and parked at the right
  future task?

## Report

Lead with the verdict (accurate/inaccurate, acceptance passed/failed). Then:
a verified-claims list showing what was reproduced and whether it matched; schema/task
fidelity; an assessment of each judgment call; discrepancies (if any) ranked by
severity; minor observations that don't block. Reference code as `file:line` links.
Findings only — don't fix anything unless asked.
