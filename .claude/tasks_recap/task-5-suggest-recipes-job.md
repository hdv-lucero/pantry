# Task 5 Recap — SuggestRecipesJob against the real API

**Completed:** 2026-07-26 · **Branch:** `task-4-suggestion-domain-models`, on top of `4d31f43`
**Governing spec:** `pantry-app-design-doc.md` §5 (the whole section — prompt, exact-name echo rule, content boundaries, preference lists, the link problem, ranking, substitutions, cost & abuse control), §4.2 (run card lifecycle and broadcasting), §2 (SDK and model tier), §8 (testing and fixtures), §3 (`inventory_snapshot`, `Recipe` identity)
**Task text:** `claude-code-initial-tasks.md` → Task 5

> The core LLM integration per §5. Build `SuggestRecipesJob`: snapshot inventory onto the
> run, call the Anthropic API with the web search tool enabled, parse per the doc's rules
> — defensive JSON handling with one corrective retry, exact-name validation against the
> snapshot, URL sanity checks, dropping substitutions not in stock, dropping results
> matching thumbs-downed recipes, upserting `Recipe` rows. Status transitions broadcast
> over Solid Cable per §4.2. Store real captured API responses as fixtures (success,
> malformed JSON, timeout) and test the parser against them with WebMock — the job's
> parsing/retry logic is where the fiddly failure handling lives (§8). Cache by inventory
> fingerprint, per-day run limit, `max_tokens` cap, job timeout, API key in credentials
> (§5 cost control).
>
> Acceptance: with a real API key in credentials, running the job from the console against
> the seeded pantry produces persisted suggestions with live source URLs; parser tests
> green against all three fixture types without network access.

---

## Files touched

### Created

| File | What it holds |
| --- | --- |
| `app/models/inventory_snapshot.rb` | Value object over the JSON in `suggestion_runs.inventory_snapshot`: entry building, the `names` vocabulary, the cache `fingerprint` (83 lines) |
| `app/models/recipe_search.rb` | Orchestrator — prompt → call → parse, with §5's single corrective retry (53 lines) |
| `app/models/recipe_search/prompt.rb` | The system prompt and per-request user message; preference lists; the correction message (196 lines) |
| `app/models/recipe_search/client.rb` | The Anthropic call: streaming, web search tool, `pause_turn` continuation, cost dials, error funnel (171 lines) |
| `app/models/recipe_search/parser.rb` | Every §5 parse rule: fences, defensive JSON, exact-name validation, URL sanity, substitutions, blocklist, dedup, ranking (260 lines) |
| `app/jobs/suggest_recipes_job.rb` | §4.2's lifecycle, the fingerprint cache, timeout, failure messages (103 lines) |
| `app/views/suggestion_runs/_suggestion_run.html.erb` | Minimal four-state card — exists so `broadcast_replace_to` has something to render (41 lines) |
| `lib/tasks/suggestions.rake` | `suggestions:capture_fixture` — one real call, written to the success fixture (42 lines) |
| `test/test_helpers/anthropic_test_helper.rb` | Fixture loading, SSE rendering, WebMock stubs, `without_anthropic_credentials` |
| `test/fixtures/files/anthropic/README.md` | Fixture provenance — what is hand-written, what the live call corrected |
| `test/fixtures/files/anthropic/web_search_success.json` | 5 valid recipes, `end_turn` |
| `test/fixtures/files/anthropic/web_search_malformed.json` | JSON that stops mid-string |
| `test/fixtures/files/anthropic/web_search_dirty.json` | 7 recipes, every §5 filter violated at least once, fenced |
| `test/fixtures/files/anthropic/web_search_pause_turn.json` | `pause_turn`, no text block |
| `test/models/inventory_snapshot_test.rb` | 13 tests |
| `test/models/recipe_search_test.rb` | 8 tests — retry orchestration |
| `test/models/recipe_search/prompt_test.rb` | 21 tests |
| `test/models/recipe_search/client_test.rb` | 21 tests |
| `test/models/recipe_search/parser_test.rb` | 31 tests |
| `test/jobs/suggest_recipes_job_test.rb` | 24 tests |

### Modified

| File | Change |
| --- | --- |
| `Gemfile` / `Gemfile.lock` | **Two gems added** — see below |
| `app/models/suggestion_run.rb` | `DAILY_LIMIT`, `BROADCAST_STREAM`, `today` scope, `daily_limit_reached?`, `within_daily_limit?`, `start!`, `complete!`, `fail!`, `includes_favorite?`, `broadcast_card` (+82 lines) |
| `test/models/suggestion_run_test.rb` | +12 tests for the above (+154 lines) |
| `config/database.yml` | Development split into primary/cache/queue/cable; comment on why test stays single |
| `config/cable.yml` | Development → `solid_cable` |
| `config/cache.yml` | Development → `database: cache` |
| `config/environments/development.rb` | `solid_cache_store`, `:solid_queue` adapter, `solid_queue.connects_to` |
| `config/environments/test.rb` | Explicit `:test` job adapter |
| `docker-compose.yml` | `SOLID_QUEUE_IN_PUMA: 1` enabled |
| `test/test_helper.rb` | `webmock/minitest`, `disable_net_connect!(allow_localhost: true)`, helper require |
| `CLAUDE.md` | Replaced the stale "Task 5 decides the dev queue" note with the settled state; added credentials and no-network-in-tests notes |
| `config/credentials.yml.enc` | Now holds `anthropic.api_key` (§5) |

**Two gems were added, both named in the doc:**

- `anthropic` (1.59.0) — §2: "via the official `anthropic` Ruby SDK (or a thin Faraday client if the SDK fights us — decide during implementation)". It did not fight us.
- `webmock` (3.26.2, test group) — §8 names it explicitly. Pulls `crack`, `hashdiff`; `anthropic` pulls `cgi`, `standardwebhooks`.

**No migrations, no schema change.** `db/schema.rb` is untouched — Task 4's tables carry this task. §6's observability columns (`input_tokens`, `output_tokens`, `duration_ms`) are still absent, as the "Later" list requires.

## Acceptance

| Clause | Status |
| --- | --- |
| With a real key, running the job against the seeded pantry produces persisted suggestions | ✅ **Verified live.** Run #5, 23-entry seeded pantry, completed in ~140s with **5 persisted `RecipeSuggestion` rows** |
| …with live source URLs | ✅ 5 distinct real sites — restlesschipotle.com, nyssaskitchen.com, justinesnacks.com, thekitchn.com, themom100.com |
| Parser tests green against all three fixture types | ✅ `parser_test.rb` → **31 runs, 62 assertions, 0 failures**, covering success, malformed and dirty fixtures |
| …without network access | ✅ `WebMock.disable_net_connect!(allow_localhost: true)` in `test_helper.rb`; no test reaches the API |

Numbers, all from commands re-run while writing this recap:

```sh
docker compose run --rm app bin/rails test                                       # 238 runs, 733 assertions, 0 failures
docker compose run --rm app bin/rails test:system                                #  12 runs,  46 assertions, 0 failures
docker compose run --rm app bin/rails test test/models/recipe_search/parser_test.rb    # 31 runs, 62 assertions
docker compose run --rm app bin/rails test test/models/recipe_search/client_test.rb    # 21 runs, 56 assertions
docker compose run --rm app bin/rails test test/models/recipe_search/prompt_test.rb    # 21 runs, 87 assertions
docker compose run --rm app bin/rails test test/models/recipe_search_test.rb           #  8 runs, 19 assertions
docker compose run --rm app bin/rails test test/models/inventory_snapshot_test.rb      # 13 runs, 36 assertions
docker compose run --rm app bin/rails test test/jobs/suggest_recipes_job_test.rb       # 24 runs, 73 assertions
docker compose run --rm app bin/rails test test/models/suggestion_run_test.rb          # 31 runs, 90 assertions
docker compose run --rm app bin/rubocop                                          # 72 files, no offenses
docker compose run --rm app bin/brakeman --no-pager                              # 0 errors, 0 security warnings (13 models)
docker compose run --rm app bin/rails zeitwerk:check                             # all is good
```

Task 4's suite was 107 + 12 system; this task takes the non-system suite to 238, adding
**131**, and that reconciles exactly:

| Source | Tests |
| --- | ---: |
| `recipe_search/parser_test.rb` | 31 |
| `recipe_search/client_test.rb` | 21 |
| `recipe_search/prompt_test.rb` | 21 |
| `recipe_search_test.rb` | 8 |
| `inventory_snapshot_test.rb` | 13 |
| `jobs/suggest_recipes_job_test.rb` | 24 |
| **six new files** | **118** |
| `suggestion_run_test.rb`, 18 → 31 | +13 |
| **total added** | **131** |

107 + 131 = 238. No other test file was touched.

### The live acceptance run, in full

Not reproducible without spending a call, so recorded here rather than claimed. Enqueued
from a `bin/rails runner` process; executed by the Solid Queue worker Puma forked.

```
run #5: completed, snapshot 23 entries, 5 cards, coverage 1/1

0. Ground Beef Puff Pastry Recipe (Cheeseburger Pot Pie)   [Restless Chipotle]
   https://www.restlesschipotle.com/cheeseburger-pot-pie
   uses: ground beef, yellow onion, cheddar cheese, puff pastry · missing: beef bouillon
1. Super Creamy Dairy Free Carrot Soup                     [Nyssa's Kitchen]
   https://nyssaskitchen.com/autumn-carrot-soup-with-pickled-red-onions
   uses: carrot, yellow onion, garlic, olive oil · missing: fennel, red onion for pickling
2. Greek Yogurt Marinated Salmon                           [Justine Doiron]
   https://justinesnacks.com/greek-yogurt-marinated-salmon
   uses: salmon fillet, greek yogurt · missing: chili paste, lemon
3. Crispy Chicken Thighs with Garlicky Spinach             [The Kitchn]
   https://www.thekitchn.com/recipe-crispy-chicken-thighs-with-lemony-spinach-223121
   uses: chicken thigh, baby spinach, garlic · missing: lemon, nutmeg, butter
4. Easy Vegetarian Black Beans and Rice Recipe             [The Mom 100]
   https://themom100.com/recipe/vegetarian-black-beans-and-rice
   uses: black bean, crushed tomato, rice · missing: tomato paste, vegetable broth, bay leaf, lime juice
```

Three §5 rules are visible in that output and are the reason it is quoted in full:

- **The exact-name echo rule held for all 14 item names.** Every one is the singularized,
  downcased form `PantryItem` stores — `chicken thigh`, `yellow onion`, `black bean`,
  `crushed tomato`, `salmon fillet` — not the recipe's wording. Nothing was dropped.
- **Ranking is 1, 2, 2, 3, 4 missing items** — §4.2's "fewest missing items" order.
- **Near-expiry items were preferred** (§5): chicken thighs expire in 1 day, baby spinach
  in 2, greek yogurt in 6 — all three surfaced.

**Cache hit verified separately:** an identical re-request completed in **0.11s** against
~140s, with the same five titles. §5's "identical re-request within an hour returns cached
results instantly".

### The two live runs that failed first

Recorded because the constants in the tree are the *second* set, and a reviewer will
otherwise wonder why they are so large.

| Run | Config | Outcome |
| --- | --- | --- |
| #3 | 120s request timeout, SDK default `max_retries: 2`, non-streaming | Failed at 290s — `Request timed out` |
| #4 | 300s request timeout, `max_retries: 0`, non-streaming | Failed at exactly 300s — `Request timed out` |
| #5 | 900s timeout, **streaming** | **Completed, 5 cards, ~140s** |

Both failures failed *correctly* — status `failed`, a readable message, no stuck `running`
run — so the failure path is verified by accident as thoroughly as the success path.

## Fidelity to the doc

### §5 rules, rule by rule

| Doc | Where | Test |
| --- | --- | --- |
| "find 3–5 existing, published recipes on the web" | `Prompt::TARGET_COUNT`, `Parser::MAX_RESULTS = 5` | `"more than five usable recipes are trimmed"` |
| "preferring items nearing expiry" | `Prompt#expiry_note` renders "expires in 2 days" | `"expiry is expressed in days"` |
| "Exact pantry coverage is explicitly not required" | System prompt, stated verbatim | `"prefers a real recipe with gaps"` |
| "Respond as JSON matching a fixed schema (title, summary, uses_items, missing_items, substitutions, source_url, source_name)" | `Prompt::SCHEMA`, `Parser::REQUIRED_KEYS` | `"specifies the JSON schema and every field it names"` |
| "Temperature low" | **Flagged, not implemented — see decision 1** | `"sampling parameters are not sent"` |
| "the prompt requires the model to echo `uses_items` and `substitutions.use_instead` verbatim from the snapshot's item names" | System prompt § "Naming" | `"states the exact-name echo rule for both fields"` |
| "any value that isn't an exact match to a snapshot name is dropped (for subs) or flagged (for uses)" | `Parser#validated_uses_items` / `#validated_substitutions` | 3 tests — see decision 3 |
| "never the source recipe's instructions or ingredient list"; "one-to-two-sentence original summary" | Prompt § "Use your own words" + `SUMMARY_LIMIT = 400` | `"summary is capped"` |
| Preference lists, "each a one-line query on the `recipes` table", "sent as title + source URL" | `Prompt#favorites_section` / `#blocked_section`, defaulting to `Recipe.favorites` / `Recipe.blocked` | 4 tests |
| "the blocklist is a prompt instruction *and* a parse-time filter" | Both — prompt section, and `Parser#build`'s `blocked_urls` check | `"a thumbs-downed recipe is dropped even though the model returned it"` |
| "strip code fences, `JSON.parse` inside a rescue, validate against the expected shape, retry once…, then fail the run cleanly" | `Parser#parse` ladder, `RecipeSearch#call` retry | 6 tests |
| Option B — "use the Anthropic web search tool in the API call" | `Client::WEB_SEARCH_TOOL_TYPE` | `"the web search tool is enabled with a use cap"` |
| "a lightweight URL sanity check (scheme, domain not obviously junk)" | `Parser#sanitized_url` | `"urls that fail the sanity check are rejected"` — 10 cases |
| "suggestions sort by fewest missing items by default" | `Parser#rank` | `"results are ranked by fewest missing items"` |
| "any proposed `use_instead` that doesn't match an in-stock item name in the snapshot is silently dropped" | `Parser#validated_substitutions` | `"substitutions are dropped unless…"` |
| "cache by inventory fingerprint (Solid Cache, 1-hour TTL)" | `SuggestRecipesJob::CACHE_TTL`, `InventorySnapshot#fingerprint` | 4 cache tests |
| "a per-day run limit enforced in the controller" | `DAILY_LIMIT` + two predicates — **enforcement point is Task 6, see decision 6** | 4 tests |
| "`max_tokens` capped, and the job wrapped in a timeout" | `Client::MAX_TOKENS`, `SuggestRecipesJob::TIMEOUT` | `"a timeout fails the run"` |
| "API key via Rails credentials, never env-committed" | `Client.credentials_api_key` | 3 tests |

### §4.2, step by step

| Doc | Where |
| --- | --- |
| 1. Controller creates run (`queued`), enqueues job | **Task 6** — no controller exists yet |
| 2. "job snapshots the inventory into the run, flips status to `running` (broadcast via `broadcast_replace_to` → Solid Cable → the card updates live)" | `SuggestionRun#start!` + `broadcast_card`; verified live (a `solid_cable_messages` row was written by the job process) |
| 3. "parses the structured response into `RecipeSuggestion` rows and broadcasts the completed card… sorted by fewest missing items" | `SuggestionRun#complete!`, `Parser#rank` |
| 4. "status goes to `failed` with a human-readable message and a retry button, broadcast the same way" | `SuggestionRun#fail!`; the retry *button* is Task 6 |

**Nothing added beyond the doc's schema.** No migration, no new column, no new index, no
new route. The one new view is the minimum a broadcast needs to render.

## Surface

**`InventorySnapshot`** (new)
- `.current(scope = PantryItem.in_stock)` — groups by `[name, unit]`; quantities sum only within a shared unit, expiry is the soonest in the group; sorted, so two builds of one pantry are byte-identical. Tested.
- `.for(run)` — rebuilds from the run's JSON column; unknown keys dropped, `nil` snapshot yields an empty one. Tested.
- `#names` → `Set` of exact names. `#include?(name)`. `#entries` → array of string-keyed hashes. `#fingerprint` → SHA256 over the entries; unchanged by `touch`, moved by all four fields plus add/remove (6 cases tested). `#empty?`, `#as_json`.

**`RecipeSearch`** (new)
- `Error` — the one class the job rescues; `Client::Error`, `Client::MissingCredentials` and `Parser::Malformed` all descend from it. Tested.
- `#call` → `Result(suggestions:, text:, usage:)`. `text` is the raw reply that parsed, for the cache. Retries **exactly once** on `Parser::Malformed` and never on transport failure. Tested both ways.

**`RecipeSearch::Prompt`** (new)
- `TARGET_COUNT = 3..5`, `SCHEMA`.
- `#system` — frozen across requests (asserted), so it stays cache-friendly.
- `#user_message` — inventory lines, optional notes, favorites and blocklist sections (omitted entirely when empty).
- `#correction_message(error)` — quotes the error, forbids a second search.
- `favorites:` / `blocked:` default to `Recipe.favorites` / `Recipe.blocked`.

**`RecipeSearch::Client`** (new)
- `MODEL = :"claude-sonnet-5"`, `WEB_SEARCH_TOOL_TYPE = "web_search_20260209"`.
- `MAX_TOKENS = 12_000`, `MAX_SEARCHES = 5`, `EFFORT = :medium`, `REQUEST_TIMEOUT = 900`, `MAX_RETRIES = 0`, `MAX_CONTINUATIONS = 2` — all measured, see decision 2.
- `.credentials_api_key` — the single named seam for §5's credentials rule.
- `#call(system:, messages:)` → `Reply(text:, content:, usage:)`. Streams. Resumes `pause_turn` up to twice by replaying the assistant turn with no added user message. Raises on `refusal` and `max_tokens` with distinct messages. `text` is **only** `text` blocks — thinking, `server_tool_use`, `web_search_tool_result` and `code_execution_tool_result` are all dropped. Tested.

**`RecipeSearch::Parser`** (new)
- `MAX_RESULTS = 5`, `SUMMARY_LIMIT = 400`, `NON_PUBLIC_TLDS`, `REQUIRED_KEYS`.
- `#call(text)` → ranked array of attribute hashes with `position` assigned from 0.
  - **`[]` when the model returned `{"recipes": []}`** — a real "nothing found", not retried.
  - **Raises `Malformed` when recipes were returned but none survived** — a broken response, retried.
- `blocked_urls:` defaults to `Recipe.blocked.pluck(:source_url)`; injectable. Tested.

**`SuggestRecipesJob`** (new)
- `CACHE_TTL = 1.hour`, `CACHE_NAMESPACE`, `TIMEOUT = 20.minutes`.
- `discard_on ActiveJob::DeserializationError`. **No `retry_on`** — deliberate, §5.
- Returns immediately unless the run is `queued` (idempotent; tested).
- Cache key is `[namespace, fingerprint, digest(notes)]` — notes are part of identity. Tested.
- Caches the **raw reply**, so filters re-run on a hit. Tested by thumbs-downing a recipe between two cache-hitting runs.

**`SuggestionRun`** (additions)
- `DAILY_LIMIT = 10`, `BROADCAST_STREAM = "suggestion_runs"`.
- `.today`, `.daily_limit_reached?` (≥ limit), `#within_daily_limit?` (counts only runs before this one today). Both tested at the boundary and across a day change.
- `#start!(snapshot)`, `#complete!(results)` (one transaction; rollback tested), `#fail!(message)` (truncates at 500).
- `#includes_favorite?` — §4.3's ★ badge. Tested.
- `after_update_commit :broadcast_card, if: :saved_change_to_status?` — status changes only; a `prompt_notes` or `archive!` write does not broadcast. Tested.

## Decisions a reviewer should weigh

### 1. §5 says "Temperature low". The API rejects it. Flagged, not worked around.

**This is the one place the task conflicts with the doc**, and per CLAUDE.md the rule is to
stop and flag rather than improvise. Flagging it here is that.

§5's prompt paragraph ends "Temperature low." Claude Sonnet 5 — and every current model at
this tier — **removed the sampling parameters**: sending `temperature`, `top_p` or `top_k`
returns a 400. There is no way to honour that sentence as written; the request would fail.

What I did instead of improvising a substitute: sent no sampling parameter, left adaptive
thinking on, and used `output_config.effort` (the supported control) at `:medium`. A test
(`"sampling parameters are not sent"`) asserts all three are absent, so a future edit that
tries to restore the doc's letter fails in the suite rather than in production.

**The doc sentence should be amended**, and I have not amended it — the design doc is the
source of truth and editing it to match my implementation is exactly the improvisation
CLAUDE.md forbids. Suggested replacement for whoever owns the doc: *"Effort low-to-medium;
sampling parameters are not available on current model tiers."*

**Unresolved consequence:** the doc's intent was presumably output stability across runs.
Effort does not give that, and nothing else does either. Two identical requests can return
different recipes. The fingerprint cache hides this for an hour, which is why it did not
show up in testing.

### 2. Every cost and timeout constant is measured, and the first set was wrong

**Beyond the task text**, which just says "`max_tokens` cap, job timeout". I set them by
guess first, and two live runs failed before they were right. The numbers now in the tree:

| Constant | First guess | Now | Why |
| --- | --- | --- | --- |
| `REQUEST_TIMEOUT` | 120s | 900s | One real call took **258s**. 120 and then 300 both killed healthy calls |
| `MAX_RETRIES` | (SDK default 2) | 0 | The default silently turned one timeout into three, consuming the job budget |
| `MAX_TOKENS` | 8,192 | 12,000 | Observed **7,135** output tokens — close enough to truncate the JSON |
| `MAX_SEARCHES` | 8 | 5 | The model spent all 8; input tokens are where the money goes |
| `MAX_CONTINUATIONS` | 3 | 2 | Each continuation is another billable request |
| `TIMEOUT` (job) | 5 min | 20 min | Must fit a call *plus* §5's corrective retry |

The measurement that matters most for §5's cost story: **219,152 input tokens** for one
call. That is the server-side search loop accumulating results, and it means `max_uses` is
a far stronger cost lever than `max_tokens`. At Sonnet 5 introductory rates that is roughly
$0.44 per uncached run.

**Known limit:** these come from two data points (258s and ~140s for the same pantry).
Variance is high and I have not characterised it. `REQUEST_TIMEOUT` is set as a
stuck-connection guard rather than a tuned value, which is defensible only because the
request streams.

**If a reviewer disagrees:** every number is a constant at the top of
`app/models/recipe_search/client.rb`, and none of the tests assert on their values except
`client_test.rb`'s three request-shape tests, which read the constants rather than hardcode
them.

### 3. "Flagged" for a bad `uses_items` name means logged-and-dropped, and the doc doesn't define it

§5: "any value that isn't an exact match to a snapshot name is **dropped (for subs) or
flagged (for uses)**." Dropped is unambiguous. Flagged is not — there is no column to flag
into, and §6's observability columns are on the "do not start" list.

I implemented flagging as: **log a warning naming the recipe and the unmatched values, drop
the value from the stored `uses_items`, and keep the suggestion.** That last clause is what
distinguishes it from a substitution's silent drop.

Dropping the *value* rather than keeping it is the part worth challenging. Keeping it would
be worse in both directions: coverage (§5) would count a name that can never be in stock,
archiving the run early, and §4.3's "I made this" modal would offer a deduction against an
item that does not exist. But it does mean coverage is computed over a slightly optimistic
set.

A recipe whose `uses_items` **all** fail is dropped entirely — a card that uses nothing you
own is not a suggestion. Tested (`"a recipe whose uses_items are all invented is dropped"`).

**If a reviewer disagrees:** `Parser#validated_uses_items` is 12 lines; returning
`string_list(values)` unfiltered restores the doc's most literal reading, and two tests go
with it.

### 4. The cache stores the raw reply, not the parsed rows

**Beyond the task text.** §5 says only "cache by inventory fingerprint". Caching the parsed
`RecipeSuggestion` attributes would be the obvious reading and is what I wrote first.

It breaks a §5 promise. The fingerprint covers the pantry, but a recipe can be thumbs-downed
between two identical requests, and §5 says a blocked recipe "cannot resurface even if the
model ignores the instruction". Cached rows would resurface it for up to an hour. Caching
the reply and re-parsing on every hit costs microseconds and keeps the guarantee.

Covered by `"a recipe thumbs-downed after caching cannot come back from the cache"`, which
asserts both that it was a cache hit (one API request total) and that the blocked card is
gone.

Consequence: a cache hit whose every recipe is now blocked raises `Malformed` inside
`#cached`, which is caught and treated as a miss. Deliberate, commented.

### 5. Streaming, for a response nothing streams to

`RecipeSearch::Client#create` calls `messages.stream(...).accumulated_message` — it streams
and then waits for the whole message anyway. That reads like pointless indirection.

It is the fix for the two failed live runs. A web-search turn spends minutes server-side
sending nothing; a plain POST is one long silence that an HTTP timeout correctly reads as a
dead connection. Streaming keeps events flowing so the timeout means what it should.

**Cost to the test suite, and it is not small:** stubs must now answer in SSE rather than
JSON. `AnthropicTestHelper#anthropic_sse` renders a fixture `Message` into the event
sequence the SDK's accumulator rebuilds it from, so fixtures stay readable JSON.
`client_test.rb`'s `"a fixture survives the round trip through the SSE stub"` asserts that
conversion is lossless — without it, every other client test would assert against a message
the API would never send.

**Bonus, not the reason:** §M4's "staged progress messages" becomes a UI change rather than
a rewrite.

### 6. The per-day limit is enforced in the job as well as (eventually) the controller

§5 says "a per-day run limit enforced **in the controller**". There is no controller until
Task 6, so a literal reading leaves this task's deliverable unimplemented.

I implemented the mechanism (`DAILY_LIMIT`, `.daily_limit_reached?` for the controller,
`#within_daily_limit?` for the job) **and** had the job refuse when over the limit. That is
double enforcement, which §5 itself establishes as the house pattern for the blocklist
("a prompt instruction *and* a parse-time filter").

The two predicates deliberately differ: the class method asks "would a *new* run be over?"
(what a controller needs, before creating anything); the instance method asks "is *this* run
within the allowance?", counting only runs created before it today. Both boundaries tested.

**If a reviewer wants the doc's literal reading:** delete `#within_daily_limit?` and the
guard line in `SuggestRecipesJob#perform`, keep the class method for Task 6, and drop two
tests.

### 7. Development now runs the full Solid stack — four SQLite files

**Well beyond the task text**, though CLAUDE.md did assign "a real development queue" to
this task. I also moved development's cable and cache onto `solid_cable` / `solid_cache`
with their own files.

The queue change forces the other two. With `SOLID_QUEUE_IN_PUMA`, the job runs in a
different process from the request that enqueued it, and both of Rails' generated
development defaults are same-process: the `async` cable adapter only reaches subscribers
inside the broadcasting process, and `:memory_store` is not shared. §4.2's live broadcasts
and §5's fingerprint cache would silently do nothing in development while working in
production — the worst way for a demo to be wrong.

Verified live: the Puma-forked supervisor, dispatcher and worker all start; a job enqueued
from a separate `runner` process was picked up, and its `start!` broadcast wrote a
`solid_cable_messages` row.

**Test deliberately stays a single file** — its queue, cable and cache are all in-process
doubles, so three more files would be created, migrated and never read, once per parallel
worker. Commented in `database.yml`.

**If a reviewer disagrees:** revert `config/cable.yml`, `config/cache.yml`, the two
`development.rb` lines and `docker-compose.yml`; `database.yml`'s development block goes
back to one line. Nothing in `app/` depends on it.

### 8. A test that passed while doing nothing, and what it cost

Worth recording because the fix changed production code.

I first wrote the missing-credentials tests as
`Rails.application.credentials.stub(:dig, nil) { … }`. Two things were wrong.
`ActiveSupport::EncryptedConfiguration#method_missing` answers `stub` with `config[:stub]`
— so it returned `nil` and **never ran the block**. And Minitest 6 has dropped
`minitest/mock` entirely, so `Object#stub` does not exist to be called anyway.

The client test passed regardless, because its surviving assertion (`assert_not_requested`)
is trivially true when no code runs. Only the job test's status assertion caught it.

Two changes came out of it: `RecipeSearch::Client.credentials_api_key` exists as a named
seam (also used by the rake task), and `without_anthropic_credentials` in the test helper
swaps a real singleton method — which cannot fail silently — instead of stubbing Rails
internals. A test asserts the swap is restored afterwards.

**No mocking gem was added**, per CLAUDE.md's no-new-gems-without-justification rule. The
hand-rolled swap is six lines.

### 9. Sonnet, not Opus

§2 says "Model: a fast/cheap tier model is fine for this task", which names a tier rather
than a model. Sonnet 5 is the cheapest tier that still supports `web_search_20260209` —
Haiku 4.5 only offers the older basic `web_search_20250305`, without the dynamic filtering
that keeps search results from flooding the context and the bill.

One constant (`Client::MODEL`). The live run's output quality is in the acceptance section
above; judge it there.

### 10. The fixtures are hand-written, then corrected against a real response

§8 asks for "real captured API responses". These are not verbatim captures, and the README
beside them says so in the first line.

They were written to the shape (checked against the SDK's own model classes, not recalled),
then **amended after the live call revealed two block types the first draft had no idea
about**: a leading `thinking` block with empty text (`display` defaults to `"omitted"`), and
`code_execution_tool_result` blocks that `web_search_20260209` emits because its dynamic
filtering runs code server-side. Both must be skipped by `Client#text_from`, so fixtures
lacking them were testing an easier problem than production faces.

**Why not check in the real capture:** it is 229 KB, of which 143 KB is opaque
`encrypted_content` and `encrypted_stdout` blobs, and the recipes it returns would need
`parser_test.rb`'s success-path assertions rewritten on every re-capture.
`bin/rails suggestions:capture_fixture` exists for anyone who wants to make that trade, and
the README documents the consequences.

**This is the acceptance clause most open to challenge.** The honest statement is: the
parser is tested against fixtures whose *shape* has been validated against a live response,
and the end-to-end behaviour was verified live once, with the output quoted above.

## Deliberately not done

- **No controller, no route, no "Suggest recipes" button.** §4.2 step 1 is Task 6. Nothing
  in the app can start a run except the console.
- **The run card is a skeleton.** `_suggestion_run.html.erb` renders four states plainly and
  exists only so `broadcast_replace_to` has a partial. §4.2's missing-items and substitution
  display, the ★ badge, the retry button, and §4.3's "I made this" modal are all Task 6.
  `#includes_favorite?` is here and unused by any view.
- **No system test for the suggestion flow.** §8 asks for one "with the LLM stubbed"; it
  needs the UI that Task 6 builds. The 12 existing system tests still pass.
- **No observability columns** (`input_tokens`, `output_tokens`, `duration_ms`) — §6, and on
  the explicit "Later (do not start yet)" list. `Client::Reply` carries `usage` and nothing
  persists it.
- **No demo-mode fixture replay** (§6) and **no seeded suggestion runs** — `db/seeds.rb` is
  unchanged.
- **`SuggestionRun.archive_stale!` is not called after a run completes.** Task 4's handoff
  raised it as optional; a run parsed against a pantry that has already moved on stays active
  until the next inventory change.
- **No progress messages during the call.** §M4 stretch. The streaming plumbing is in place
  and nothing consumes the deltas.
- **`RAILS_MASTER_KEY` is still commented out in CI.** The test suite does not need
  credentials — no test reads the key — but the line needs uncommenting and a repo secret
  before anything that does.

## What Task 6 inherits

- **`SuggestionRun#start!` / `#complete!` / `#fail!` are the only status writers**, and each
  broadcasts on `SuggestionRun::BROADCAST_STREAM`. A controller creating a run should leave
  it `queued` and let the job move it.
- **`app/views/suggestion_runs/_suggestion_run.html.erb` is the broadcast target.** Redesign
  it in place — the partial path and `dom_id` target are wired into `broadcast_card`. Keep
  the four-state branch or broadcasts will render blank cards.
- **`SuggestionRun.daily_limit_reached?` is the controller's guard** (§5). Check it before
  creating the run; the job's `#within_daily_limit?` is the backstop, not the UX.
- **`recipe_suggestions` are already ranked and positioned**; `.ordered` reads `position`.
  `#missing_items` and `#substitutions` are arrays of plain strings / `{"missing", "use_instead"}`
  hashes, ready to render.
- **`#includes_favorite?` is the ★ badge**, already tested.
- **Cooking a recipe will zero pantry items**, and each zeroed item triggers a full
  `archive_stale!` pass plus a `PantryItem::INVENTORY_STREAM` refresh broadcast (Task 4's
  note). Whether that wants batching is Task 6's call.
- **`InventorySnapshot.for(run)`** rebuilds what the model saw, for the modal's quantity
  math against a run that may be older than the pantry.
- **Tests must not reach the network.** `test_helper.rb` enforces it; use
  `stub_anthropic(:web_search_success)` for the stubbed system test §8 asks for.

## Open questions

1. **§5's "Temperature low" needs amending in the doc** (decision 1). Not mine to change.
   Due before M2 is called done, since the doc is the source of truth and currently
   specifies something the API rejects.
2. **Output is not reproducible across runs**, and nothing makes it so now that temperature
   is gone. Matters most for §6's demo mode, which is fixture-replay anyway — so the real
   question is whether live suggestions ever need to be repeatable. Due at Task 7 (demo mode).
3. **~$0.44 and 2–4 minutes per uncached run** (decision 2). Both are sized off two samples.
   `MAX_SEARCHES` is the lever. Due when there is enough real use to characterise variance —
   and it interacts with §6's decision to disable live calls for the demo account entirely.
4. **A 20-minute job timeout holds a worker thread.** Fine for one user with three threads;
   worth revisiting if M3's deploy ever serves more than one.
5. **Sites that key recipes off a query string** (`/recipes?id=1234`) still collapse onto one
   `Recipe` row — Task 4's decision 3 flagged it, and `Parser#sanitized_url` only closes the
   homepage-plus-query case. No fixture uses one and nothing detects it. Due whenever a real
   suggestion comes back wrong.
