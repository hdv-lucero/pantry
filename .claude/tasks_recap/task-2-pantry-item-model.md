# Task 2 Recap — PantryItem model and inventory schema

**Completed:** 2026-07-25 · **Branch:** `main` (repo has no commits yet; all files untracked)
**Governing spec:** `pantry-app-design-doc.md` §3 (schema), §4.1 (expiry window)
**Task text:** `claude-code-initial-tasks.md` → Task 2

> Implement `PantryItem` exactly as §3 specifies: name, decimal quantity defaulting to 1,
> free-text unit, location enum (pantry/fridge/freezer), category enum, `expires_on`, with
> the two indexes. Add the light normalization on save (downcase, singularize — §3) and
> scopes: per-location grouping and `expiring_soon` (within 3 days, §4.1). Model tests for
> normalization and the expiry scope. No UI yet.

---

## Files touched

| File | What it holds |
| --- | --- |
| `db/migrate/20260725060126_create_pantry_items.rb` | The §3 table, column-for-column, plus both indexes |
| `db/schema.rb` | Regenerated (`pantry_items` at lines 14–25) |
| `app/models/pantry_item.rb` | Enums, normalization, scopes, `expiring_soon?` |
| `config/initializers/inflections.rb` | Food-word inflections — see Decision 2 |
| `db/seeds.rb` | Appended a 22-item pantry below the existing user seed |
| `test/models/pantry_item_test.rb` | 14 tests |
| `test/fixtures/pantry_items.yml` | 6 pre-normalized rows (replaces the generator's `MyString` stub) |

Nothing else was modified. No new gems. No controllers, routes, or views — Task 2 is
explicitly model-only.

## What the acceptance check required, and how it was met

| Requirement | Status |
| --- | --- |
| Model tests green | 14 tests, 49 assertions. Full suite: 28 runs, 103 assertions, 0 failures |
| Seeds create a plausible ~20-item pantry | 22 items |
| …across all three locations | pantry 10 / fridge 8 / freezer 4 |
| …with a few near-expiry items | 3 within the window: chicken thigh (+1d), baby spinach (+2d), milk (+2d) |
| Seed is the demo-mode base later (§6) | Expiry dates are relative to `Date.current`, so the "use soon" section is never empty regardless of when it runs |

Reproduce:

```sh
docker compose run --rm app bin/rails test          # 28 runs, 0 failures
docker compose run --rm app bin/rails db:seed       # run twice — still 22 rows
docker compose run --rm app bin/rubocop             # 44 files, no offenses
docker compose run --rm app bin/brakeman --no-pager # 0 warnings
```

## Schema fidelity to §3

Every column matches the design doc's `create_table` block: `name` (`null: false`),
`quantity` (`decimal`, precision 8, scale 2, default 1), `unit` (string, nullable),
`location` (`integer, null: false, default: 0`), `category` (integer, **nullable, no
default** — as the doc has it), `expires_on` (date), timestamps. Both `add_index` lines
present (`location`, `expires_on`). No extra columns, no extra indexes.

## Model surface

- `EXPIRING_SOON_WINDOW = 3.days` — one constant, referenced by the scope, the predicate,
  and the seed output.
- `enum :location, { pantry: 0, fridge: 1, freezer: 2 }`
- `enum :category, { produce: 0, dairy: 1, protein: 2, grains: 3, condiments: 4, other: 5 }`
- `normalizes :name` — `squish.downcase.singularize`
- `normalizes :unit` — `squish.downcase.presence` (nil for blank)
- `validates :name, presence: true`; `validates :quantity, numericality: { greater_than_or_equal_to: 0 }`
- `scope :ordered` — `order(:name)`
- `scope :expiring_soon` — `where(expires_on: ..3.days.from_now.to_date).order(:expires_on, :name)`
- `PantryItem.grouped_by_location` — one query; returns **all three** enum keys in enum
  order (`pantry`, `fridge`, `freezer`) even when a location is empty, so Task 3's three
  Turbo Frames render without nil checks. Composes with other scopes
  (`PantryItem.expiring_soon.grouped_by_location` is tested).
- `#expiring_soon?` — row-level predicate for the §4.1 badge.

Semantics chosen for `expiring_soon`, all covered by tests: **includes** already-expired
items (the "use soon" section should surface them), **includes** the boundary day
(exactly +3), **excludes** `expires_on IS NULL` (falls out of the SQL range comparison).

---

## Decisions a reviewer should weigh

### 1. Units are downcased but not singularized

§3 says names get "downcasing, singularizing on save". The `unit` column's own comment
says only "free text, normalized lightly", and its examples are plural: `"g", "ml",
"pcs", "cans"`. Singularizing units would produce `pcs` → `pc` and `cans` → `can`,
contradicting the doc's own examples and muddying the `<datalist>` of previously-used
units that Task 3 (§4.1 quick add) builds from this column. So `unit` gets
squish + downcase only.

**If a reviewer disagrees:** the change is one lambda in `app/models/pantry_item.rb` plus
the `"downcases unit without singularizing it"` test, but the §4.1 datalist and the seed
units would need revisiting together.

### 2. Added inflection rules for food words (scope beyond the literal task)

Singularizing free-text food names walks the stock Rails inflector into real breakage,
verified in the container:

```
asparagus -> asparagu     olives -> olife      pasta  -> pastum
hummus    -> hummu        cloves -> clofe      leaves -> leafe
couscous  -> couscou      molasses -> molass   loaves -> loafe
```

This is not cosmetic downstream: §5 validates LLM-returned item names **exactly** against
the run's inventory snapshot, so a mangled stored name becomes a silent drop of a valid
suggestion. `config/initializers/inflections.rb` (a file Rails already ships as a
commented template — no new dependency) now declares 6 uncountables
(`asparagus couscous grits hummus molasses pasta`) and 4 irregulars (`clove`, `leaf`,
`loaf`, `olive`). Covered by the `"keeps food words the default inflector mangles"` test.

**Known limits:** the list is empirical, not exhaustive — it fixes what a plausible pantry
contains, not every English food noun. Anything else ending in `-us`/`-ss`/`-ves` will
still mangle. Task 3 introduces real user-typed input via quick add and is the natural
place to decide whether this needs a broader answer.

**If a reviewer disagrees:** deleting the block restores stock behavior; only that one
test fails.

### 3. Fixtures are pre-normalized

`test/fixtures/pantry_items.yml` stores names as the model would write them (`egg`, not
`Eggs`) — fixtures bypass callbacks, so any other spelling would be a row the app cannot
actually produce. The six rows deliberately span every case the scopes care about:
future expiry inside the window (`milk`), past expiry (`yogurt`), future expiry outside it
(`egg`, `ground_beef`), and null expiry (`rice`, `olive_oil`), across all three locations.

Because `fixtures :all` loads these into every test, scope tests assert with
`assert_includes` / `assert_not_includes` rather than absolute counts. The two tests that
genuinely need an empty table (`"expiring_soon is ordered by expiry date"`,
`"grouped_by_location keeps empty locations"`) call `PantryItem.delete_all` inside the
transactional test, which rolls back.

### 4. Two validations the doc doesn't name

`name` presence (mirrors `null: false`) and `quantity >= 0`. Non-negative quantity is a
precondition for Task 4's coverage math and Task 6's "I made this" deduction, both of
which reason about items being at or above zero. Neither validation is in §3; both are
small and removable.

## Deliberately not done

- **No UI** — the task says "No UI yet". No controller, routes, views, or system tests.
- **No `in_stock` scope** — "still in stock" is Task 4's coverage computation; adding it
  now would be guessing at that task's shape.
- **No user association** — §3's `pantry_items` has no `user_id`, and the app is
  single-household. Not an oversight; flag it if the doc is read differently.
- **No `PantryItem` ↔ suggestion wiring** — Tasks 4–6.

## What Task 3 inherits from this

- `grouped_by_location` is the inventory screen's entry point; guaranteed three keys.
- `expiring_soon` (section) and `expiring_soon?` (per-row badge) are both ready.
- `unit` values across the seed give the quick-add `<datalist>` real content:
  `gallon, pcs, cups, bag, g, jar, lb, sheet, kg, cans, ml, bottle, bulb`.
- The quick-add parser (`name x quantity unit`) must feed the parsed name through the
  same `normalizes` path — it does so automatically via attribute assignment, but the
  parser's unit tests (`Bok Choi x3 stalks` → name `bok choi`) should assert the
  normalized result, not the raw capture.

## Open questions carried forward

1. Does `expiring_soon` need to exclude zero-quantity items once Task 4 defines "in
   stock"? Currently a `quantity: 0` item with a near date still appears in "use soon".
2. Should the inflections list grow, or should Task 3 handle mangled input differently
   (e.g. preserve the user's typed name alongside a normalized key)? §5's exact-name
   matching is the constraint that makes this matter.
