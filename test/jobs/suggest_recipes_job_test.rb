require "test_helper"
require "turbo/broadcastable/test_helper"

# §4.2's lifecycle end to end, with the LLM stubbed: snapshot → running → completed
# or failed, each transition broadcast, and §5's cost controls actually biting.
class SuggestRecipesJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include Turbo::Broadcastable::TestHelper

  setup do
    @run = SuggestionRun.create!
  end

  # ── the happy path ──────────────────────────────────────────────────────────

  test "a queued run ends up completed with its cards" do
    stub_anthropic(:web_search_success)

    perform

    assert_predicate @run.reload, :completed?
    assert_equal 5, @run.recipe_suggestions.count
    assert_nil @run.error_message
  end

  test "the inventory is snapshotted onto the run" do
    stub_anthropic(:web_search_success)

    perform

    assert_equal InventorySnapshot.current.entries, @run.reload.inventory_snapshot
  end

  test "cards are stored in ranked order with their overlap data" do
    stub_anthropic(:web_search_success)

    perform

    first = @run.reload.recipe_suggestions.first

    assert_equal "Beef and Rice Skillet", first.title
    assert_equal 0, first.position
    assert_equal [ "ground beef", "rice", "olive oil" ], first.uses_items
    assert_equal [ "bell pepper", "taco seasoning" ], first.missing_items
  end

  test "a substitution survives onto the card" do
    stub_anthropic(:web_search_success)

    perform

    pancakes = @run.reload.recipe_suggestions.find_by(title: "Greek Yogurt Pancakes")

    assert_equal [ { "missing" => "butter", "use_instead" => "olive oil" } ], pancakes.substitutions
  end

  test "a recipe already known keeps its identity and its verdict" do
    stub_anthropic(:web_search_success)

    assert_no_difference -> { Recipe.where(source_url: recipes(:shakshuka).source_url).count } do
      perform
    end

    suggestion = @run.reload.recipe_suggestions.find_by(title: "Shakshuka")

    assert_equal recipes(:shakshuka), suggestion.recipe
    assert_predicate suggestion.recipe, :favorite?, "the existing thumbs-up must survive the upsert"
  end

  test "a recipe seen for the first time is created with its source" do
    stub_anthropic(:web_search_success)

    assert_difference -> { Recipe.count }, 2 do
      perform
    end

    recipe = Recipe.find_by(source_url: "https://www.budgetbytes.com/beef-and-rice-skillet")

    assert_equal "Budget Bytes", recipe.source_name
    assert_equal "Beef and Rice Skillet", recipe.canonical_title
    assert_nil recipe.make_again, "a brand new recipe has no verdict"
  end

  # ── §4.2's broadcasts ───────────────────────────────────────────────────────

  test "every status transition broadcasts" do
    stub_anthropic(:web_search_success)

    # queued → running → completed is two transitions, so two broadcasts.
    assert_turbo_stream_broadcasts SuggestionRun::BROADCAST_STREAM, count: 2 do
      perform
    end
  end

  test "a failure broadcasts too" do
    stub_anthropic_error(500)

    assert_turbo_stream_broadcasts SuggestionRun::BROADCAST_STREAM, count: 2 do
      perform
    end
  end

  test "the broadcast renders the card in its new state" do
    stub_anthropic(:web_search_success)

    broadcasts = capture_turbo_stream_broadcasts SuggestionRun::BROADCAST_STREAM do
      perform
    end

    assert_equal "replace", broadcasts.last["action"]
    assert_equal ActionView::RecordIdentifier.dom_id(@run), broadcasts.last["target"]
    assert_match(/Beef and Rice Skillet/, broadcasts.last.to_html)
  end

  # ── §4.2 step 4: failing cleanly ────────────────────────────────────────────

  test "a transport failure fails the run with a message a cook can read" do
    stub_anthropic_error(500)

    perform

    assert_predicate @run.reload, :failed?
    assert_equal "Couldn't reach the recipe search. Try again?", @run.error_message
  end

  test "a timeout fails the run" do
    stub_anthropic_timeout

    perform

    assert_predicate @run.reload, :failed?
    assert_match(/Try again/, @run.error_message)
  end

  test "a response that stays malformed through the retry fails the run" do
    stub_anthropic(:web_search_malformed)

    perform

    assert_predicate @run.reload, :failed?
    assert_equal "The recipe search came back garbled. Try again?", @run.error_message
    assert_equal 2, anthropic_requests.size, "§5 allows exactly one corrective retry"
  end

  test "missing credentials fail the run rather than raising" do
    without_anthropic_credentials { SuggestRecipesJob.perform_now(@run) }

    assert_predicate @run.reload, :failed?
    assert_equal "Recipe suggestions aren't configured yet.", @run.error_message
    assert_not_requested :post, AnthropicTestHelper::MESSAGES_URL
  end

  test "the run never gets stuck on running" do
    stub_anthropic_error(500)

    perform

    assert_not_predicate @run.reload, :running?
  end

  test "a failed run keeps no half-written cards" do
    stub_anthropic(:web_search_malformed)

    perform

    assert_equal 0, @run.reload.recipe_suggestions.count
  end

  # ── §5's cost controls ──────────────────────────────────────────────────────

  test "an empty pantry fails without spending a call" do
    PantryItem.delete_all

    perform

    assert_predicate @run.reload, :failed?
    assert_match(/pantry is empty/, @run.error_message)
    assert_not_requested :post, AnthropicTestHelper::MESSAGES_URL
  end

  test "a run past the daily limit fails without spending a call" do
    SuggestionRun::DAILY_LIMIT.times { SuggestionRun.create! }
    run = SuggestionRun.create!

    SuggestRecipesJob.perform_now(run)

    assert_predicate run.reload, :failed?
    assert_match(/suggestion runs today/, run.error_message)
    assert_not_requested :post, AnthropicTestHelper::MESSAGES_URL
  end

  test "an identical re-request inside the hour is served from cache" do
    with_cache do
      stub_anthropic(:web_search_success)
      perform

      second = SuggestionRun.create!
      SuggestRecipesJob.perform_now(second)

      assert_predicate second.reload, :completed?
      assert_equal 5, second.recipe_suggestions.count
      assert_equal 1, anthropic_requests.size, "the second run should not have called the API"
    end
  end

  test "a changed pantry misses the cache" do
    with_cache do
      stub_anthropic(:web_search_success)
      perform

      pantry_items(:rice).update!(quantity: 99)
      SuggestRecipesJob.perform_now(SuggestionRun.create!)

      assert_equal 2, anthropic_requests.size
    end
  end

  test "a different note against the same pantry misses the cache" do
    with_cache do
      stub_anthropic(:web_search_success)
      perform

      SuggestRecipesJob.perform_now(SuggestionRun.create!(prompt_notes: "something quick"))

      assert_equal 2, anthropic_requests.size
    end
  end

  test "a recipe thumbs-downed after caching cannot come back from the cache" do
    # §5 promises a blocked recipe "cannot resurface even if the model ignores the
    # instruction". Caching the parsed rows instead of the raw reply would break that
    # promise for up to an hour, which is why the cache stores the reply.
    with_cache do
      stub_anthropic(:web_search_success)
      perform

      Recipe.find_by(source_url: "https://www.budgetbytes.com/beef-and-rice-skillet").update!(make_again: false)

      second = SuggestionRun.create!
      SuggestRecipesJob.perform_now(second)

      assert_equal 1, anthropic_requests.size, "still a cache hit"
      assert_not_includes second.reload.recipe_suggestions.map(&:title), "Beef and Rice Skillet"
      assert_equal 4, second.recipe_suggestions.count
    end
  end

  # ── job mechanics ───────────────────────────────────────────────────────────

  test "the job is idempotent against a run that already ran" do
    stub_anthropic(:web_search_success)
    perform

    assert_no_difference -> { RecipeSuggestion.count } do
      SuggestRecipesJob.perform_now(@run.reload)
    end

    assert_equal 1, anthropic_requests.size
  end

  test "a deleted run is discarded rather than raising" do
    stub_anthropic(:web_search_success)
    SuggestRecipesJob.perform_later(@run)
    @run.destroy!

    assert_nothing_raised { perform_enqueued_jobs }
  end

  test "the job does not retry itself" do
    # §5 — "New LLM calls happen only on explicit user action, never as a side effect."
    # §4.2 gives the user a retry button; ActiveJob must not race it.
    stub_anthropic_error(500)

    assert_no_enqueued_jobs do
      perform
    end
  end

  private
    def perform
      SuggestRecipesJob.perform_now(@run)
    end

    # Rails.cache is :null_store in test, which would make every cache assertion
    # vacuously pass. Swapped for the duration of the block only.
    def with_cache
      previous = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      yield
    ensure
      Rails.cache = previous
    end
end
