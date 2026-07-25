---
name: rails-delta
description: Explain the modern Rails features a just-completed task used versus how the same thing was done in the Rails 4 era — for a legacy Rails maintainer using this project to get up to speed with Rails 8.
argument-hint: <task-number>
---

The audience: a longtime Rails 4.x legacy maintainer. This project exists partly so
they can see what Rails 8 can do; after each task, this rundown is the payoff. Assume
solid Rails fundamentals (AR, callbacks, fixtures, scopes) but nothing after ~4.2.

Produce a rundown for Task $ARGUMENTS (if no number given, the highest-numbered recap
in `.claude/tasks_recap/`). Scope it to the files that task touched — use the recap's
file list, then read the actual code.

## For each feature or idiom that didn't exist (or looked different) in Rails 4

- Show the modern code as written in this repo, linked as `file:line`.
- Show the Rails 4 equivalent the reader would have written, as a real snippet.
- Name the version where it landed (and where old syntax was deprecated/removed).
  If unsure of a version, verify before stating it — wrong version numbers are worse
  than saying "recent Rails".
- Explain the *behavioral* win, not just the syntax — e.g. `normalizes` applying to
  finder conditions matters more than its declarative look.

## Shape

- Order by impact on daily work, not by chronology or file order.
- Distinguish **mandatory** changes (old syntax removed — the reader must learn this)
  from optional sugar (nice, but old habits still compile).
- Briefly cover changes *around* the task visible in its output: generated defaults,
  test-runner behavior, schema-dump format, CI tooling — the things that look alien
  in a diff or terminal even though the task didn't write them.
- Close with what *didn't* change — the muscle memory that still applies — and one
  line on which upcoming task will showcase the next batch (Hotwire, Solid stack,
  Kamal), so the rundowns build on each other.
- Don't pad: skip anything that worked identically in Rails 4. A short honest list
  beats an exhaustive one.
