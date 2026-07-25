# Pantry — Initial Tasks for Claude Code

Companion to `pantry-app-design-doc.md`. Drop both files in the repo root; the design doc is the source of truth for every decision, and each task below points at the sections that govern it. Tasks are sized to be one Claude Code session each, in dependency order, each ending in a verifiable state (tests green, feature demonstrable). Don't hand over Task N+1 until Task N's acceptance check passes — small verified increments beat one giant prompt.

## Task 0 — Orientation (paste at the start of the first session)

> Read `pantry-app-design-doc.md` in full before writing any code. It contains the tech stack decisions (§2), schema (§3), and feature designs. Two constraints are non-negotiable throughout the project: SQLite is the production database for app, queue, cache, and cable — never introduce Postgres, Redis, or Sidekiq; and the LLM feature only surfaces existing published recipes with real sources — never generated ones. When a task conflicts with the doc, stop and flag it instead of improvising.

Also create a `CLAUDE.md` in the repo root as part of Task 1 (contents specified there) so every future session inherits the constraints without re-reading the whole doc.

## Task 1 — App skeleton and CI

Generate the Rails 8 app per §2: `rails new pantry --database=sqlite3 --css=tailwind` (importmap, Propshaft, Turbo, Stimulus defaults), Ruby 3.4. Confirm Solid Queue, Solid Cache, and Solid Cable are configured against their own SQLite database files as Rails 8 sets up by default — do not consolidate them into one file (§2, §7). Run the auth generator (`bin/rails generate authentication`) and wire a basic authenticated root. Add a `CLAUDE.md` capturing: the SQLite-everywhere rule, the existing-recipes-only rule, Minitest not RSpec, no new gems without justification, and a pointer to the design doc. Add GitHub Actions CI running tests, Rubocop (rails-omakase), and Brakeman (§9 M1).

Acceptance: `bin/rails test` green in CI, sign-in works locally, four `.sqlite3` files appear in `storage/` under production config.

## Task 2 — PantryItem model and inventory schema

Implement `PantryItem` exactly as §3 specifies: name, decimal quantity defaulting to 1, free-text unit, location enum (pantry/fridge/freezer), category enum, `expires_on`, with the two indexes. Add the light normalization on save (downcase, singularize — §3) and scopes: per-location grouping and `expiring_soon` (within 3 days, §4.1). Model tests for normalization and the expiry scope. No UI yet.

Acceptance: model tests green, seeds file creates a plausible ~20-item pantry across all three locations with a few near-expiry items (this seed becomes the demo-mode base later, §6).

## Task 3 — Inventory UI with Hotwire

Build the main inventory screen per §4.1: three location groups, each a Turbo Frame. Implement in this order, testing each before the next: (a) quick add — single text input parsing `name x quantity unit` notation server-side with regex, falling back to whole-string-as-name, plus fallback fields with a unit datalist; Turbo Stream append on create; (b) inline edit — row frame swaps to form and back; (c) quantity stepper — Stimulus controller, debounced PATCH on +/−; (d) expiry badges and the server-rendered "use soon" section; (e) enable Turbo 8 morphing with `broadcasts_refreshes` so a second tab stays in sync. System tests with Capybara for a, b, and c.

Acceptance: full CRUD flow works with JavaScript enabled and the quick-add parser has unit tests covering `Bok Choi x3 stalks`, `milk x2`, and bare `eggs`.

## Task 4 — Suggestion domain models (no LLM yet)

Implement `SuggestionRun`, `Recipe`, and `RecipeSuggestion` per §3, including the URL normalization method on `Recipe` (strip query params and fragments; unique index on the result) and the upsert path (`find_or_create_by` on normalized URL). Port the coverage computation from §5: given a run's suggestions and the live inventory, the fraction of `uses_items` still in stock; archive the run (`archived_at`) when more than a third of used items are out of stock, triggered from inventory changes. Unit-test coverage math and archiving against fixture data — this is all testable with zero API calls, which is why it precedes the LLM task.

Acceptance: model tests green, including URL-variant dedup (same recipe with and without `?utm_source=` resolves to one row) and an archiving test driven by zeroing a pantry item.

## Task 5 — SuggestRecipesJob against the real API

The core LLM integration per §5. Build `SuggestRecipesJob`: snapshot inventory onto the run, call the Anthropic API with the web search tool enabled, parse per the doc's rules — defensive JSON handling with one corrective retry, exact-name validation against the snapshot, URL sanity checks, dropping substitutions not in stock, dropping results matching thumbs-downed recipes, upserting `Recipe` rows. Status transitions broadcast over Solid Cable per §4.2. Store real captured API responses as fixtures (success, malformed JSON, timeout) and test the parser against them with WebMock — the job's parsing/retry logic is where the fiddly failure handling lives (§8). Cache by inventory fingerprint, per-day run limit, `max_tokens` cap, job timeout, API key in credentials (§5 cost control).

Acceptance: with a real API key in credentials, running the job from the console against the seeded pantry produces persisted suggestions with live source URLs; parser tests green against all three fixture types without network access.

## Task 6 — Suggestions UI and the cooking loop

The suggestion flow per §4.2 and §4.3: the run card lifecycle (queued spinner → running → completed cards sorted by fewest missing items → failed with retry), missing-items and substitution display, the favorites ★ badge, and the "I made this" modal — Turbo Frame dialog listing `uses_items` with adjustable pre-filled deductions, applying in one transaction, followed by the optional thumbs writing to `recipe.make_again`. Verify the cascade end-to-end: confirming a cook that zeroes items should visibly update inventory frames and archive newly-stale runs via broadcast. System test with the LLM stubbed.

Acceptance: the full demo path works locally — add items, request suggestions, cook one, watch quantities drop and a stale run archive itself.

## Later (do not start yet)

Demo mode with fixture replay and reset job (§6), Kamal + Litestream deploy with restore drill (§7 / M3), observability columns, staged progress messages, and the M4 stretch list. These get their own task prompts once Tasks 1–6 are verified.
