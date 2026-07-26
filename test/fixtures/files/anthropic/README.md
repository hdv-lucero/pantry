# Anthropic API response fixtures

§8 asks for "a small VCR-style fixture set of real API responses kept in the repo" so
the parsing tests are honest. These back `test/models/recipe_search/*_test.rb` and
`test/jobs/suggest_recipes_job_test.rb`, all of which run with
`WebMock.disable_net_connect!` — no test in this suite can reach the API.

## Provenance — read this before trusting them

**These four files are hand-written to the response shape, then corrected against a
real call.** They are not verbatim captures. Field names, block types and nesting were
checked against the installed `anthropic` gem's own models (`ServerToolUseBlock`,
`WebSearchToolResultBlock`, `WebSearchResultBlock`, `Usage`) rather than recalled.

A live call was then made during Task 5 (23-item seeded pantry, 258s, 219k input /
7.1k output tokens, 8 searches) and the fixtures were amended to match what actually
came back. Two block types were missing from the first draft, and both matter here:

- **A leading `thinking` block** whose `thinking` text is empty. That is not an
  omission — `thinking.display` defaults to `"omitted"` on this model, so the block
  arrives carrying only a signature.
- **`code_execution_tool_result` blocks**, one per search round. `web_search_20260209`
  does its dynamic filtering by running code server-side, so these appear without ever
  being asked for. (The matching lesson for the request side: do *not* also declare
  `code_execution` in `tools` — a second execution environment confuses the model.)

Both are blocks `RecipeSearch::Client#text_from` has to skip, so fixtures lacking them
were testing an easier problem than production faces.

Three deliberate departures from a verbatim capture, so nobody mistakes them for API
behaviour:

- `encrypted_content` and `encrypted_stdout` are truncated to short placeholders. Both
  are multi-kilobyte opaque blobs in reality — 143 KB of a 229 KB response — nothing in
  the app reads them (the client keeps only `text` blocks, §5's content boundary), and
  faithful ones would make these files unreviewable.
- `id` values are fixed rather than per-response, so diffs stay legible.
- Block *counts* are representative, not literal: the real success response had 59
  content blocks across 8 searches, and the fixture has 8 across 2.

## Replacing them with a real capture

With `anthropic.api_key` in credentials:

```sh
docker compose run --rm app bin/rails suggestions:capture_fixture
```

That makes one real web-search call against the **seeded development pantry** and
writes `web_search_success.json` from the response. It costs a live call and roughly
half a dollar at current rates (the input-token count is the expensive part — see
`RecipeSearch::Client::MAX_SEARCHES`).

Two things to expect if you run it. The file becomes ~230 KB of mostly opaque blobs
rather than something you can read in review, and the recipes it returns will differ
from the ones below — so `recipe_search/parser_test.rb`'s success-path assertions will
need their titles, counts and ranked order updated to match. That trade is why the
checked-in fixture is the hand-written one: this task's live verification is recorded
in the recap (`.claude/tasks_recap/task-5-suggest-recipes-job.md`) with the actual
recipes and URLs it produced, which is the honest version of "we ran it for real"
without making the fixture unreviewable.

The other three are derived, not captured, and stay that way by design: a malformed
reply and a `pause_turn` are not outcomes you can ask the API for on demand.

## What each file is for

| File | Shape | What it exercises |
| --- | --- | --- |
| `web_search_success.json` | `end_turn`, two search rounds, five valid recipes | The happy path, plus both ranking tiebreaks (fewest missing → most used → title) |
| `web_search_malformed.json` | `end_turn`, JSON that stops mid-string | §5's corrective retry; the shape a truncated or derailed reply actually takes |
| `web_search_dirty.json` | `end_turn`, valid JSON in a ```json fence, seven recipes | Every §5 filter at once — fence stripping, a blocked recipe, a duplicate URL, a junk host, invented item names, three bad substitutions, a missing field |
| `web_search_pause_turn.json` | `pause_turn`, no text block | The server-side search loop asking to continue |

The pantry these were written against is `test/fixtures/pantry_items.yml` (milk, greek
yogurt, egg, ground beef, rice, olive oil), and the blocked recipe in
`web_search_dirty.json` is `recipes(:tuna_casserole)`, whose `make_again: false` is
what the parse-time blocklist filter keys on.
