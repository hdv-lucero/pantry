require "test_helper"

# §5 — "retry once with an error-corrective message if malformed, then fail the run
# cleanly." Exactly once is the contract: zero would waste a recoverable response,
# and unbounded retries against a model stuck in a loop is how a cost-controlled
# feature stops being one.
class RecipeSearchTest < ActiveSupport::TestCase
  setup do
    @snapshot = InventorySnapshot.current
  end

  test "a good response is parsed on the first call" do
    stub_anthropic(:web_search_success)

    result = search.call

    assert_equal 5, result.suggestions.size
    assert_equal 1, anthropic_requests.size
  end

  test "the raw reply text comes back for the cache to store" do
    stub_anthropic(:web_search_success)

    assert_equal anthropic_fixture_text(:web_search_success), search.call.text
  end

  test "a malformed response is retried once and succeeds" do
    stub_anthropic_sequence(:web_search_malformed, :web_search_success)

    result = search.call

    assert_equal 5, result.suggestions.size
    assert_equal 2, anthropic_requests.size
  end

  test "the correction replays the model's own turn and says what was wrong" do
    stub_anthropic_sequence(:web_search_malformed, :web_search_success)
    search.call

    messages = anthropic_requests.last["messages"]

    assert_equal %w[ user assistant user ], messages.map { |m| m["role"] }

    # Squished because the prompt is a wrapped heredoc; the assertion is about the
    # words, not where the lines break.
    correction = messages.last["content"].squish

    assert_match(/could not be parsed/, correction)
    assert_match(/not valid JSON/, correction)
    # The retry should not pay for a second round of searching.
    assert_match(/do not search again/, correction)
  end

  test "the retried text is what gets cached, not the malformed first reply" do
    stub_anthropic_sequence(:web_search_malformed, :web_search_success)

    assert_equal anthropic_fixture_text(:web_search_success), search.call.text
  end

  test "a second malformed response gives up rather than retrying again" do
    stub_anthropic(:web_search_malformed)

    assert_raises(RecipeSearch::Parser::Malformed) { search.call }
    assert_equal 2, anthropic_requests.size
  end

  test "a transport failure is not retried — the user's retry button is the retry" do
    # §5: "New LLM calls happen only on explicit user action." The corrective retry is
    # for a response that arrived and was unusable, not for one that never arrived.
    stub_anthropic_error(500)

    assert_raises(RecipeSearch::Client::Error) { search.call }
    assert_equal 1, anthropic_requests.size
  end

  test "notes reach the prompt" do
    stub_anthropic(:web_search_success)

    search(notes: "something quick, no dairy").call

    assert_match(/something quick, no dairy/, anthropic_requests.sole["messages"].sole["content"])
  end

  private
    def search(notes: nil)
      RecipeSearch.new(snapshot: @snapshot, notes: notes, client: stubbed_search_client)
    end
end
