# Pantry

Inventory tracking with LLM-powered recipe suggestions. Portfolio project whose
point is demonstrating a 2026-era Rails app that leans on the defaults.

`pantry-app-design-doc.md` is the source of truth for every decision.
`claude-code-initial-tasks.md` holds the task breakdown and their acceptance checks.

## Non-negotiable constraints

**SQLite everywhere.** SQLite is the production database for the app *and* for the
queue, cache, and cable backends (Solid Queue, Solid Cache, Solid Cable), each on its
own `.sqlite3` file — four in production, and they must not be consolidated. Never
introduce Postgres, Redis, Valkey, Memcached, or Sidekiq. (§2, §7)

**Existing recipes only.** The LLM feature surfaces real, already-published recipes
found via the Anthropic web search tool, every one traceable to a live source URL. It
never generates recipes, and cards never reproduce a source's instructions or
ingredient list — just our own one-to-two-sentence summary, the overlap data, and the
link. (§1, §5)

**When a task conflicts with the design doc, stop and flag it.** Do not improvise a
resolution.

## Conventions

- **Minitest, not RSpec.** System tests via Capybara.
- **No new gems without justification.** The Rails 8 defaults (importmap, Propshaft,
  Turbo, Stimulus, Tailwind, Solid stack, Kamal) are the intended toolkit. If a gem
  seems necessary, say why before adding it.
- Hotwire does the interactive work — Turbo frames, streams, and morphing, with
  Stimulus for sprinkles. No custom JSON API, no frontend framework.
- Ruby 3.4, Rails 8.1.

## Development is dockerized

There is no Ruby on the host — `bin/rails` only works inside the container. Dev uses
`Dockerfile.dev` (bakes no app code; the bind-mounted tree is the source of truth).
The root `Dockerfile` and `.kamal/` belong to the production Kamal deploy — leave them
alone until M3.

```sh
docker compose up                                   # http://localhost:3000
docker compose run --rm app bin/rails db:seed       # first account, prints credentials
docker compose run --rm app bin/rails test
docker compose run --rm app bin/rails test:system         # Capybara; chromium is in the image
docker compose run --rm app bin/rails console
docker compose run --rm app bin/rubocop             # rails-omakase
docker compose run --rm app bin/brakeman --no-pager
docker compose build app                            # after changing Dockerfile.dev
```

Gems live in the `bundle_cache` volume, so `bundle install` survives container
restarts but not a `docker compose down -v`.

Notes:
- The container user is uid/gid 1000 to match the host user; files it writes into the
  repo stay owned by you. Keep it that way.
- System tests run against Debian's chromium, installed in `Dockerfile.dev`.
  `CHROME_BINARY` / `CHROMEDRIVER_PATH` are set there and read by
  `test/application_system_test_case.rb`; CI's runner has real Chrome and sets
  neither, so Selenium Manager handles it there.
- `SOLID_QUEUE_IN_PUMA` is commented out in `docker-compose.yml`. Rails' generated
  development config uses the `:async` queue adapter against a single
  `development.sqlite3` with no `solid_queue` tables, so enabling it as-is crashes the
  supervisor on boot. Task 5 is where a real development queue gets decided.
- There is no sign-up UI (the Rails 8 auth generator ships none by design). Accounts
  come from `db/seeds.rb`.
