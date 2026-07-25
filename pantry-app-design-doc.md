# Design Doc: Pantry — Inventory & Recipe Suggestions

**Status:** Draft v0.1
**Purpose:** Portfolio project demonstrating modern Rails (Hotwire, SQLite-in-production, the Solid stack) on a small but real problem.

## 1. Overview

Pantry is a single-user (initially) web app for tracking what's in your fridge, freezer, and pantry, with an AI-powered feature that looks at your current inventory and surfaces recipes you could actually make. A hard product constraint: the AI only searches for and suggests existing, published recipes from the web — it never generates recipes of its own. Every suggestion must trace back to a real source.

The point of the project is less the domain and more the demonstration: this should read, to anyone browsing the repo, as an example of what a 2026-era Rails app looks like when you lean into the defaults rather than reaching for Postgres, Redis, Sidekiq, and a React frontend out of habit. The LLM feature is deliberately chosen because it forces the app to deal with slow external calls, background work, and progressive UI updates — exactly the territory where Hotwire and the Solid gems either shine or fall over, which is what we want to find out.

### Goals

Demonstrate Turbo (frames, streams, morphing) and Stimulus doing real interactive work without any custom JSON API or frontend framework. Run SQLite as the production database, including as the backing store for jobs, cache, and websockets via Solid Queue, Solid Cache, and Solid Cable. Integrate an LLM call cleanly: asynchronous, streamed to the browser, resilient to failure, and honest about the hallucinated-URL problem. Keep the whole thing deployable to a single cheap VPS with Kamal, backed up with Litestream.

### Non-goals

Multi-user households, sharing, or permissions (schema shouldn't preclude it, but no UI). Barcode scanning, receipt OCR, or grocery-list generation — tempting scope creep, all of it deferred. Nutrition tracking. Native mobile. Perfect recipe matching; "useful suggestions most of the time" is the bar.

## 2. Stack

**Rails 8.x** on Ruby 3.4, generated with defaults: importmap, Propshaft, Turbo, Stimulus. Tailwind via `tailwindcss-rails` for styling (keeps the asset story no-build). Authentication via the Rails 8 built-in auth generator — arguably more than a single-user app needs, but it's on-theme (session management, password reset, and rate-limited sign-in with zero gems is part of the Rails 8 pitch), and it keeps the door open for household members later without schema surgery.

**SQLite** for everything. Rails 8 ships sane production defaults now (WAL mode, `IMMEDIATE` transactions, a reasonable busy timeout), so most of the folklore about SQLite melting under Rails no longer applies for a single-node app. We'll use three separate databases as Rails 8 encourages — `production.sqlite3` for the app, plus dedicated files for queue, cache, and cable — which sidesteps write contention between app traffic and job polling.

**Solid Queue** for background jobs (the LLM call), **Solid Cache** for caching suggestion results, **Solid Cable** for Turbo Streams broadcasting. Zero Redis, zero external services beyond the LLM API.

**Anthropic API** for the LLM call, via the official `anthropic` Ruby SDK (or a thin Faraday client if the SDK fights us — decide during implementation). Model: a fast/cheap tier model is fine for this task.

**Kamal 2** for deployment to a single VPS, **Litestream** replicating the SQLite files to object storage for backup. This pairing is part of the portfolio pitch: total infra is one box and one S3 bucket.

## 3. Domain Model

The schema is intentionally small. Three tables carry the app; a fourth records suggestion runs so results are persistent and shareable.

```ruby
create_table :pantry_items do |t|
  t.string  :name, null: false
  t.decimal :quantity, precision: 8, scale: 2, default: 1
  t.string  :unit                 # "g", "ml", "pcs", "cans" — free text, normalized lightly
  t.integer :location, null: false, default: 0   # enum: pantry / fridge / freezer
  t.integer :category             # enum: produce / dairy / protein / grains / condiments / other
  t.date    :expires_on
  t.timestamps
end
add_index :pantry_items, :location
add_index :pantry_items, :expires_on

create_table :suggestion_runs do |t|
  t.integer  :status, null: false, default: 0    # enum: queued / running / completed / failed
  t.datetime :archived_at                        # set when inventory coverage drops — see §5
  t.text     :inventory_snapshot                 # JSON of items at time of request
  t.text     :prompt_notes                       # optional user free-text ("something quick", "vegetarian")
  t.text     :error_message
  t.timestamps
end
add_index :suggestion_runs, :archived_at

create_table :recipes do |t|
  t.string  :source_url, null: false   # normalized: tracking params & fragments stripped
  t.string  :source_name
  t.string  :canonical_title
  t.boolean :make_again                # the verdict — one row per recipe, latest tap wins
  t.timestamps
end
add_index :recipes, :source_url, unique: true

create_table :recipe_suggestions do |t|
  t.references :suggestion_run, null: false, foreign_key: true
  t.references :recipe, null: false, foreign_key: true
  t.string  :title, null: false  # as presented in this run
  t.text    :summary
  t.text    :uses_items          # JSON array of item names it consumes
  t.text    :missing_items       # JSON array of things you'd need to buy
  t.text    :substitutions       # JSON: [{missing:, use_instead:}] — on-hand subs only, see §5
  t.datetime :cooked_at          # set by the "I made this" flow — see §4.3
  t.integer :position
  t.timestamps
end
```

Notes on the model. `PantryItem` deliberately avoids a normalized `ingredients` master table — for a single user, free-text names plus light normalization (downcasing, singularizing on save) is the right amount of engineering, and it keeps the LLM prompt trivially constructible. `RecipeSuggestion` is a join between a run and a `Recipe`: per-run presentation and overlap data (title as shown, summary, uses/missing/subs, position, `cooked_at` as an event) belong to the suggestion; canonical identity and the `make_again` verdict belong to the recipe. `inventory_snapshot` on the run exists so a suggestion remains interpretable after the pantry changes; it also makes runs replayable when tuning the prompt. JSON-in-text columns are fine here — SQLite has real JSON functions if we ever need to query into them, and Rails `serialize`/`store` handles the ergonomics.

### Why `Recipe` exists — and why it didn't at first

This schema went through one structural revision during design review, and the reasoning is worth preserving because the sequence matters as much as the result.

The first draft had no `Recipe` table. Suggestions were flat, run-scoped rows carrying their own `source_url` — and that was the correct design for what the app then was. A suggestion was a disposable artifact: generated, considered, cooked or ignored, eventually archived with its run. Nothing ever referred to a recipe twice, so "the same recipe" was not a concept the system needed, and modeling it anyway would have been speculative normalization — the same over-engineering we deliberately refused for ingredients. Designing identity for things that don't recur is how small apps grow join tables nobody queries.

What changed was the thumbs feature (§4.3). Thumbs-up created the app's first *cross-run promise* — "resurface this recipe whenever the inventory fits" — and the moment the system promises to bring the same recipe back, sameness becomes real and something must define it. The flat design failed immediately and concretely: a resurfaced favorite would insert a second row for the same recipe with a null verdict beside the old row's thumbs-up, scattering one opinion across contradictory records. And the verdict wasn't alone — once identity existed, other features started leaning on it. The do-not-suggest filter must recognize a returning recipe to drop it. The favorites badge on a run ("includes one of your favorites ★") is a join over identity. Within-run duplicate detection falls out of the upsert for free. Even `cooked_at` got more useful: "you've made this three times" is a cross-run question flat rows can only answer by ad-hoc URL matching.

Hence the extraction: `Recipe` keyed by normalized `source_url` (query params and fragments stripped, so tracking-parameter variants don't split identity), upserted during parsing, holding exactly the recipe-level facts — canonical title, source, verdict. The alternative was considered: a minimal verdict side-table keyed by URL, keeping suggestions flat. But that is the `recipes` table minus the foreign key — the same normalization and uniqueness obligations, with every lookup done by string-matching at query time instead of a join. Same concept, worse ergonomics.

The resulting asymmetry is the design principle in miniature: ingredients stay denormalized because nothing there recurs with identity; recipes are normalized because a feature forced recurrence. The test that the table is carrying its weight rather than being architecture for its own sake: if the preference feature were cut from scope, `Recipe` would be cut with it.

## 4. Core Flows & Hotwire Usage

### 4.1 Inventory management

The main screen is the inventory, grouped by location (fridge / freezer / pantry), each group a Turbo Frame. Interactions, and what they demonstrate:

**Quick add** — a persistent inline form at the top of each group. One text input that accepts natural notation — `Bok Choi x3 stalks` — parsed server-side with a small regex (`name x quantity unit`, quantity defaulting to 1, unit optional with a `<datalist>` of previously used units as fallback fields). Submits over Turbo, appends the new item to its group via a Turbo Stream response, resets the form. Demonstrates streams from controller responses (no broadcast needed for the actor's own tab), plus a bit of parsing polish that costs ten lines of Ruby and no JavaScript.

**Inline edit** — each item row is a frame; clicking swaps in an edit form, saving swaps back. The classic frame demo, but genuinely the right tool here.

**Quantity stepper** — a small Stimulus controller on each row with +/− buttons that debounce and PATCH the quantity. Demonstrates Stimulus doing what it's for: sprinkles, not architecture.

**Expiry highlighting** — items expiring within 3 days get a badge; a "use soon" section at the top is computed server-side. No JS at all; a reminder that most UI is still just server-rendered HTML.

**Turbo 8 morphing** — enable page refreshes with morphing so that broadcast updates (e.g., a second tab, or the suggestion job completing) smoothly patch the DOM. Scroll and form state preservation across refreshes is a headline Hotwire feature worth showing.

### 4.2 Recipe suggestions

The flow that earns the LLM its place in the architecture:

1. User hits "Suggest recipes", optionally typing a note ("30 minutes max, no dairy"). Controller creates a `SuggestionRun` (status `queued`), enqueues `SuggestRecipesJob`, and responds with a Turbo Stream that renders the run's card in a `pending` state with a spinner.
2. The job snapshots the inventory into the run, flips status to `running` (broadcast via `broadcast_replace_to` → Solid Cable → the card updates live), and calls the LLM.
3. On success, it parses the structured response into `RecipeSuggestion` rows and broadcasts the completed card: 3–5 recipe cards sorted by fewest missing items, each showing title, summary, which of *your* items it uses, what's missing, and a link to the real source recipe.
4. On failure (timeout, malformed response after retries), status goes to `failed` with a human-readable message and a retry button, broadcast the same way.

This one feature exercises the entire Solid stack in a way a CRUD app never would: Solid Queue runs the job, Solid Cable pushes the updates, Solid Cache stores a fingerprint of the inventory so an identical re-request within an hour returns cached results instantly.

### 4.3 Cooking a recipe (closing the loop)

Each suggestion card has an "I made this" button — the event that ties the whole system together. Clicking it opens a modal (a Turbo Frame rendering into a dialog) that lists the recipe's `uses_items` with the quantities currently on hand, pre-filled with a proposed deduction for each; the user adjusts the amounts (the recipe may not have used all 3 stalks) or unchecks items entirely, then confirms. Confirmation applies the deductions in one transaction, which cascades naturally through mechanisms already designed: quantities update across the inventory frames via broadcast, zeroed items trip the coverage check, and stale runs archive themselves — one click, three coordinated morphing updates, no bespoke code paths. This is the single best Hotwire demonstration in the app and the reason the confirmation is a modal rather than an optimistic one-click: the user stays in control of the quantity math, and the app never guesses.

The modal also carries an optional, skippable thumbs prompt — "would you make this again?" — answered with a single tap and written to `recipe.make_again`, the single canonical verdict for that recipe (§3). Thumbs up marks the recipe a favorite: it should be resurfaced in future suggestions whenever the inventory fits, and any run containing one gets a "includes one of your favorites ★" badge — a cheap join now that identity is normalized. Thumbs down suppresses it: the card is archived out of the active view (its siblings in the run stay live; the run itself still archives via coverage as usual) and the recipe joins the do-not-suggest list — it remains browsable in history for the user to revisit on their own terms. Skipping leaves the verdict untouched. Because the verdict lives on the recipe rather than the suggestion row, re-asking on a resurfaced favorite is safe by construction: there's no duplicate opinion to create, the tap simply updates the one verdict in place, and latest wins — demoting a favorite that's gotten old is one tap. The distinction from `cooked_at` still holds: the timestamp on the suggestion records the *fact* of cooking in that run (and drives the deductions); the thumb records the recipe-level *verdict*, and the two are independent.

*Deferred idea, revisit later:* anything richer than the thumbs — learned taste profiles, cuisine preferences inferred over time, weighting beyond the two explicit lists. The thumbs data is the seed for all of it, but v1 keeps the mechanism to exactly two lists fed into the prompt (§5).

## 5. LLM Integration Design

### The prompt

System prompt establishes the task as *retrieval, not invention*: given a pantry inventory (name, quantity, unit, expiry) and optional user notes, find 3–5 existing, published recipes on the web that substantially overlap the on-hand items, preferring items nearing expiry. Exact pantry coverage is explicitly not required — a good real recipe that needs one or two purchasable extras beats a contrived perfect match, and relaxing the matching problem this way makes retrieval far less brittle. For each recipe, report the overlap honestly: which inventory items it uses, and which ingredients are missing. Additionally, for missing items only, the model may propose substitutions drawn strictly from the current inventory (see below). Respond as JSON matching a fixed schema (title, summary, uses_items, missing_items, substitutions, source_url, source_name). Temperature low. The inventory snapshot is serialized compactly into the user message.

**Exact-name echo rule.** Coverage scoring, substitution verification, and the cooking-confirmation deductions all match strings against the snapshot, and "bok choi" vs "bok choy" vs "pak choi" would quietly break all three. So the prompt requires the model to echo `uses_items` and `substitutions.use_instead` values *verbatim from the snapshot's item names*, and parsing validates it: any value that isn't an exact match to a snapshot name is dropped (for subs) or flagged (for uses). This converts a fuzzy-matching problem into an exact-match one at the cost of one prompt sentence — the model does the normalization, since it can see both the recipe's ingredient list and our names for things.

**Content boundaries.** The card shows our own short summary, the overlap data, and the link — never the source recipe's instructions or ingredient list reproduced from the page. The prompt instructs the model to write a one-to-two-sentence original summary and nothing more. This is the right call on respecting the source sites' content, and it's better product design anyway: the source is the recipe; this app is the matchmaking.

**Preference lists.** Thumbs feedback from the cooking modal (§4.3) feeds two compact lists into every call, each a one-line query on the `recipes` table: favorites (`make_again: true` — "the user loved these; resurface one when the inventory fits well") and the do-not-suggest list (`make_again: false`), sent as title + source URL. Enforcement is belt-and-suspenders in the established pattern: the blocklist is a prompt instruction *and* a parse-time filter — any returned result whose normalized `source_url` upserts onto a thumbs-downed recipe is dropped, so a blocked recipe cannot resurface even if the model ignores the instruction. Both lists grow only by explicit user taps, so prompt size stays bounded in practice; if it ever becomes a problem, truncating to the most recent N entries is the escape hatch.

Parsing is defensive: strip code fences, `JSON.parse` inside a rescue, validate against the expected shape, retry once with an error-corrective message if malformed, then fail the run cleanly. This is the kind of unglamorous edge-handling worth showing in a portfolio.

### The link problem (the interesting design decision)

The product constraint from §1 — only existing, published recipes, every suggestion traceable to a real source — drives this decision. The naive approach, asking the model for URLs from memory, produces plausible, frequently dead links; that's a known failure mode and shipping it would undermine the whole feature. Three options considered:

**Option A — model invents the recipe idea and emits a search query; app links to a results page.** Zero dead-link risk, but it violates the constraint outright: the model is generating recipes, and nothing guarantees a published recipe matching the suggestion exists. Ruled out.

**Option B — use the Anthropic web search tool in the API call.** The model searches the live web during the call and returns real recipe pages it actually visited, with citations. This is the only approach that satisfies the constraint with a single vendor. Costs: the call is slower and more expensive, and responses need citation-aware parsing plus a lightweight URL sanity check (scheme, domain not obviously junk) before persisting.

**Option C — recipe API (Spoonacular/Edamam) for retrieval, LLM for matching/ranking.** Also satisfies the constraint, and more deterministically — but adds a second vendor, API keys, and rate limits to a portfolio app. Held as fallback if the web-search path proves too slow or noisy in practice.

**Recommendation: B as the baseline, C as the documented fallback.** The constraint leaves no room for A, and B doubles as the stronger portfolio demo: real tool-use integration with cited sources.

### Ranking and the missing-items UX

Suggestions will rarely use the pantry perfectly, and that's by design — the interesting user decision is often between recipes with *different* gaps (a gyudon that needs dashi powder versus a hotpot that only needs bok choi). Which gap is easier to fill depends on the user's neighborhood, shopping habits, and appetite — context the app cannot have — so the app deliberately does not score "ease of acquisition." Instead it makes the comparison effortless and leaves the judgment to the user: suggestions sort by fewest missing items by default (a defensible heuristic, not a difficulty claim), and each card displays its missing list prominently ("you'd need: bok choi") alongside the on-hand items it uses. The user compares gaps at a glance and decides.

*Deferred idea, revisit later:* having the LLM soft-tag missing items (staple / common / specialty) as muted metadata. Potentially helpful context, but it's a guess from a model with no knowledge of the user's local stores, so it stays out of scope for now and would never become a ranking factor.

### Substitutions

The model may suggest substitutions for a recipe's missing items — but only from items currently in the inventory (the motivating example: gyudon missing dashi powder, but a beef bouillon cube is on hand). This constraint is what makes the feature sound. It directly serves cost minimization, since a workable sub can eliminate a shopping need entirely; it keeps the model from freelancing into open-ended recipe rewriting, which would erode the existing-recipes-only constraint; and it makes every suggestion mechanically verifiable — during parsing, any proposed `use_instead` that doesn't match an in-stock item name in the snapshot is silently dropped. Substitutions happen in the same API call (one JSON field, zero added cost) and render as a muted hint attached to the missing item — "no dashi powder · you could try: beef bouillon cube" — with the user judging whether the swap actually works, consistent with the division of labor above.

### Suggestion lifecycle: archiving instead of regeneration

Suggestion runs are never deleted and never auto-refreshed; they are *archived* when the pantry drifts too far from the snapshot they were generated against. Whenever inventory changes (item deleted or quantity hits zero), a lightweight check recomputes a coverage score for each active run — the fraction of each suggestion's `uses_items` still in stock — and sets `archived_at` when coverage falls below a threshold (initially: more than a third of used items out of stock; tune from real use). Archived runs disappear from the main view into a browsable history.

The cost properties are the point. New LLM calls happen only on explicit user action, never as a side effect of archiving. The inventory-fingerprint cache (Solid Cache, 1-hour TTL) already dedupes repeat requests against an unchanged pantry. And archived runs are free to keep forever — which also makes them nice demo data for the portfolio. Net effect: API spend scales with deliberate use, not with pantry churn.

One consequence of keeping runs forever: source URLs will rot. The deliberate answer is graceful degradation, not link health checks — each card stores `source_name` and our own summary, so an archived card remains meaningful ("Gyudon — Just One Cookbook") even if its link eventually dies. No crawler, no maintenance burden.

### Cost & abuse control

Single-user mitigates most of it, but still: cache by inventory fingerprint (Solid Cache, 1-hour TTL), a per-day run limit enforced in the controller, `max_tokens` capped, and the job wrapped in a timeout. API key via Rails credentials, never env-committed.

## 6. Demo Mode

The deployed app's real audience is a reviewer who will spend ninety seconds and will not create an account or type in a pantry — so the demo path is a feature, not an afterthought. A "try the demo" button on the sign-in page logs into a demo account seeded with a plausible, well-stocked pantry (some items conveniently near expiry, so the "use soon" UI shows) and a couple of pre-generated suggestion runs loaded from fixtures — real captured API responses, not live calls — including one archived run so the history view has content. Live LLM calls for the demo account are either disabled (the "Suggest recipes" button replays a fixture with realistic job latency, exercising the full broadcast pipeline) or capped hard per day; disabled-with-replay is the default recommendation since it demos identically and costs zero. Demo data resets on a schedule (a recurring Solid Queue job — one more honest use of the stack) so one visitor's edits don't confuse the next. The observability columns below make a nice footer here too: the demo can show "this run used N tokens" as a small credibility detail.

As a low-priority addition, `suggestion_runs` gains `input_tokens`, `output_tokens`, and `duration_ms` columns populated from the API response — near-zero effort, and it turns the README's cost story into real numbers ("average run: ~X tokens, ~$0.0Y") instead of hand-waving.

## 7. SQLite in Production — What We're Validating

Part of the project's thesis, so worth being explicit about what "taking SQLite seriously" means here. WAL mode and `IMMEDIATE` transactions via Rails 8 defaults; confirm `busy_timeout` behavior under concurrent writes from Puma + Solid Queue workers (separate database files should make this a non-issue, but we'll load-test lightly and write up findings). Litestream sidecar in the Kamal deploy replicating all four databases continuously; document a restore drill in the README, because backup claims without a tested restore are fiction. Known limitation to note honestly: this architecture is single-node by design; the README should say what would have to change (move to Postgres, or SQLite-with-LiteFS) if horizontal scaling were ever needed.

## 8. Testing

Standard Minitest. Model tests for normalization and expiry scopes. System tests with Capybara covering the Hotwire flows — inline edit, quick add, and crucially the suggestion flow with the LLM call stubbed (WebMock fixture responses for success, malformed-JSON, and timeout cases). A small VCR-style fixture set of real API responses kept in the repo makes the parsing tests honest. The job's parsing/retry logic gets direct unit tests since that's where the fiddly failure handling lives.

## 9. Milestones

**M1 — Inventory CRUD + auth** with the Rails 8 auth generator, Turbo frames/streams, quick-add parsing, styling, expiry logic, CI (GitHub Actions: tests, Rubocop, Brakeman). The app is already useful here.
**M2 — Suggestions via web search (Option B)**: job, broadcasting, citation-aware parsing with exact-name validation, URL sanity checks, missing-items ranking, substitutions, the "I made this" confirmation flow with optional thumbs feedback (favorites + blocklist), coverage-based archiving, caching, failure states.
**M3 — Deploy + demo mode**: Kamal to a VPS, Litestream, restore drill, seeded demo account with fixture-replay suggestions, README write-up of the SQLite findings.
**M4 (stretch)** — token/latency observability columns; staged progress messages during the web-search call ("searching… found 4 candidates… checking links…"); richer taste profiling beyond the thumbs lists; Option C fallback if web-search retrieval proves unreliable; Turbo 8 morphing polish; dark mode because portfolio.

## 10. Resolved Decisions & Open Questions

Resolved in review: authentication uses the Rails 8 built-in auth generator (§2) — on-theme for the showcase and future-proofs for household members. Unit handling stays free-text with the `name x quantity unit` quick-add notation and a datalist of prior units (§4.1); no canonical unit table. Suggestion retention is coverage-based archiving rather than time-based pruning (§5) — runs are kept forever, archived when the pantry drifts, and regeneration is always explicit to control API cost. Substitutions are in scope, constrained to on-hand items and generated within the same call (§5). Cooking a recipe goes through a modal confirmation where the user adjusts deductions before they apply, with an optional skippable thumbs verdict feeding the favorites and do-not-suggest lists (§4.3, §5). Recipes are normalized into their own table keyed by source URL so a recipe recurring across runs has one identity and one verdict — the asymmetry with unnormalized ingredients is deliberate (§3). Ingredient matching uses the exact-name echo rule (§5). Demo mode ships with fixture-replay suggestions and no live LLM calls (§6). Recipe cards never reproduce source content (§5); dead links in archived runs degrade gracefully rather than being health-checked (§5).

Deferred, revisit later: staple/common/specialty tagging of missing items (§5); taste profiling richer than the two thumbs-fed lists (§4.3).

Still open: should "use soon" items be weighted explicitly in the prompt, or is including expiry dates in the snapshot enough for the model to figure out? And the exact coverage threshold for archiving (starting at one-third of used items out of stock) needs tuning against real usage.
