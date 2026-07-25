# Task 3 Recap — Inventory UI with Hotwire

**Completed:** 2026-07-25 · **Branch:** `main` (repo still has no commits; all files untracked)
**Governing spec:** `pantry-app-design-doc.md` §4.1 (inventory management), §8 (testing), §9 M1
**Task text:** `claude-code-initial-tasks.md` → Task 3

> Build the main inventory screen per §4.1: three location groups, each a Turbo Frame.
> Implement in this order, testing each before the next: (a) quick add — single text input
> parsing `name x quantity unit` notation server-side with regex, falling back to
> whole-string-as-name, plus fallback fields with a unit datalist; Turbo Stream append on
> create; (b) inline edit — row frame swaps to form and back; (c) quantity stepper —
> Stimulus controller, debounced PATCH on +/−; (d) expiry badges and the server-rendered
> "use soon" section; (e) enable Turbo 8 morphing with `broadcasts_refreshes` so a second
> tab stays in sync. System tests with Capybara for a, b, and c.
>
> Acceptance: full CRUD flow works with JavaScript enabled and the quick-add parser has
> unit tests covering `Bok Choi x3 stalks`, `milk x2`, and bare `eggs`.

---

## Files touched

### Created

| File | What it holds |
| --- | --- |
| `app/models/pantry_item/quick_add.rb` | The `name x quantity unit` parser — regex, fallback, `#to_h` |
| `app/controllers/pantry_items_controller.rb` | `index`/`create`/`edit`/`update`/`destroy`, param merging, error stream |
| `app/helpers/pantry_items_helper.rb` | Stream-target ids, quantity formatting, expiry wording |
| `app/javascript/controllers/quantity_controller.js` | The +/− stepper: nudge, debounce, `requestSubmit()` |
| `app/views/pantry_items/index.html.erb` | Header, cable subscription, use-soon, the three groups, datalist |
| `app/views/pantry_items/_location_group.html.erb` | One location's Turbo Frame: heading, quick-add form, item list |
| `app/views/pantry_items/_quick_add.html.erb` | Notation input + `<details>` fallback fields |
| `app/views/pantry_items/_pantry_item.html.erb` | The row frame: stepper form, name link, badge, Remove |
| `app/views/pantry_items/_form.html.erb` | The inline edit form |
| `app/views/pantry_items/edit.html.erb` | Wraps `_form` in the row's frame so Turbo swaps in place |
| `app/views/pantry_items/_use_soon.html.erb` | The server-rendered "use soon" section |
| `app/views/pantry_items/_unit_suggestions.html.erb` | The shared `<datalist>` of units already in use |
| `app/views/pantry_items/create.turbo_stream.erb` | append row · replace form · replace use-soon · replace datalist |
| `app/views/pantry_items/update.turbo_stream.erb` | replace row, or remove+append when the location changed |
| `app/views/pantry_items/destroy.turbo_stream.erb` | remove row · replace use-soon · replace datalist |
| `test/application_system_test_case.rb` | Did not exist before this task — driver, Capybara config, two helpers |
| `test/system/inventory_test.rb` | 12 Capybara tests |
| `test/models/pantry_item/quick_add_test.rb` | 12 parser tests |
| `test/controllers/pantry_items_controller_test.rb` | 17 request tests (replaces `home_controller_test.rb`) |

### Modified

| File | Change |
| --- | --- |
| `app/models/pantry_item.rb` | Added `INVENTORY_STREAM`, `broadcasts_refreshes_to`, `.units_in_use` |
| `app/views/layouts/application.html.erb` | `turbo_refreshes_with method: :morph, scroll: :preserve`; `mt-28` → `mt-12` |
| `config/routes.rb` | `resources :pantry_items, except: %i[ show new ]`; root moved to `pantry_items#index` |
| `Dockerfile.dev` | `chromium` + `chromium-driver`; `CHROME_BINARY` / `CHROMEDRIVER_PATH` env |
| `CLAUDE.md` | Added the `test:system` command and a note on where the browser comes from |
| `test/models/pantry_item_test.rb` | Added 3 tests (`units_in_use`, two broadcast tests) + two `include`s |

### Deleted

| File | Why |
| --- | --- |
| `app/controllers/home_controller.rb` | §4.1: "the main screen is the inventory"; this was Task 1's placeholder |
| `app/views/home/index.html.erb` | Its body literally read "The inventory lives here once it's built." |
| `test/controllers/home_controller_test.rb` | Superseded by `pantry_items_controller_test.rb` |

`app/assets/builds/tailwind.css` is rewritten on every `bin/rails test` by the tailwind
build step. It is gitignored (`.gitignore:37`) and is not a deliverable.

**No new gems.** `capybara` and `selenium-webdriver` were already in the Gemfile's `:test`
group from Task 1; nothing was added to `Gemfile` or `Gemfile.lock`.

## Acceptance

| Clause | Status |
| --- | --- |
| Full CRUD flow works with JavaScript enabled | 12 system tests in real headless chromium cover create / read / update / delete |
| Parser unit test: `Bok Choi x3 stalks` | `"parses name, quantity and unit out of the x notation"` → `"Bok Choi"`, `3`, `"stalks"` |
| Parser unit test: `milk x2` | `"parses name and quantity when no unit is given"` → `"milk"`, `2`, `nil` |
| Parser unit test: bare `eggs` | `"treats a bare string as the whole name and defaults the quantity to one"` → `"eggs"`, `1`, `nil` |
| (a) quick add, tested before (b) | 6 controller tests + 4 system tests |
| (b) inline edit, tested before (c) | 4 controller tests + 3 system tests |
| (c) quantity stepper | 2 controller tests + 3 system tests |
| (d) expiry badges + use soon | 1 controller test + 1 system test (asserts badge present inside the window, absent outside it, and use-soon membership) |
| (e) morphing + broadcasts | 2 model tests; plus a manual two-tab check (below) |
| System tests with Capybara for a, b, c | Present for all three |

Numbers, all from commands run while writing this recap:

```sh
docker compose run --rm app bin/rails test                                     # 58 runs, 206 assertions, 0 failures
docker compose run --rm app bin/rails test:system                              # 12 runs,  46 assertions, 0 failures
docker compose run --rm app bin/rails test test/models/pantry_item/quick_add_test.rb   # 12 runs, 31 assertions
docker compose run --rm app bin/rails test test/controllers/pantry_items_controller_test.rb  # 17 runs, 71 assertions
docker compose run --rm app bin/rails test test/models/pantry_item_test.rb     # 17 runs, 56 assertions
docker compose run --rm app bin/rubocop                                        # 49 files, no offenses
docker compose run --rm app bin/brakeman --no-pager                            # 0 errors, 0 security warnings
```

Note `bin/rails test` does **not** include `test/system` — the 58 and the 12 are disjoint,
70 tests total. CI runs them as two jobs (`.github/workflows/ci.yml`), which is why they
are reported separately here.

### The one thing tests do not cover: (e) end-to-end

The test-env Action Cable adapter is `:test` (`config/cable.yml`), which records broadcasts
but never delivers them to a browser. So the model tests prove the *right refresh signal
goes onto the right stream*, and nothing more. Actual cross-tab delivery was verified by
hand, in this session, with a throwaway Selenium script driving two tabs against the dev
server (script deleted afterwards; it lived in the gitignored `tmp/`). Four checks passed:

1. Quick add in tab A streamed the row into the fridge group.
2. Tab B picked up the write with no manual reload.
3. `<meta name="turbo-refresh-method">` read `morph`.
4. A delete performed in tab B propagated back to tab A.

Caveat on what that proves: **development uses Action Cable's `async` adapter, not Solid
Cable.** Solid Cable is configured for production only. The broadcast path is verified;
the Solid Cable adapter under it is not, and will not be until M3.

## Fidelity to §4.1

§4.1 is prose, not a schema, so this is rule-by-rule:

| §4.1 says | Where it lives |
| --- | --- |
| "grouped by location (fridge / freezer / pantry), each group a Turbo Frame" | `_location_group.html.erb` → `turbo_frame_tag "location_#{location}"`, one per enum key |
| "a persistent inline form at the top of each group" | `_quick_add.html.erb`, rendered above the item list inside the group frame |
| "One text input that accepts natural notation — `Bok Choi x3 stalks`" | `text_field_tag "pantry_item[quick_add]"` |
| "parsed server-side with a small regex" | `PantryItem::QuickAdd::NOTATION` (`quick_add.rb:12`), one regex; 32 lines of file including comments |
| "quantity defaulting to 1" | `QuickAdd::DEFAULT_QUANTITY` |
| "unit optional with a `<datalist>` of previously used units as fallback fields" | `_unit_suggestions.html.erb` + the `<details>` block in `_quick_add` |
| "appends the new item to its group via a Turbo Stream response, resets the form" | `create.turbo_stream.erb` lines 1 and 2 |
| "no broadcast needed for the actor's own tab" | Honoured — turbo-rails filters the actor's own refresh by request id; the stream response is what updates their view |
| "each item row is a frame; clicking swaps in an edit form, saving swaps back" | `_pantry_item.html.erb` frame + `edit.html.erb` + `update.turbo_stream.erb` |
| "+/− buttons that debounce and PATCH the quantity" | `quantity_controller.js`, 400 ms default debounce |
| "items expiring within 3 days get a badge" | `_pantry_item.html.erb`, gated on `expiring_soon?` (Task 2's `EXPIRING_SOON_WINDOW`) |
| "a 'use soon' section at the top is computed server-side. No JS at all" | `_use_soon.html.erb`; no Stimulus controller, no data attributes |
| "enable page refreshes with morphing" | `turbo_refreshes_with method: :morph, scroll: :preserve` in the layout head |

Nothing was added to the schema — **no migration, no new column, no new index**. The two
non-negotiables were not touched: no new database or cache backend appears anywhere in
this task, and nothing here reaches the LLM.

## Surface

**`PantryItem::QuickAdd`** (new class)
- `NOTATION` — `/\A(?<name>.*\S)\s+x\s*(?<quantity>\d+(?:\.\d+)?)(?:\s+(?<unit>\S.*))?\z/i`. The `x` must be preceded by whitespace, so `"box of wine"` parses as a name. `name` is greedy, so the *last* x-number wins (`"beer x6 x2"` → six-packs ×2). Tested.
- `DEFAULT_QUANTITY = 1`.
- `#initialize(input)` — squishes; `nil` and `""` are accepted and yield `name == nil`. Tested.
- `#name` / `#quantity` / `#unit` — raw captures, **not normalized**; `quantity` is a `BigDecimal`. Tested including `x1.5`.
- `#to_h` — compacted, so a key the text said nothing about is absent rather than `nil`. This is load-bearing for the merge in the controller. Tested.

**`PantryItem`** (additions)
- `INVENTORY_STREAM = "pantry_items"` — the single cable stream for the whole inventory.
- `broadcasts_refreshes_to ->(_item) { INVENTORY_STREAM }` — create, update **and** destroy each emit one `<turbo-stream action="refresh">`. Both facts tested.
- `.units_in_use` — distinct, non-nil, `ORDER BY unit`. Tested.

**`PantryItemsController`**
- `index` (root and `/pantry_items`), `create`, `edit`, `update`, `destroy`. No `show`, no `new`.
- Every write action answers `turbo_stream` **and** `html` (redirect), so the screen degrades without JS. The two HTML fallbacks are tested.
- Failures return `:unprocessable_content` (Rack 3.1's name; `:unprocessable_entity` is the deprecated alias).
- `expiring_soon` / `units_in_use` are `helper_method`s, memoized per request.

**`PantryItemsHelper`**
- `location_frame_id` → `location_fridge`; `location_items_id` → `fridge_items`; `quick_add_id` → `quick_add_fridge`; `quick_add_field_id` → `quick_add_field_fridge`. These four strings are the entire Turbo Stream target contract.
- `formatted_quantity` — `number_with_precision(..., strip_insignificant_zeros: true)`, so `decimal(8,2)` renders `3` not `3.0`.
- `expiry_label` — `"expired"` (≤ −2 days), `"expired yesterday"`, `"today"`, `"tomorrow"`, `"in N days"`. Assumes `expires_on` is present; the only two call sites gate on that.

**`quantity` Stimulus controller** — targets `input`; values `delay` (400), `min` (0), `step` (1). `increment`/`decrement`/`save`. Clears its timeout on `disconnect`.

**`ApplicationSystemTestCase`** (new)
- `Capybara.enable_aria_label = true`, `Capybara.default_max_wait_time = 5`.
- `sign_in_as(user, password: "password")` — goes through the real form, then asserts the inventory rendered.
- `assert_stored_quantity(item, expected)` — polls `reload` to the Capybara wait time, because the stepper's PATCH is asynchronous and there is no DOM signal that distinguishes the optimistic value from the saved one.

## Decisions a reviewer should weigh

### 1. `broadcasts_refreshes_to`, not the `broadcasts_refreshes` the task names

**Beyond the literal task text.** The task says "enable Turbo 8 morphing with
`broadcasts_refreshes`". In turbo-rails 2.0.23 that bare method expands to:

```ruby
after_create_commit  -> { broadcast_refresh_later_to(stream) }   # stream = "pantry_items"
after_update_commit  -> { broadcast_refresh_later }              # stream = the record itself
after_destroy_commit -> { broadcast_refresh }                    # stream = the record itself
```

Updates and destroys go to a **per-record** stream. The inventory index would therefore
need one `turbo_stream_from` per row to see an edit — N subscriptions for a screen that
has exactly one meaningful stream. `broadcasts_refreshes_to ->(_item) { INVENTORY_STREAM }`
points all three at one stream instead.

§4.1 asks only for "broadcast updates (e.g., a second tab…) smoothly patch the DOM" and
names no method, so I read this as an implementation detail rather than a doc conflict —
but it is a deviation from the task's literal wording, hence its place at the top of this
list. Covered by `"creating, updating and destroying each broadcast a refresh to the
inventory stream"` (count: 3).

**If a reviewer disagrees:** replace the one line in `app/models/pantry_item.rb` with
`broadcasts_refreshes`, add `turbo_stream_from pantry_item` inside `_pantry_item.html.erb`,
and drop `INVENTORY_STREAM`. The two broadcast tests would need rewriting against record
streams.

### 2. Chromium added to `Dockerfile.dev` (scope beyond the literal task)

Task 3 requires Capybara system tests. Two things were missing: the container had no
browser, and `test/application_system_test_case.rb` did not exist at all. CI's
`system-test` job in `.github/workflows/ci.yml` has existed since Task 1, but with no
`test/system/*_test.rb` files it had nothing to run — I did not execute CI to confirm that,
so treat it as inference from the task list rather than a verified fact. CLAUDE.md says
there is no Ruby on the host, so the browser has to be in the image.

`chromium` + `chromium-driver` are now installed, and the image exports `CHROME_BINARY` and
`CHROMEDRIVER_PATH`. `application_system_test_case.rb` reads both **conditionally** — CI's
ubuntu runner has real Google Chrome, sets neither variable, and gets stock Selenium
Manager behaviour. Setting `driver_path` is what stops Selenium Manager from trying to
download a chromedriver for a Chrome that isn't installed.

**Known cost:** the dev image is meaningfully larger. The considered alternative was a
`selenium/standalone-chromium` service in `docker-compose.yml` with `Capybara.server_host`
/ `app_host` wiring so the remote browser could reach Puma — slimmer image, more moving
parts and more failure modes. I picked the simpler one.

**If a reviewer disagrees:** remove the two apt packages and the `ENV` line from
`Dockerfile.dev`; `application_system_test_case.rb` needs no change, since both lookups are
already conditional.

### 3. `home#index` deleted and root repointed

**Beyond the literal task text.** §4.1 opens "The main screen is the inventory", and
Task 1's home view said "The inventory lives here once it's built." Rather than render the
inventory inside `HomeController`, root now points at `pantry_items#index` and the three
home files are gone. `home_controller_test.rb`'s two cases (redirect when signed out,
renders when signed in) are both reproduced in `pantry_items_controller_test.rb`.

**If a reviewer disagrees:** restoring a `HomeController` that renders
`pantry_items#index`'s template is mechanical, but the sign-out button and the
`turbo_stream_from` subscription live in `index.html.erb` and would move with it.

### 4. `quick_add` is not a model attribute

The notation field is named by hand — `text_field_tag "pantry_item[quick_add]"` — rather
than `form.text_field :quick_add` backed by an `attribute :quick_add, :string`.

The reason is ordering. A virtual attribute with a setter that applies the parse would run
whenever `PantryItem.new(hash)` reached that key, so whether the explicit `quantity` field
or the parsed `x2` won would depend on hash order. Merging in the controller
(`PantryItemsController#new_item_attributes`) makes precedence explicit and
order-independent: parse first, then `compact_blank` the form fields over the top. This is
also what makes `QuickAdd#to_h`'s compaction load-bearing.

Covered both ways: `"explicit fallback fields win over the parsed notation"` and
`"blank fallback fields leave the parsed values alone"`.

### 5. The stepper submits a form; it does not `fetch`

§4.1 says "a small Stimulus controller … that debounce and PATCH the quantity". The
controller does not issue the request itself — it sets `input.value`, debounces, and calls
`this.element.requestSubmit()` on the `form_with` it is attached to. Turbo intercepts the
submit and PATCHes. Net effect: no `fetch`, no manual CSRF token, no response parsing in
JavaScript, and the stepper and the inline edit form share one controller action.

The cost is that the response `turbo_stream.replace`s the whole row, so the number input is
a new DOM node afterwards and loses focus. That is invisible for button clicks (the debounce
has already settled) and is why the number input submits on `change` (blur/Enter) rather
than on `input`.

**If a reviewer disagrees:** the controller would grow a `fetch` with an
`Accept: text/vnd.turbo-stream.html` header, a CSRF token read from the meta tag, and a
`Turbo.renderStreamMessage` call — roughly fifteen more lines for the same behaviour.

### 6. Badges only inside the three-day window

First cut showed a muted badge for every dated item. §4.1 says "items expiring within 3 days
get a badge" and nothing about the rest, and the screen was visibly noisy — a pantry of 22
items showed "in 180 days", "in 120 days", "in 90 days" and so on. Badges are now gated on
`expiring_soon?`; other dates live in the edit form. Locked by
`assert_no_text "in 10 days"` in the system test.

### 7. New rows append rather than sort into place

`create.turbo_stream.erb` appends, so a new row lands at the bottom of its group even though
`PantryItem.ordered` sorts by name and a page load would place it alphabetically. §4.1
specifies "appends the new item to its group", and seeing what you just typed is better than
watching it vanish into a list — but it is a real inconsistency between the streamed view and
the reloaded one, and it is not hidden by a test.

### 8. Layout margin changed

`app/views/layouts/application.html.erb` went from `mt-28` to `mt-12`. One class, but the
layout is shared with the sign-in and password pages, so it changes those too. 7rem of
leading whitespace above a three-column inventory looked wrong.

### 9. Two test-infrastructure choices

- **`Capybara.enable_aria_label = true`.** The stepper's +/− and the Remove button carry
  `aria-label`s rather than visible text. Without this the tests would have to match on
  `title` attributes or the literal `−` (U+2212). The a11y labels are wanted regardless;
  this just lets the tests use them.
- **`assert_stored_quantity` polls the database.** After a stepper click the DOM already
  shows the new number optimistically, so no Capybara matcher can distinguish "saved" from
  "not yet saved". The helper polls `reload` up to `Capybara.default_max_wait_time`. It
  relies on system tests sharing a connection with the server thread, which Rails does.

## Deliberately not done

- **No `show` action or route.** An item is only ever seen inside its location group.
- **No new gems, no migration, no schema change.** Task 3 is presentation over Task 2's table.
- **No `turbo_stream_from` per record.** See decision 1.
- **No system test for (e).** The task asks for system tests for a, b and c only, and the
  `:test` cable adapter cannot deliver a broadcast to a browser. Switching
  `config/cable.yml`'s test entry to `async` would enable a two-session system test; I did
  not, because it is test-infrastructure scope the task did not ask for and a new source of
  flake. The manual verification above is what stands in its place, and its limits are
  stated.
- **No `in_stock` / zero-quantity filtering.** Still Task 4's business. A `quantity: 0` item
  with a near date still shows in "use soon" — carried forward from Task 2's open question 1,
  unchanged.
- **No suggestion UI, no LLM anything.** Tasks 4–6.
- **`hello_controller.js` left in place.** It is the Rails generator's sample controller and
  predates this task; deleting it was not mine to do here.

## What Task 4 inherits

- **The write path is `PantryItemsController`.** Task 4's coverage recomputation triggers on
  "item deleted or quantity hits zero" (§5) — both funnel through `update` and `destroy`
  there. The stepper reaching zero is an ordinary `update`, not a special case.
- **`INVENTORY_STREAM` already exists and already fires on every commit.** When Task 6's
  cooking transaction zeroes several items, each one broadcasts a refresh; turbo-rails
  debounces them per request, so the "one click, three coordinated morphing updates" §4.3
  describes should fall out without new broadcast code.
- **Four helper-defined stream-target ids** (`location_frame_id`, `location_items_id`,
  `quick_add_id`, `quick_add_field_id`) are the contract for anything that wants to patch the
  inventory from outside. Route through the helper, not string interpolation.
- **`expiring_soon` and `units_in_use` are `helper_method`s memoized per request** — a
  controller that renders `_use_soon` or `_unit_suggestions` from a different action gets them
  for free, but a second render in the same request will not see intervening writes.
- **`assert_stored_quantity`** in `ApplicationSystemTestCase` is reusable for Task 6's
  deduction assertions, which have the same "async write, no distinguishing DOM signal" shape.

## Open questions

1. **Should `config/cable.yml`'s test adapter become `async` so cross-tab behaviour is
   testable?** Task 6's acceptance ("watch quantities drop and a stale run archive itself")
   is exactly a broadcast-delivery assertion, so this decision is due there, not later.
2. **Append-vs-sort on create** (decision 7) — worth revisiting once Task 6 adds a second
   writer to the same lists, since a cook that zeroes an item may make position drift more
   noticeable.
3. **Does the `<details>` fallback block belong in quick add at all?** §4.1's phrasing
   ("unit optional with a `<datalist>` of previously used units as fallback fields") is
   ambiguous about whether "fallback fields" means just quantity/unit or a full create form.
   I included quantity, unit, category and `expires_on`. If demo-mode screenshots (§6, M3)
   want a tighter screen, category and expiry are the two to cut.
