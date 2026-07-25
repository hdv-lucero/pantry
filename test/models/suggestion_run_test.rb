require "test_helper"

class SuggestionRunTest < ActiveSupport::TestCase
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
end
