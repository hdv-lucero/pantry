# Task 6 Recap — Suggestions UI and the cooking loop

**Completed:** 2026-07-27 · **Branch:** `task-5-SuggestRecipesJob-api-calling`, working tree on top of `39b7c0e`
**Governing spec:** `pantry-app-design-doc.md` §4.2 (the whole run-card lifecycle, all four steps), §4.3 (the whole cooking loop — modal, deductions, thumbs, favorites badge, blocklist), §5 (ranking and the missing-items UX, substitutions, the archiving lifecycle, cost & abuse control's per-day limit, the graceful-degradation note about `source_name`), §4.1 (the screen the panel shares and the acting-tab/broadcast split Task 3 established), §3 (`Recipe` identity, `cooked_at` vs `make_again`), §8 (system tests with the LLM stubbed)
**Task text:** `claude-code-initial-tasks.md` → Task 6

> The suggestion flow per §4.2 and §4.3: the run card lifecycle (queued spinner → running →
> completed cards sorted by fewest missing items → failed with retry), missing-items and
> substitution display, the favorites ★ badge, and the "I made this" modal — Turbo Frame
> dialog listing `uses_items` with adjustable pre-filled deductions, applying in one
> transaction, followed by the optional thumbs writing to `recipe.make_again`. Verify the
> cascade end-to-end: confirming a cook that zeroes items should visibly update inventory
> frames and archive newly-stale runs via broadcast. System test with the LLM stubbed.
>
> Acceptance: the full demo path works locally — add items, request suggestions, cook one,
> watch quantities drop and a stale run archive itself.

---

## Files touched

**No gems were added.** No migrations, so `db/schema.rb` is untouched — Task 4's schema
already carried every column this task needed (`cooked_at`, `make_again`, `archived_at`).

### Created

| File | What it holds |
| --- | --- |
| `app/controllers/suggestion_runs_controller.rb` | `#index` (history, every run) and `#create` (§4.2 step 1: queued run + job + streamed card), the per-day limit refusal, and the retry's archive-the-superseded-run step |
| `app/controllers/cooks_controller.rb` | `#new` (the modal) and `#create` (apply deductions, stream the thumbs step); permits the dynamic-key `deductions` hash |
| `app/controllers/verdicts_controller.rb` | `#update` — writes `recipe.make_again`, closes the modal, re-renders the run list |
| `app/models/recipe_suggestion/cook.rb` | The form object: builds the modal's lines from the live pantry, clamps submitted amounts, applies the deductions and `cooked_at` in one transaction |
| `app/helpers/suggestion_runs_helper.rb` | DOM-id helpers (`suggestion_runs_list_id`, `new_suggestion_run_id`, `modal_frame_id`) and `run_timestamp` |
| `app/javascript/controllers/dialog_controller.js` | Opens the `<dialog>` on connect, closes it on Cancel/Skip, empties the frame on the dialog's own `close` event |
| `app/views/suggestion_runs/_suggestions.html.erb` | The panel: `turbo_stream_from`, heading, History link, form, list |
| `app/views/suggestion_runs/_new_run.html.erb` | The "Suggest recipes" form with the optional note; takes `prompt_notes:`/`error:` locals for the refusal path |
| `app/views/suggestion_runs/_runs.html.erb` | The `#suggestion_runs_list` container, with the `hidden only:block` empty state |
| `app/views/suggestion_runs/_recipe_suggestion.html.erb` | One recipe card: title link, source name, summary, uses chips, missing chips with substitution hints, ★, "I made this" / "You made this" |
| `app/views/suggestion_runs/create.turbo_stream.erb` | Prepend the pending card, reset the note form |
| `app/views/suggestion_runs/index.html.erb` | The history page |
| `app/views/cooks/new.html.erb` | The modal frame + dialog + deduction form |
| `app/views/cooks/_verdict.html.erb` | The thumbs step (Skip / 👎 / 👍) |
| `app/views/cooks/create.turbo_stream.erb` | Modal → thumbs, deducted rows replaced, run list replaced |
| `app/views/verdicts/update.turbo_stream.erb` | Empty the modal frame, replace the run list |
| `test/controllers/suggestion_runs_controller_test.rb` | 10 tests |
| `test/controllers/cooks_controller_test.rb` | 7 tests |
| `test/controllers/verdicts_controller_test.rb` | 6 tests |
| `test/models/recipe_suggestion/cook_test.rb` | 10 tests |
| `test/system/suggestions_test.rb` | 5 tests — §8's stubbed-LLM system test |

### Modified

| File | Change |
| --- | --- |
| `config/routes.rb` | `resources :suggestion_runs, only: %i[index create]`; `resource :cook` nested under `recipe_suggestions`; `resource :verdict` nested under `recipes` |
| `app/models/suggestion_run.rb` | `after_update_commit :broadcast_removal, if: :saved_change_to_archived_at?`; `scope :on_screen`; `#visible_suggestions`; private `#broadcast_removal` |
| `app/models/recipe_suggestion.rb` | `#blocked?` (delegates to the recipe's verdict), `#substitution_for(missing_item)` |
| `app/controllers/pantry_items_controller.rb` | `#index` also loads `@suggestion_runs = SuggestionRun.on_screen` |
| `app/views/pantry_items/index.html.erb` | Renders the suggestions panel below the inventory |
| `app/views/layouts/application.html.erb` | The one `turbo_frame_tag modal_frame_id` every "I made this" link targets |
| `app/views/suggestion_runs/_suggestion_run.html.erb` | Rewritten from Task 5's four-state skeleton into the real card (badges, note, spinner, ranked cards, retry) |
| `app/helpers/pantry_items_helper.rb` | `formatted_quantity` now takes a quantity, not a `PantryItem` — the modal formats a proposed deduction that has no row |
| `app/views/pantry_items/_pantry_item.html.erb`, `_form.html.erb` | Call sites updated for that signature change |
| `test/test_helpers/anthropic_test_helper.rb` | `with_anthropic_credentials` added; `without_anthropic_credentials` refactored onto a shared `with_credentials_api_key` |
| `test/jobs/suggest_recipes_job_test.rb` | `#perform` wraps in `with_anthropic_credentials` (see decision 8) — no test added or removed |
| `test/models/suggestion_run_test.rb` | +6 tests, −1 (a Task 4/5 test that asserted archiving is silent had to change); now 36 |
| `test/models/recipe_suggestion_test.rb` | +2 tests; now 11 |
| `test/controllers/pantry_items_controller_test.rb` | +1 test (the panel and modal frame on the index); now 18 |

`.claude/tasks_recap/task-5-suggest-recipes-job.md` also shows as modified in `git status`;
that edit predates this session and is not mine.

## Acceptance

> the full demo path works locally — add items, request suggestions, cook one, watch
> quantities drop and a stale run archive itself.

| Clause | What actually happened |
| --- | --- |
| add items | Task 3's, unchanged and still green — `test/system/inventory_test.rb`, 12 tests, including quick-add, inline edit and the stepper |
| request suggestions | `test/system/suggestions_test.rb` drives a real Chromium: form → queued card → job drained → 5 ranked cards, live in the browser over Solid Cable's test adapter (which subclasses `Async`, so broadcasts really are delivered in-process) |
| cook one | Same test: "I made this" → dialog with three pre-filled lines → confirm |
| watch quantities drop | Same test: ground beef `0`, rice `0`, olive oil `0` asserted **in the inventory frames**, not just in the DB |
| a stale run archives itself | Same test: `assert_predicate run.reload, :archived?` and `assert_no_selector "#suggestion_run_<id>"`; a second test proves the *broadcast* specifically, by removing an item on a page where nothing re-renders the panel |
| **with a live API call** | **Not done this task.** See "Deliberately not done" |

| Command | Result |
| --- | --- |
| `docker compose run --rm app bin/rails test` | **279 runs, 914 assertions, 0 failures, 0 errors, 0 skips** (238/733 at session start, so +41) |
| `docker compose run --rm app bin/rails test test/models/recipe_suggestion/cook_test.rb test/controllers/suggestion_runs_controller_test.rb test/controllers/cooks_controller_test.rb test/controllers/verdicts_controller_test.rb` | **33 runs, 150 assertions, 0 failures, 0 errors** |
| `docker compose run --rm app bin/rails test:system` | **17 runs, 98 assertions, 0 failures, 0 errors** (12 at session start, so +5). Run four times in this session, no flakes |
| `docker compose run --rm app bin/rubocop` | **82 files inspected, no offenses detected** |
| `docker compose run --rm app bin/brakeman --no-pager` | **7 controllers, 14 models, 22 templates, 0 errors, 0 security warnings** |

Note: `bin/rails test:system test/system/suggestions_test.rb` runs all 17 system tests —
the path argument does not filter that task. The 5/12 split is from counting `test "`
declarations per file.

### The manual walk through the running dev app

Reproducible only by repeating the steps, so it is recorded rather than claimed as a
number `/review-task` can re-run. Against `docker compose up` with the full dev Solid
stack and the two completed runs Task 5's live call left in `storage/`:

- Signed in over HTTP and fetched `/`: the panel rendered 4 run cards (2 completed × 5
  recipes, 2 failed), 10 `data-turbo-frame="modal"` links, 2 `<button>Try again</button>`.
- `/suggestion_runs`: same 4 cards, **0** "I made this" links and **0** retry buttons.
- `GET /recipe_suggestions/8/cook/new` with `Turbo-Frame: modal`: **exactly one**
  `<turbo-frame>` in the response (turbo-rails substitutes its minimal layout for a frame
  request, so the layout's placeholder frame is not there to collide), four checked lines
  pre-filled `200 / 1 / 1 / 4` with matching `max` attributes.
- `POST /recipe_suggestions/8/cook`: 200, six stream actions — `update modal`, four
  `replace pantry_item_*`, `replace suggestion_runs_list`. Quantities went
  `200/1/1/4 → 0/0/0/2`, `cooked_at` stamped `2026-07-27 06:14:30 UTC`.
- The run did **not** archive: coverage fell to 11/14 ≈ 0.786, above the 2/3 threshold.
  The seeded 22-item pantry is large enough that one recipe does not strand a run. The
  archive half of the cascade is covered by the system test instead, where it does.
- Exactly one cable message came out of those four pantry writes —
  `SolidCable::Message` id 9, channel `pantry_items`, `2026-07-27 06:14:31 UTC`, with the
  next-newest message dated 2026-07-26. That is Turbo's refresh debouncing doing its job,
  and it is still inspectable in the dev cable database.
- `bin/rails db:seed` restored the four quantities. **`cooked_at` on `recipe_suggestions`
  id 8 in the dev database is mine and was not undone.**

## Fidelity to the doc

### §4.2, step by step

| Doc | Implementation |
| --- | --- |
| 1. "Controller creates a `SuggestionRun` (status `queued`), enqueues `SuggestRecipesJob`, and responds with a Turbo Stream that renders the run's card in a `pending` state with a spinner" | `SuggestionRunsController#create` + `create.turbo_stream.erb` (prepend + form reset). The spinner is a `animate-spin` ring with `role="status"` |
| 1. "optionally typing a note" | `suggestion_run[prompt_notes]`, stored, echoed on the card, and carried through a retry |
| 2–4. status transitions broadcast | Task 5's `broadcast_card`; this task only supplied the real partial it renders |
| 3. "3–5 recipe cards sorted by fewest missing items, each showing title, summary, which of *your* items it uses, what's missing, and a link to the real source recipe" | `_recipe_suggestion.html.erb`, in `position` order (the job ranked them; the view does not re-sort) |
| 4. "status goes to `failed` with a human-readable message and a retry button" | The `:failed` branch renders `error_message` with `role="alert"` and a `button_to "Try again"` |

### §4.3, clause by clause

| Doc | Implementation |
| --- | --- |
| "a modal (a Turbo Frame rendering into a dialog)" | `turbo_frame_tag "modal"` in the layout; `cooks/new` renders a `<dialog>` into it |
| "lists the recipe's `uses_items` with the quantities currently on hand" | One line per **in-stock** row whose name is in `uses_items`; names with no in-stock row are named separately rather than dropped |
| "pre-filled with a proposed deduction for each" | The whole quantity on hand — decision 1 |
| "the user adjusts the amounts … or unchecks items entirely" | Per-line `amount` number field and `apply` checkbox; both covered by system and model tests |
| "applies the deductions in one transaction" | `RecipeSuggestion::Cook#apply!` — `RecipeSuggestion.transaction` around every pantry write *and* the `cooked_at` stamp |
| "quantities update across the inventory frames via broadcast" | Broadcast for other tabs (Task 3's `broadcasts_refreshes_to`); the acting tab is filtered out by request id, so `cooks/create.turbo_stream.erb` replaces exactly the deducted rows — the same split Task 3 made for quick add |
| "zeroed items trip the coverage check, and stale runs archive themselves" | Unchanged from Task 4; this task added the `remove` broadcast that takes the card off the screen |
| "an optional, skippable thumbs prompt … written to `recipe.make_again`" | `cooks/_verdict.html.erb` → `VerdictsController#update` |
| "Skipping leaves the verdict untouched" | Skip is a plain button that closes the dialog. There is no request and no route — decision 5 |
| "Thumbs up marks the recipe a favorite … any run containing one gets a 'includes one of your favorites ★' badge" | `SuggestionRun#includes_favorite?` (Task 4's, now rendered) plus a ★ on the favorite's own card |
| "Thumbs down … the card is archived out of the active view (its siblings in the run stay live; the run itself still archives via coverage as usual)" | `SuggestionRun#visible_suggestions` — decision 4 |
| "it remains browsable in history" | `/suggestion_runs` renders every run and every card, blocked ones marked "Not for you" |
| "the timestamp on the suggestion records the *fact* of cooking … the thumb records the recipe-level *verdict*, and the two are independent" | Two routes, two writes; cooking never touches `make_again`, the verdict never touches `cooked_at` |

### §5 rules this task implements

- **"suggestions sort by fewest missing items by default"** — rendered in `position` order,
  which the parser assigned. The view adds no sorting of its own.
- **"each card displays its missing list prominently ('you'd need: bok choi')"** — a
  labelled chip row.
- **"renders as a muted hint attached to the missing item — 'no dashi powder · you could
  try: beef bouillon cube'"** — `RecipeSuggestion#substitution_for` pairs them; the hint is
  inside the missing item's own chip, in `text-gray-400`.
- **"a per-day run limit enforced in the controller"** — now actually in the controller,
  where Task 5 promised to put it.
- **"each card stores `source_name` and our own summary, so an archived card remains
  meaningful … even if its link eventually dies"** — `source_name` is rendered as text, not
  only as the link target.
- **"Archived runs disappear from the main view into a browsable history"** — `on_screen`
  is `active`; `/suggestion_runs` is the history.
- **§1/§5 content boundary** — the card renders `summary`, `uses_items`, `missing_items`,
  `substitutions` and a link. Nothing else exists to render; the client already dropped the
  search-result blocks.

### What was not added beyond the doc

No new columns, no migrations, no indexes. No `archived_at` on `recipe_suggestions` (the
blocked-card filter is a join on the verdict that already exists). No `Recipe` verdict
side-table. No new gems. No JSON API. One new Stimulus controller, 15 lines.

## Surface

**Routes** (6 lines, verified with `bin/rails routes`)

| Helper | Verb / path | Action |
| --- | --- | --- |
| `suggestion_runs_path` | `GET /suggestion_runs` | `suggestion_runs#index` — history |
| `suggestion_runs_path` | `POST /suggestion_runs` | `suggestion_runs#create` |
| `new_recipe_suggestion_cook_path` | `GET /recipe_suggestions/:recipe_suggestion_id/cook/new` | `cooks#new` |
| `recipe_suggestion_cook_path` | `POST /recipe_suggestions/:recipe_suggestion_id/cook` | `cooks#create` |
| `recipe_verdict_path` | `PATCH|PUT /recipes/:recipe_id/verdict` | `verdicts#update` |

**`SuggestionRun`**

- `scope :on_screen` — `active.recent.preload(recipe_suggestions: :recipe)`. Newest first.
  `preload`, not `includes`, deliberately (decision 9). Tested.
- `#visible_suggestions` — `recipe_suggestions` minus those whose recipe is thumbs-downed.
  Filters in Ruby, so a preloaded relation is used as loaded. Does **not** affect
  `used_item_names`/`coverage` — a hidden card still counts toward archiving. Both halves
  tested.
- `after_update_commit :broadcast_removal, if: :saved_change_to_archived_at?` — a
  `broadcast_remove_to` on `BROADCAST_STREAM` targeting `dom_id(run)`. Fires once, because
  `archive!` is already guarded by `unless archived?`. Tested, including the payload's
  `action="remove"` and target.

**`RecipeSuggestion`**

- `#blocked?` — `recipe.blocked?`. A recipe with **no** verdict is not blocked. Tested.
- `#substitution_for(missing_item)` — exact-string lookup in `substitutions`, returns the
  `use_instead` or `nil`. Tested.

**`RecipeSuggestion::Cook`** — `new(suggestion, deductions = {})`

- `Line = Struct.new(:pantry_item, :amount, :apply)` with `#apply?` and `#remaining`
  (`[quantity - amount, 0].max`).
- `#lines` — one per in-stock `PantryItem` whose name is in `uses_items`, ordered by name.
  Built from the pantry, never from the parameters, so an unknown id has nothing to attach
  to. Tested.
- `#unavailable_names` — `uses_items` with no in-stock row. Tested.
- `#applied` / `#deducted_items` — the checked lines and their items.
- `#apply!` — one transaction: each applied line's new quantity, then `cooked_at`. Returns
  `self`. Tested, including the archiving cascade it sets off.
- Amounts are **clamped, never rejected**: `amount.to_s.to_d.clamp(0, quantity)`. Junk
  deducts nothing, negative deducts nothing, more than you own empties the row. There is no
  invalid state and therefore no error rendering path. Tested (three cases).

**`SuggestionRunsHelper`** — `suggestion_runs_list_id` (`"suggestion_runs_list"`, chosen
*not* to collide with the `"suggestion_runs"` cable stream), `new_suggestion_run_id`,
`modal_frame_id`, `run_timestamp`.

**`PantryItemsHelper#formatted_quantity`** — signature changed from `(pantry_item)` to
`(quantity)`. Two Task 3 call sites updated.

**`AnthropicTestHelper`** — `with_anthropic_credentials(&block)` added, and
`without_anthropic_credentials` re-expressed on the shared `with_credentials_api_key`.

**Stimulus `dialog`** — `connect` (`showModal` if not already open), `close`, `clear`
(empties the enclosing `turbo-frame`, null-safe).

## Decisions a reviewer should weigh

### 1. The pre-filled deduction is the whole quantity on hand

**Beyond the task text**, which says only "adjustable pre-filled deductions" and leaves the
proposal open. The doc's own example cuts the other way — "the recipe may not have used all
3 stalks" — which reads as *starting at 3 and dialling back*, and that is what this does.

`uses_items` carries names only: §5's exact-name echo rule is about identity, not amounts,
and nothing in the response says how much of anything a recipe wants. So there is no
quantity data to be faithful to, and the choice is between an honest maximum and an invented
fraction. Proposing "you used it up" invents nothing and gives the checkbox a meaning
("that one was a pinch, leave it alone"). Defaulting to 1 would be a guess dressed as
modesty, and wrong for everything sold by weight. A category-based heuristic (staples get a
fraction, produce gets all of it) is exactly the guessing §5 refuses elsewhere.

The consequence worth naming: accepting the proposal on a 3-ingredient recipe zeroes all
three, which usually pushes that run under the coverage threshold and archives it. That is
the doc's designed cascade, not a side effect — but it means **cooking a suggestion normally
retires the run it came from**.

*Covered by* `cook_test.rb` "a line per in-stock row the suggestion names, proposing the
whole quantity", and the system test's `assert_field … with: "1" / "750" / "2"`.
*To disagree:* change `Line.new(item, item.quantity, true)` in `Cook#line_for`. Nothing else
depends on the value; the clamp already tolerates anything.

### 2. Retry creates a new run and archives the failed one

**Beyond the task text**, which says "failed with retry" and nothing about mechanics.

Re-queueing the failed run in place would have been less code, but `daily_limit_reached?`
counts runs *created today* — so a rewind spends nothing from the allowance, and §5's cap
becomes free to walk around with one button. A new run spends normally. The failed run is
then archived rather than deleted, honouring §5's "runs are never deleted": it stays in
history as the record of what went wrong, and stops occupying the screen it can no longer
answer.

That is a **new archiving trigger** the doc does not name — §5 archives on coverage drift.
The justification is that the user's explicit "try again" is the same statement ("this run
is no longer the live answer") in a different voice, and the alternative is a pile of dead
cards that coverage can never archive, since a failed run has no `uses_items` and its
coverage is `Rational(1)` forever.

*Covered by* `suggestion_runs_controller_test.rb` "a retry starts a new run carrying the
note and archives the one it replaces" (which also asserts the failed run is still
`failed?`, i.e. archived and not rewound), and the system test's retry.
*To disagree:* delete `superseded_run&.archive!` and the `retry_of` param from
`SuggestionRunsController#create` and from the card's `button_to`. Failed cards then
accumulate on the active view.

### 3. The suggestions panel lives on the inventory screen

**Beyond the task text.** §4.2 never says where cards render. The reason is §4.3: "one
click, three coordinated morphing updates" is only observable if the quantities and the run
list are on the same screen, and the acceptance clause ("watch quantities drop and a stale
run archive itself") reads as one screen. `PantryItemsController#index` therefore loads
`@suggestion_runs` as well as the inventory, which is a mixed-responsibility index action —
defensible for a home screen, but it is a real cost of the choice.

*Covered by* `pantry_items_controller_test.rb` "index carries the suggestions panel …".
*To disagree:* move `render "suggestion_runs/suggestions"` to its own page and drop the
`@suggestion_runs` line; everything else is already routed through partials that take the
collection as a local.

### 4. A blocked card is hidden by a Ruby filter, not a column or a scope

§4.3 says a thumbs-down card "is archived out of the active view". The obvious reading is an
`archived_at` on `recipe_suggestions`, but the verdict already lives on the recipe (§3), so
the card's absence is derivable and a column would be a second place for the same fact to
be wrong.

Filtered in Ruby (`recipe_suggestions.reject(&:blocked?)`) rather than with a SQL scope,
because `on_screen` preloads those associations and a `joins` would throw the preload away.
The load-bearing consequence: `used_item_names` and therefore `coverage` still see the
hidden card, so hiding one cannot quietly change when the run archives. There is a test for
exactly that.

*Covered by* `suggestion_run_test.rb` "visible_suggestions drops the blocked cards and keeps
the rest" and "a blocked card still counts toward coverage"; `verdicts_controller_test.rb`
"a thumbs down takes the card out of the active view and leaves its siblings".

### 5. Skip sends no request

§4.3: "Skipping leaves the verdict untouched." The honest way to leave something untouched
is to send nothing, so Skip is a `<button type="button">` that closes the dialog — no route,
no action, no `null` write. Worth flagging because a reviewer looking for a third verdict
endpoint will not find one, and because it means a skipped prompt leaves no trace anywhere.

### 6. History is *every* run, not just the archived ones

§5 says archived runs go "into a browsable history", which reads as archived-only. But §4.3
promises a thumbs-downed card "remains browsable in history", and such a card usually sits
on a run that is still **active** — an archived-only history would lose it entirely. So
`#index` lists every run, marks the archived ones, and renders every card including blocked
ones. It is read-only: no retry button, no "I made this".

*Covered by* three `suggestion_runs_controller_test.rb` tests, one of which asserts the same
buttons **do** appear on the inventory screen, so the absence assertions are about the
`history` flag rather than about markup that never renders anywhere.
*To disagree:* `SuggestionRun.archived.recent` in `#index`, and drop the `history` local.

### 7. Archiving now broadcasts, which changed a Task 4/5 test

Task 5's `suggestion_run_test.rb` asserted "a write that does not change status does not
broadcast" and used `run.archive!` as its example of such a write. The task text requires
newly stale runs to "archive themselves via broadcast", so that assertion had to go. It was
narrowed to "a write that changes neither status nor archived_at does not broadcast" and two
tests were added for the removal. Calling this out because it is the one place this task
**weakened an existing assertion**, and a reviewer should confirm the replacement is not
weaker than it looks.

The callback is registered separately rather than as a branch inside `broadcast_card`,
because Rails deduplicates commit callbacks by method name — the same trap `PantryItem`
documents.

### 8. `SuggestRecipesJobTest` depended on the runner's `config/master.key` — fixed here

**Outside this task's scope**, found while writing the system test. `SuggestRecipesJob`
builds its own `RecipeSearch::Client`, which raises `MissingCredentials` *before* WebMock
sees anything if `Rails.application.credentials.dig(:anthropic, :api_key)` is nil. It is
non-nil on this machine and nil in CI, where `RAILS_MASTER_KEY` is still commented out — so
those tests pass here and would fail there. This contradicts the Task 5 recap's line "The
test suite does not need credentials — no test reads the key."

Fixed by adding `with_anthropic_credentials` (the mirror of the existing
`without_anthropic_credentials`, on a shared swap) and wrapping the job test's `perform`
helper and the system test's `perform_enqueued_jobs`. **This is not verified against a
CI-like environment** — I did not run the suite with the key removed, because that means
moving the user's key file. The reasoning is from reading `EncryptedConfiguration`, not from
an observed failure.

*To disagree:* revert `test/jobs/suggest_recipes_job_test.rb` and delete
`with_anthropic_credentials`; the system test would then need its own way in.

### 9. `on_screen` uses `preload`, and the test that guards it does not

Written first as `includes(recipe_suggestions: :recipe)`. In the dev console
`SuggestionRun.on_screen.pluck(:id)` returned 12 rows for 4 runs, because Rails' `pluck`
applies a join whenever `includes_values` are present. Rendering deduplicates, so no page
was wrong, but the scope would have answered a `pluck` dishonestly. Switched to `preload`.

**The committed test is not a regression guard, and I should say so plainly.** I probed both
versions in the test environment this session: with `includes`, `pluck` returns 5 rows for 4
active runs and `count`/`to_a` return 4; with `preload`, all three return 4. The test asserts
`count` and `to_a`, so it passes either way. Catching a revert would need a `pluck`
assertion. I did not add one, because the recap step is not the place to extend code — it is
listed under open questions instead.

### 10. The failed-run system test reloads instead of watching

`running` and `failed` are broadcast microseconds apart on the misconfigured-credentials
path, and Action Cable's in-process async adapter hands each broadcast to a thread pool —
two that close together can be delivered out of order, leaving the card showing the spinner.
Observed once in a full-file run before the test was changed. Production's `solid_cable`
poller replays rows in insert order and cannot reorder them, so this is a test-environment
artifact, but it is a real one and the test says so in a comment. The completed-path test
still watches the transitions live, so broadcast delivery is not going untested.

### 11. The cascade is not batched

Task 5 handed this over explicitly ("Whether that wants batching is Task 6's call"). It is
not batched: N zeroed items means N `SuggestionRun.archive_stale!` passes. Each is
idempotent (`archive!` no-ops on an already-archived run), the run set is tiny, and Turbo
debounces the refresh broadcasts — the dev walkthrough produced **one** cable message from
four pantry writes. Suppressing the per-item callback would mean a mechanism to turn a model
callback off, which costs more than the scans do.

## Deliberately not done

- **No live API call in this task.** Task 5 verified that path end to end and recorded the
  actual recipes and URLs; everything Task 6 adds sits above the parser and is exercised by
  the fixture. A fresh live run costs ~$0.44 and 2–4 minutes and would prove nothing this
  task changed. The acceptance clause's "request suggestions" is therefore verified against
  the stubbed API in a real browser, plus the two real runs already in the dev database.
- **No demo mode, no fixture replay, no seeded suggestion runs** (§6, and on the "Later"
  list). `db/seeds.rb` is unchanged.
- **No observability columns** (`input_tokens`, `output_tokens`, `duration_ms`) — §6, and on
  the "Later" list.
- **No staged progress messages** during the search — §M4. The card shows one running state,
  not "searching… found 4 candidates…".
- **No dark mode, no Turbo morphing polish** beyond what Task 3 enabled — §M4.
- **No pagination on history.** Runs are never deleted, so this page grows forever. Fine at
  single-user scale, and the doc treats archived runs as an asset ("nice demo data").
- **No "cook from history".** An archived run's ingredients are mostly gone by definition;
  the page is read-only rather than partly-live, which is simpler to explain than a card
  whose buttons work in one view and not another.
- **No link-health checking** — §5 is explicit that graceful degradation, not a crawler, is
  the answer to URL rot.
- **`SuggestionRun.archive_stale!` is still not called after a run completes** — inherited
  from Task 5's open list, unchanged.

## What the next task inherits

- **`SuggestionRun.on_screen` is the panel's query**, and three controllers answer with the
  same `suggestion_runs/_runs` partial. Anything that changes what is on screen should
  re-render that partial rather than invent a stream target.
- **`suggestion_runs/_suggestion_run` is still the broadcast target** and can only be passed
  `suggestion_run:`. Its `history` local is fetched with a default for exactly that reason —
  any new local needs the same treatment.
- **The modal frame is in the layout, one per page**, id from `modal_frame_id`. A frame
  request gets turbo-rails' minimal layout, so a modal view may render its own
  `turbo_frame_tag` with the same id without colliding.
- **`RecipeSuggestion::Cook` is where deduction semantics live.** Demo mode (§6) resetting
  the pantry should go through `PantryItem` writes, not around them, or the coverage
  cascade and the refresh broadcasts will not fire.
- **Cooking normally archives the run it came from** (decision 1). Demo fixtures that want a
  cooked card *and* a live run need a partial deduction.
- **`with_anthropic_credentials` is the seam** for any future test that drives the job.
- **The dev database now has `cooked_at` set on `recipe_suggestions` id 8** from the manual
  walkthrough. Anything that treats dev data as pristine should know that.

## Open questions

1. **The `on_screen` guard test does not guard** (decision 9). A `pluck` assertion would
   catch a revert to `includes`; `count`/`to_a` do not. Due whenever the model tests are
   next touched — it is one line, and I left it out only because the recap step is not the
   place to write code.
2. **Nothing verifies the CI-without-master-key claim** (decision 8). The real fix is
   uncommenting `RAILS_MASTER_KEY` in `.github/workflows/ci.yml` and adding the repo
   secret, which also settles whether the credential swap was necessary or merely tidy. Due
   before CI is trusted, and it is Task 5's open item too.
3. **Every cook archives its run, on a small pantry.** With the seeded 22-item pantry it
   does not (coverage 11/14); with a 6-item test pantry it does. Whether the 2/3 threshold
   is right is a question only real use answers — §5 says "tune from real use" — and demo
   mode (§6) is the first place it will look wrong, since a reviewer who cooks the first
   suggestion may watch the whole panel empty itself.
4. **Failed runs are only archivable by retrying them.** Coverage can never archive a run
   with no suggestions, so a failed run the user ignores sits on the active view forever.
   Decision 2 handles the retry path; nothing handles the ignore path. Due if failed runs
   turn out to be common in practice.
