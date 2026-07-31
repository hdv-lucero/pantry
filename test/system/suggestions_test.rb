require "application_system_test_case"

# §8 — "system tests with Capybara covering the Hotwire flows — ... and crucially the
# suggestion flow with the LLM call stubbed". This is also Task 6's acceptance path:
# ask for suggestions, watch the card land, cook one, watch quantities drop and a
# stale run archive itself.
#
# The job is drained with `perform_enqueued_jobs` *after* the card is on screen rather
# than inline at enqueue time, because inline would have the run finish before the
# controller rendered anything — and then the lifecycle this is here to watch would
# happen off camera. Draining it here puts the running → completed broadcasts on the
# cable while a subscribed browser is looking, which is what production does.
class SuggestionsTest < ApplicationSystemTestCase
  include ActionView::RecordIdentifier
  # System tests do not pick this up the way integration tests do, and draining the
  # queue by hand is the whole point of the timing above.
  include ActiveJob::TestHelper

  setup do
    # The fixtures ship four active runs so the coverage maths has cases to measure.
    # This file is about one run at a time, so the panel starts empty.
    SuggestionRun.destroy_all

    sign_in_as users(:one)
  end

  test "asking for suggestions runs the card through its lifecycle and lands the recipes" do
    stub_anthropic(:web_search_success)

    within "#suggestions" do
      assert_text "No suggestions yet"

      fill_in "Anything to work around?", with: "something quick"
      click_button "Suggest recipes"

      assert_text "Queued…"
      assert_text "You asked for “something quick”"
      assert_field "Anything to work around?", with: ""
    end

    with_anthropic_credentials { perform_enqueued_jobs }

    within "#suggestions" do
      # Five cards, ranked by fewest missing items — the top one is the tiebreak the
      # parser settles on title (§5's ranking), and it is what the fixture ranks first.
      assert_text "5 recipes for what you have"
      assert_selector "#suggestion_runs_list li:first-child h4", text: "Beef and Rice Skillet"

      # §4.3's badge: the fixture response includes Shakshuka, which the recipes
      # fixture already carries a thumbs-up for.
      assert_text "★ includes one of your favorites"
    end

    within "##{dom_id(RecipeSuggestion.find_by!(title: 'Greek Yogurt Pancakes'))}" do
      assert_text "Thick, tangy pancakes"                       # our summary, not the source's
      assert_text "greek yogurt"                                # what it uses
      assert_text "all-purpose flour"                           # what you'd need
      assert_text "butter · you could try: olive oil"           # §5's substitution hint
      assert_link "Greek Yogurt Pancakes", href: "https://www.loveandlemons.com/greek-yogurt-pancakes"
    end
  end

  test "cooking a suggestion drops the quantities, archives the stale run and takes the thumbs" do
    stub_anthropic(:web_search_success)

    click_button "Suggest recipes"
    assert_text "Queued…"
    with_anthropic_credentials { perform_enqueued_jobs }

    run = SuggestionRun.order(:id).last
    skillet = RecipeSuggestion.find_by!(title: "Beef and Rice Skillet")   # ground beef, rice, olive oil
    assert_text "5 recipes for what you have"

    within("##{dom_id(skillet)}") { click_link "I made this" }

    within "dialog" do
      # §4.3 — the lines arrive pre-filled with a proposal, one per in-stock item the
      # recipe uses. Taken as they stand here; adjusting and unchecking them is the
      # last test in this file.
      assert_field "Amount of ground beef used", with: "1"
      assert_field "Amount of olive oil used", with: "750"
      assert_field "Amount of rice used", with: "2"

      click_button "I made this"
    end

    # One click, and the rest of the screen follows without a reload.
    within("#freezer_items") { assert_field "Quantity of ground beef", with: "0" }
    within "#pantry_items" do
      assert_field "Quantity of rice", with: "0"
      assert_field "Quantity of olive oil", with: "0"
    end

    # Half of what the run leans on is gone, which is more than the third §5 tolerates,
    # so it archives itself out of the active view — and its card goes with it.
    assert_predicate run.reload, :archived?
    assert_no_selector "##{dom_id(run)}"

    # §4.3's optional thumbs, on the same dialog, after the deduction is applied.
    within "dialog" do
      assert_text "Would you make it again?"
      click_button "👍 Yes"
    end

    assert_no_selector "dialog"
    assert_predicate skillet.recipe.reload, :favorite?
  end

  # The archiving broadcast on its own: nothing here re-renders the suggestions panel,
  # so the card can only leave the screen because the pantry write pushed it off.
  test "a run archives itself off the screen when an item it needs leaves the pantry" do
    beef = pantry_items(:ground_beef)
    run = completed_run(uses: [ beef.name, "rice" ])

    visit root_path
    assert_selector "##{dom_id(run)}"

    within("##{dom_id(beef)}") { click_button "Remove ground beef" }

    assert_no_selector "##{dom_id(run)}"
    within("#suggestions") { assert_text "No suggestions yet" }
    assert_predicate run.reload, :archived?
  end

  test "a failed run says so in plain language and its retry starts a fresh one" do
    click_button "Suggest recipes"
    assert_text "Queued…"

    # The configured-credentials path is covered above; this is §4.2 step 4's failed
    # card, driven by the one failure that needs no network at all.
    without_anthropic_credentials { perform_enqueued_jobs }

    # Reloaded rather than watched. This failure comes back microseconds after the
    # run flips to `running`, and the in-process async adapter the test environment
    # uses can hand two broadcasts that close together to its thread pool out of
    # order — production's solid_cable poller replays rows in insert order and
    # cannot. The test above already proves a live card follows the transitions;
    # this one is about the failed card and its retry.
    page.refresh

    failed = SuggestionRun.order(:id).last
    assert_predicate failed, :failed?
    assert_text "Recipe suggestions aren't configured yet."

    click_button "Try again"

    assert_text "Queued…"
    assert_no_selector "##{dom_id(failed)}"
    assert_predicate failed.reload, :archived?
  end

  test "the amounts are the user's to adjust, and a thumbs down hides one card" do
    run = completed_run(uses: [ "rice", "milk" ])
    other = run.recipe_suggestions.create!(recipe: recipes(:overnight_oats), title: "Overnight Oats",
                                           uses_items: [ "rice" ], position: 1)
    cooked = run.recipe_suggestions.first

    visit root_path
    within("##{dom_id(cooked)}") { click_link "I made this" }

    within "dialog" do
      # §4.3 — "the user adjusts the amounts (the recipe may not have used all 3
      # stalks) or unchecks items entirely".
      uncheck "Use rice"
      fill_in "Amount of milk used", with: "0.25"
      click_button "I made this"
    end

    within("dialog") { click_button "👎 No" }

    # §4.3 — "the card is archived out of the active view (its siblings in the run
    # stay live)", and the run itself is untouched.
    assert_no_selector "##{dom_id(cooked)}"
    assert_selector "##{dom_id(other)}"
    assert_selector "##{dom_id(run)}"

    assert_equal 2, pantry_items(:rice).reload.quantity
    assert_equal BigDecimal("0.75"), pantry_items(:milk).reload.quantity
    assert_predicate cooked.reload, :cooked?
  end

  private
    # A completed run without going through the API — for the tests that are about
    # what happens *after* one, and have no reason to pay for the round trip.
    def completed_run(uses:)
      SuggestionRun.create!.tap do |run|
        run.complete!([ { title: "Test Kitchen Bake", source_url: "https://example.org/bake",
                          source_name: "Test Kitchen", summary: "A plain test recipe.",
                          uses_items: uses, missing_items: [ "salt" ], substitutions: [], position: 0 } ])
      end
    end
end
