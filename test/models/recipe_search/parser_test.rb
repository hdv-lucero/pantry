require "test_helper"

# §8 — "The job's parsing/retry logic gets direct unit tests since that's where the
# fiddly failure handling lives." No network, no database writes beyond the fixtures.
class RecipeSearch::ParserTest < ActiveSupport::TestCase
  setup do
    @snapshot = InventorySnapshot.current
    @parser = RecipeSearch::Parser.new(snapshot: @snapshot)
  end

  # The test pantry, for readability in the assertions below.
  PANTRY = %w[ milk greek\ yogurt egg ground\ beef rice olive\ oil ].freeze

  test "the fixture pantry is the vocabulary these tests assume" do
    assert_equal PANTRY.sort, @snapshot.names.to_a.sort
  end

  # ── the happy path, against the captured-shape success fixture ───────────────

  test "the success fixture yields all five recipes" do
    results = @parser.call(anthropic_fixture_text(:web_search_success))

    assert_equal 5, results.size
    assert_equal 5, results.map { |r| r[:source_url] }.uniq.size
  end

  test "results are ranked by fewest missing items, then most used, then title" do
    results = @parser.call(anthropic_fixture_text(:web_search_success))

    assert_equal [
      "Beef and Rice Skillet",      # 2 missing, 3 used — beats the pudding on title
      "Stovetop Rice Pudding",      # 2 missing, 3 used
      "Greek Yogurt Pancakes",      # 3 missing, 3 used — beats shakshuka on items used
      "Shakshuka",                  # 3 missing, 2 used
      "Gyudon (Japanese Beef Bowl)" # 4 missing
    ], results.map { |r| r[:title] }
  end

  test "position is assigned in ranked order from zero" do
    results = @parser.call(anthropic_fixture_text(:web_search_success))

    assert_equal (0..4).to_a, results.map { |r| r[:position] }
  end

  test "a valid substitution survives with both halves intact" do
    pancakes = find_result(:web_search_success, "Greek Yogurt Pancakes")

    assert_equal [ { "missing" => "butter", "use_instead" => "olive oil" } ], pancakes[:substitutions]
  end

  test "source_name is taken from the response" do
    assert_equal "Just One Cookbook", find_result(:web_search_success, "Gyudon (Japanese Beef Bowl)")[:source_name]
  end

  # ── §5's filters, against the dirty fixture ─────────────────────────────────

  test "the dirty fixture leaves only the two recipes that break no rules" do
    results = @parser.call(anthropic_fixture_text(:web_search_dirty))

    assert_equal [ "Beef and Rice Skillet", "Stovetop Rice Pudding" ], results.map { |r| r[:title] }
  end

  test "a fenced response is parsed" do
    # The dirty fixture is wrapped in ```json …  ```; parsing at all proves the strip.
    assert_predicate @parser.call(anthropic_fixture_text(:web_search_dirty)), :any?
  end

  test "a thumbs-downed recipe is dropped even though the model returned it" do
    assert_predicate recipes(:tuna_casserole), :blocked?

    results = @parser.call(anthropic_fixture_text(:web_search_dirty))

    assert_not_includes results.map { |r| r[:source_url] }, recipes(:tuna_casserole).source_url
  end

  test "an item name that is not in the pantry is dropped from uses_items" do
    skillet = find_result(:web_search_dirty, "Beef and Rice Skillet")

    # The fixture asked for ["ground beef", "bok choi", "rice"].
    assert_equal [ "ground beef", "rice" ], skillet[:uses_items]
  end

  test "a recipe whose uses_items are all invented is dropped entirely" do
    results = @parser.call(anthropic_fixture_text(:web_search_dirty))

    assert_not_includes results.map { |r| r[:title] }, "Bok Choi Hotpot"
  end

  test "two URLs that normalize to the same recipe collapse to one result" do
    results = @parser.call(anthropic_fixture_text(:web_search_dirty))

    assert_equal 1, results.count { |r| r[:source_url] == "https://www.budgetbytes.com/beef-and-rice-skillet" }
    assert_not_includes results.map { |r| r[:title] }, "Beef & Rice Skillet (again)"
  end

  test "a URL at a non-public host is dropped" do
    results = @parser.call(anthropic_fixture_text(:web_search_dirty))

    assert_not_includes results.map { |r| r[:title] }, "Grandma's Secret Rice Bowl"
  end

  test "a recipe missing a required field is dropped" do
    results = @parser.call(anthropic_fixture_text(:web_search_dirty))

    assert_not_includes results.map { |r| r[:title] }, "Mystery Casserole"
  end

  test "substitutions are dropped unless use_instead is in the pantry and missing was declared" do
    pudding = find_result(:web_search_dirty, "Stovetop Rice Pudding")

    # The fixture offered three: butter→olive oil (good), sugar→honey (honey is not in
    # the pantry), vanilla extract→milk (vanilla was never in missing_items).
    assert_equal [ { "missing" => "butter", "use_instead" => "olive oil" } ], pudding[:substitutions]
  end

  test "tracking params and fragments are stripped from the stored url" do
    skillet = find_result(:web_search_dirty, "Beef and Rice Skillet")

    assert_equal "https://www.budgetbytes.com/beef-and-rice-skillet", skillet[:source_url]
  end

  # ── malformed input, which the caller retries once ──────────────────────────

  test "the malformed fixture raises Malformed" do
    error = assert_raises(RecipeSearch::Parser::Malformed) do
      @parser.call(anthropic_fixture_text(:web_search_malformed))
    end

    assert_match(/not valid JSON/, error.message)
  end

  test "an empty response raises Malformed" do
    assert_raises(RecipeSearch::Parser::Malformed) { @parser.call("") }
    assert_raises(RecipeSearch::Parser::Malformed) { @parser.call("   ") }
  end

  test "valid JSON of the wrong shape raises Malformed" do
    error = assert_raises(RecipeSearch::Parser::Malformed) { @parser.call('["a", "b"]') }
    assert_match(/expected a JSON object/, error.message)

    assert_raises(RecipeSearch::Parser::Malformed) { @parser.call('{"results": []}') }
  end

  test "a response where every recipe is filtered out raises Malformed rather than returning nothing" do
    payload = { recipes: [ {
      title: "Bok Choi Hotpot", source_url: "https://example.com/hotpot", source_name: "Nowhere",
      summary: "Uses nothing you own.", uses_items: [ "bok choi" ], missing_items: [], substitutions: []
    } ] }.to_json

    error = assert_raises(RecipeSearch::Parser::Malformed) { @parser.call(payload) }
    assert_match(/none of the 1 recipe returned were usable/, error.message)
  end

  test "a genuinely empty recipes array is an empty result, not a malformed one" do
    # "If you cannot find 3 suitable recipes, return the ones you did find" — nothing
    # found is a real answer, and retrying would not change it.
    assert_equal [], @parser.call('{"recipes": []}')
  end

  test "an object wrapped in prose is still parsed" do
    text = "Here's what I found!\n\n#{{ recipes: [ valid_recipe ] }.to_json}\n\nHope that helps."

    assert_equal 1, @parser.call(text).size
  end

  # ── URL sanity, rule by rule ────────────────────────────────────────────────

  test "urls that fail the sanity check are rejected" do
    [
      [ "an IP host", "https://192.168.1.10/recipes/thing" ],
      [ "a dotless host", "https://intranet/recipes/thing" ],
      [ "a .local host", "https://kitchen.local/recipes/thing" ],
      [ "a .test host", "https://recipes.test/thing" ],
      [ "a bare domain", "https://www.seriouseats.com" ],
      [ "a homepage with a query", "https://www.seriouseats.com/?recipe=1234" ],
      [ "a non-http scheme", "ftp://www.seriouseats.com/recipe" ],
      [ "javascript", "javascript:alert(1)" ],
      [ "not a url at all", "just some text" ],
      [ "an empty string", "" ]
    ].each do |label, url|
      payload = { recipes: [ valid_recipe(source_url: url) ] }.to_json

      assert_raises(RecipeSearch::Parser::Malformed, "expected #{label} (#{url}) to be rejected") do
        @parser.call(payload)
      end
    end
  end

  test "a real recipe url on a real host survives" do
    payload = { recipes: [ valid_recipe(source_url: "https://www.seriouseats.com/recipes/thing") ] }.to_json

    assert_equal 1, @parser.call(payload).size
  end

  # ── shape defences ──────────────────────────────────────────────────────────

  test "summary is capped so a source's method cannot be pasted onto a card" do
    payload = { recipes: [ valid_recipe(summary: "Step one. " * 200) ] }.to_json

    summary = @parser.call(payload).sole[:summary]

    assert_operator summary.length, :<=, RecipeSearch::Parser::SUMMARY_LIMIT
  end

  test "more than five usable recipes are trimmed to the best five" do
    recipes = 8.times.map do |i|
      valid_recipe(title: "Recipe #{i}", source_url: "https://www.seriouseats.com/recipe-#{i}",
                   missing_items: Array.new(i) { |n| "ingredient #{n}" })
    end

    results = @parser.call({ recipes: recipes }.to_json)

    assert_equal RecipeSearch::Parser::MAX_RESULTS, results.size
    assert_equal [ "Recipe 0", "Recipe 1", "Recipe 2", "Recipe 3", "Recipe 4" ], results.map { |r| r[:title] }
  end

  test "non-array and non-string list entries are ignored rather than raising" do
    payload = { recipes: [ valid_recipe(
      uses_items: [ "rice", nil, 42, { "name" => "milk" }, [ "egg" ] ],
      missing_items: "not an array",
      substitutions: "not an array"
    ) ] }.to_json

    result = @parser.call(payload).sole

    assert_equal [ "rice" ], result[:uses_items]
    assert_equal [], result[:missing_items]
    assert_equal [], result[:substitutions]
  end

  test "duplicate names within uses_items collapse" do
    payload = { recipes: [ valid_recipe(uses_items: [ "rice", "rice", "milk" ]) ] }.to_json

    assert_equal [ "rice", "milk" ], @parser.call(payload).sole[:uses_items]
  end

  test "source_name falls back to the host when the model omits it" do
    payload = { recipes: [ valid_recipe(source_name: nil, source_url: "https://www.seriouseats.com/thing") ] }.to_json

    assert_equal "seriouseats.com", @parser.call(payload).sole[:source_name]
  end

  test "a non-hash entry in the recipes array is skipped" do
    payload = { recipes: [ "nonsense", 42, valid_recipe ] }.to_json

    assert_equal 1, @parser.call(payload).size
  end

  test "an explicit blocked_urls list overrides the database" do
    parser = RecipeSearch::Parser.new(snapshot: @snapshot, blocked_urls: [ "https://www.seriouseats.com/thing" ])
    payload = { recipes: [ valid_recipe(source_url: "https://www.seriouseats.com/thing") ] }.to_json

    assert_raises(RecipeSearch::Parser::Malformed) { parser.call(payload) }
  end

  private
    def find_result(fixture, title)
      @parser.call(anthropic_fixture_text(fixture)).find { |r| r[:title] == title } ||
        flunk("no result titled #{title.inspect}")
    end

    def valid_recipe(**overrides)
      {
        title: "A Real Recipe",
        source_url: "https://www.seriouseats.com/a-real-recipe",
        source_name: "Serious Eats",
        summary: "Something you can actually make.",
        uses_items: [ "rice" ],
        missing_items: [],
        substitutions: []
      }.merge(overrides)
    end
end
