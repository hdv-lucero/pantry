require "test_helper"

class RecipeSuggestionTest < ActiveSupport::TestCase
  test "the json columns round-trip as arrays" do
    suggestion = recipe_suggestions(:beef_night_gyudon)

    assert_equal [ "ground beef", "rice" ], suggestion.uses_items
    assert_equal [ "dashi powder", "mirin", "sesame oil" ], suggestion.missing_items
    assert_equal [ { "missing" => "sesame oil", "use_instead" => "olive oil" } ], suggestion.substitutions
  end

  test "the json columns default to empty arrays" do
    suggestion = RecipeSuggestion.new

    assert_equal [], suggestion.uses_items
    assert_equal [], suggestion.missing_items
    assert_equal [], suggestion.substitutions
  end

  test "the json columns survive a write" do
    suggestion = suggestion_runs(:pending).recipe_suggestions.create!(
      recipe: recipes(:gyudon),
      title: "Gyudon",
      uses_items: [ "rice" ],
      substitutions: [ { missing: "mirin", use_instead: "milk" } ]
    )

    assert_equal [ "rice" ], suggestion.reload.uses_items
    assert_equal [ { "missing" => "mirin", "use_instead" => "milk" } ], suggestion.substitutions
  end

  test "a json column refuses a value that isn't a list, at assignment" do
    assert_raises(ActiveRecord::SerializationTypeMismatch) do
      RecipeSuggestion.new(title: "Gyudon", uses_items: "rice")
    end
  end

  # The flip side of leaving the columns nullable: `type: Array` reads NULL as an
  # empty list and writes an empty list back as NULL, so nil never surfaces.
  test "an empty list is stored as null and read back as an empty list" do
    suggestion = suggestion_runs(:pending).recipe_suggestions.create!(recipe: recipes(:gyudon), title: "Gyudon")

    assert_nil suggestion.reload.attributes_before_type_cast["uses_items"]
    assert_equal [], suggestion.uses_items
  end

  test "a suggestion needs a title, a run and a recipe" do
    assert_predicate RecipeSuggestion.new, :invalid?
    assert_predicate RecipeSuggestion.new(suggestion_run: suggestion_runs(:pending), recipe: recipes(:gyudon)),
      :invalid?
    assert_predicate RecipeSuggestion.new(suggestion_run: suggestion_runs(:pending), recipe: recipes(:gyudon),
                                          title: "Gyudon"), :valid?
  end

  test "ordered sorts by position" do
    run = suggestion_runs(:beef_night)
    run.recipe_suggestions.find_by(position: 1).update!(position: 3)

    assert_equal [ "Shakshuka", "Gyudon (Japanese Beef Bowl)" ], run.recipe_suggestions.reload.map(&:title)
  end

  # §4.3 — cooking is an event on the suggestion; the verdict is separate and
  # lives on the recipe.
  test "cooked_at records the fact of cooking in this run" do
    assert_predicate recipe_suggestions(:history_gyudon), :cooked?
    assert_not_predicate recipe_suggestions(:beef_night_gyudon), :cooked?
    assert_equal [ recipe_suggestions(:history_gyudon) ], RecipeSuggestion.cooked.to_a
  end

  test "the same recipe can carry a different title in each run" do
    assert_equal recipe_suggestions(:beef_night_gyudon).recipe, recipe_suggestions(:history_gyudon).recipe
    assert_not_equal recipe_suggestions(:beef_night_gyudon).title, recipe_suggestions(:history_gyudon).title
  end

  # §4.3 — the card the active view hides is the one whose *recipe* was thumbed down.
  test "blocked follows the recipe's verdict" do
    assert_predicate recipe_suggestions(:history_tuna_casserole), :blocked?
    assert_not_predicate recipe_suggestions(:beef_night_shakshuka), :blocked?
    assert_not_predicate recipe_suggestions(:beef_night_gyudon), :blocked?   # no verdict is not a no
  end

  # §5 — "renders as a muted hint attached to the missing item".
  test "a substitution is found by the missing item it belongs to" do
    suggestion = recipe_suggestions(:beef_night_gyudon)

    assert_equal "olive oil", suggestion.substitution_for("sesame oil")
    assert_nil suggestion.substitution_for("mirin")
    assert_nil recipe_suggestions(:beef_night_shakshuka).substitution_for("paprika")
  end
end
