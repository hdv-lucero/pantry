require "test_helper"
require "turbo/broadcastable/test_helper"

class SuggestionRunTest < ActiveSupport::TestCase
  include Turbo::Broadcastable::TestHelper

  # Everything the pantry_items fixtures have on hand, which is what the coverage
  # math sees unless a test says otherwise.
  IN_STOCK = [ "milk", "greek yogurt", "egg", "ground beef", "rice", "olive oil" ].freeze

  test "a new run is queued and active" do
    run = SuggestionRun.create!

    assert_predicate run, :queued?
    assert_not_predicate run, :archived?
    assert_includes SuggestionRun.active, run
  end

  test "active and archived partition the runs" do
    assert_equal SuggestionRun.count, SuggestionRun.active.count + SuggestionRun.archived.count
    assert_includes SuggestionRun.archived, suggestion_runs(:history)
    assert_not_includes SuggestionRun.active, suggestion_runs(:history)
  end

  test "the inventory snapshot round-trips as json" do
    snapshot = suggestion_runs(:beef_night).inventory_snapshot

    assert_equal 4, snapshot.size
    assert_equal "ground beef", snapshot.first["name"]
    assert_nil snapshot.second["expires_on"]
  end

  test "suggestions come back in the position the job assigned" do
    assert_equal [ "Gyudon (Japanese Beef Bowl)", "Shakshuka" ],
      suggestion_runs(:beef_night).recipe_suggestions.map(&:title)
  end

  test "used_item_names collects the run's uses_items" do
    assert_equal [ "ground beef", "rice", "egg", "olive oil" ], suggestion_runs(:beef_night).used_item_names
  end

  test "used_item_names counts an item two suggestions share only once" do
    run = suggestion_runs(:beef_night)
    run.recipe_suggestions.create!(recipe: recipes(:rice_pudding), title: "Rice Pudding",
                                   uses_items: [ "rice", "milk" ], position: 3)

    assert_equal [ "ground beef", "rice", "egg", "olive oil", "milk" ], run.reload.used_item_names
  end

  # §5 — coverage is the fraction of the items the run leans on that are still in
  # stock, measured against live inventory rather than the snapshot.
  test "coverage is one when every used item is in stock" do
    assert_equal Rational(1), suggestion_runs(:beef_night).coverage
  end

  test "coverage is one for a run with no suggestions yet" do
    assert_equal Rational(1), suggestion_runs(:pending).coverage
    assert_not_predicate suggestion_runs(:pending), :stale?
  end

  test "coverage drops as used items leave the inventory" do
    pantry_items(:milk).update!(quantity: 0)

    assert_equal Rational(1, 2), suggestion_runs(:breakfast).coverage
    assert_equal Rational(2, 3), suggestion_runs(:dessert).coverage
  end

  test "coverage ignores items that were never in the pantry" do
    # The archived run leans on "bok choi", which no pantry_items fixture has.
    assert_equal Rational(1, 2), suggestion_runs(:history).coverage
  end

  test "coverage measures against the names it is given" do
    assert_equal Rational(1, 2), suggestion_runs(:breakfast).coverage([ "milk", "rice" ])
    assert_equal Rational(0), suggestion_runs(:breakfast).coverage([])
  end

  # §5 — "more than a third of used items out of stock". Exactly a third is not
  # more than a third; these two sit either side of that line.
  test "a run with exactly a third of its items out of stock is not stale" do
    run = suggestion_runs(:dessert)   # milk, rice, egg

    assert_equal Rational(2, 3), run.coverage(IN_STOCK - [ "milk" ])
    assert_not run.stale?(IN_STOCK - [ "milk" ])
  end

  test "a run past a third out of stock is stale" do
    run = suggestion_runs(:dessert)

    assert_equal Rational(1, 3), run.coverage(IN_STOCK - [ "milk", "rice" ])
    assert run.stale?(IN_STOCK - [ "milk", "rice" ])
  end

  test "archive! stamps the run once and does not move the timestamp" do
    run = suggestion_runs(:beef_night)
    run.archive!
    archived_at = run.reload.archived_at

    assert_predicate run, :archived?

    travel 1.hour do
      run.archive!

      assert_equal archived_at, run.reload.archived_at
    end
  end

  test "archive_stale! archives only the active runs below the threshold" do
    archived = SuggestionRun.archive_stale!(IN_STOCK - [ "milk" ])

    assert_equal [ suggestion_runs(:breakfast) ], archived
    assert_predicate suggestion_runs(:breakfast).reload, :archived?
    assert_not_predicate suggestion_runs(:dessert).reload, :archived?
    assert_not_predicate suggestion_runs(:beef_night).reload, :archived?
    assert_not_predicate suggestion_runs(:pending).reload, :archived?
  end

  test "archive_stale! leaves an already archived run's timestamp alone" do
    archived_at = suggestion_runs(:history).archived_at

    SuggestionRun.archive_stale!([])

    assert_equal archived_at, suggestion_runs(:history).reload.archived_at
  end

  test "archive_stale! defaults to the live inventory" do
    # update_all skips the callbacks, so this exercises the class method itself
    # rather than the trigger PantryItem hangs off it.
    PantryItem.where(name: "milk").update_all(quantity: 0)

    assert_equal [ suggestion_runs(:breakfast) ], SuggestionRun.archive_stale!
  end

  test "destroying a run takes its suggestions with it but leaves the recipes" do
    assert_difference -> { RecipeSuggestion.count }, -2 do
      assert_no_difference -> { Recipe.count } do
        suggestion_runs(:history).destroy!
      end
    end
  end

  # ── §4.2's lifecycle, added in Task 5 ───────────────────────────────────────

  test "start! records the snapshot and flips to running in one write" do
    run = SuggestionRun.create!
    snapshot = InventorySnapshot.current

    run.start!(snapshot)

    assert_predicate run, :running?
    assert_equal snapshot.entries, run.reload.inventory_snapshot
  end

  test "complete! creates the cards and flips to completed" do
    run = SuggestionRun.create!

    run.complete!([ {
      title: "A Real Recipe", source_url: "https://www.seriouseats.com/a-real-recipe",
      source_name: "Serious Eats", summary: "Something you can make.",
      uses_items: [ "rice" ], missing_items: [ "sugar" ], substitutions: [], position: 0
    } ])

    assert_predicate run, :completed?
    assert_equal "A Real Recipe", run.recipe_suggestions.sole.title
  end

  test "complete! rolls back every card if one is unusable" do
    run = SuggestionRun.create!
    good = { title: "Fine", source_url: "https://www.seriouseats.com/fine", source_name: "Serious Eats",
             summary: "Fine.", uses_items: [ "rice" ], missing_items: [], substitutions: [], position: 0 }
    bad = good.merge(title: nil, source_url: "https://www.seriouseats.com/bad", position: 1)

    assert_raises(ActiveRecord::RecordInvalid) { run.complete!([ good, bad ]) }

    assert_equal 0, run.reload.recipe_suggestions.count
    assert_not_predicate run, :completed?
  end

  test "fail! records a message and flips to failed" do
    run = SuggestionRun.create!

    run.fail!("Couldn't reach the recipe search. Try again?")

    assert_predicate run, :failed?
    assert_equal "Couldn't reach the recipe search. Try again?", run.error_message
  end

  test "a failed run is still active — only coverage archives a run" do
    run = SuggestionRun.create!
    run.fail!("nope")

    assert_not_predicate run, :archived?
    assert_includes SuggestionRun.active, run
  end

  test "an over-long error message is truncated rather than rejected" do
    run = SuggestionRun.create!

    run.fail!("x" * 900)

    assert_equal 500, run.error_message.length
  end

  # ── §4.2's broadcasts ───────────────────────────────────────────────────────

  test "each status change broadcasts once" do
    run = SuggestionRun.create!

    assert_turbo_stream_broadcasts SuggestionRun::BROADCAST_STREAM, count: 1 do
      run.start!(InventorySnapshot.current)
    end

    assert_turbo_stream_broadcasts SuggestionRun::BROADCAST_STREAM, count: 1 do
      run.fail!("nope")
    end
  end

  test "a write that changes neither status nor archived_at does not broadcast" do
    run = SuggestionRun.create!
    run.start!(InventorySnapshot.current)

    assert_turbo_stream_broadcasts SuggestionRun::BROADCAST_STREAM, count: 0 do
      run.update!(prompt_notes: "something quick")
    end
  end

  # §4.3's cascade ends here: the pantry write archives the run, and only a broadcast
  # can take its card off a screen nobody is re-rendering.
  test "archiving broadcasts a removal, and only the first one does" do
    run = suggestion_runs(:beef_night)

    assert_turbo_stream_broadcasts SuggestionRun::BROADCAST_STREAM, count: 1 do
      run.archive!
      run.archive!
    end
  end

  test "the removal broadcast targets the run's own card" do
    run = suggestion_runs(:beef_night)

    run.archive!

    # The pubsub adapter stores the encoded payload, so the markup comes back out
    # of the JSON it was wrapped in.
    stream = JSON.parse(ActionCable.server.pubsub.broadcasts(SuggestionRun::BROADCAST_STREAM).last)

    assert_includes stream, %(action="remove")
    assert_includes stream, %(target="#{ActionView::RecordIdentifier.dom_id(run)}")
  end

  # ── §5's per-day limit ──────────────────────────────────────────────────────

  test "today counts only runs created today" do
    SuggestionRun.create!
    travel_to 2.days.ago do
      SuggestionRun.create!
    end

    assert_equal SuggestionRun.where(created_at: Time.current.all_day).count, SuggestionRun.today.count
    assert_not_includes SuggestionRun.today.pluck(:created_at).map(&:to_date), 2.days.ago.to_date
  end

  test "daily_limit_reached? flips at the limit" do
    clear_runs
    (SuggestionRun::DAILY_LIMIT - 1).times { SuggestionRun.create! }

    assert_not SuggestionRun.daily_limit_reached?

    SuggestionRun.create!

    assert SuggestionRun.daily_limit_reached?
  end

  test "within_daily_limit? counts only the runs before this one" do
    clear_runs
    runs = (SuggestionRun::DAILY_LIMIT + 1).times.map { SuggestionRun.create! }

    # The last one allowed is the DAILY_LIMIT-th; the one after it is not.
    assert_predicate runs[SuggestionRun::DAILY_LIMIT - 1], :within_daily_limit?
    assert_not_predicate runs[SuggestionRun::DAILY_LIMIT], :within_daily_limit?
  end

  test "yesterday's runs do not count against today" do
    clear_runs
    travel_to 1.day.ago do
      SuggestionRun::DAILY_LIMIT.times { SuggestionRun.create! }
    end

    assert_not SuggestionRun.daily_limit_reached?
    assert_predicate SuggestionRun.create!, :within_daily_limit?
  end

  # ── §4.3's favorites badge ──────────────────────────────────────────────────

  test "includes_favorite? sees a thumbs-up on any of the run's recipes" do
    assert_predicate recipes(:shakshuka), :favorite?

    run = SuggestionRun.create!
    run.recipe_suggestions.create!(recipe: recipes(:overnight_oats), title: "Oats", uses_items: [])

    assert_not_predicate run, :includes_favorite?

    run.recipe_suggestions.create!(recipe: recipes(:shakshuka), title: "Shakshuka", uses_items: [])

    assert_predicate run.reload, :includes_favorite?
  end

  # The panel's own query. Counted rather than just listed because the preload it
  # carries would answer this question with one row per card if it joined.
  test "on_screen is the active runs, newest first, one row each" do
    assert_equal SuggestionRun.active.count, SuggestionRun.on_screen.count
    assert_equal SuggestionRun.active.order(created_at: :desc).to_a, SuggestionRun.on_screen.to_a
    assert_not_includes SuggestionRun.on_screen, suggestion_runs(:history)
  end

  # §4.3 — a thumbs-down takes one card out of the active view without touching the
  # run or its siblings.
  test "visible_suggestions drops the blocked cards and keeps the rest" do
    run = suggestion_runs(:beef_night)

    assert_equal run.recipe_suggestions.to_a, run.visible_suggestions

    recipes(:gyudon).update!(make_again: false)

    assert_equal [ recipe_suggestions(:beef_night_shakshuka) ], run.reload.visible_suggestions
    assert_not_predicate run, :archived?
  end

  # The run still leans on what a hidden card uses, so hiding one must not quietly
  # move the coverage score that decides when the whole run is archived (§5).
  test "a blocked card still counts toward coverage" do
    recipes(:gyudon).update!(make_again: false)

    assert_includes suggestion_runs(:beef_night).used_item_names, "ground beef"
  end

  private
    # `delete_all` would leave the recipe_suggestions fixtures pointing at rows that
    # no longer exist, and SQLite enforces the foreign key.
    def clear_runs
      RecipeSuggestion.delete_all
      SuggestionRun.delete_all
    end
end
