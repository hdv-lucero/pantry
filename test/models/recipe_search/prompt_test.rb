require "test_helper"

# The prompt is the feature's contract with the model, so the rules §5 calls
# non-negotiable are asserted rather than left to careful reading. These are
# deliberately about substance, not wording — they check that a rule is stated, not
# how the sentence goes, so the prompt can be tuned without a test rewrite.
class RecipeSearch::PromptTest < ActiveSupport::TestCase
  setup do
    @snapshot = InventorySnapshot.current
    @prompt = RecipeSearch::Prompt.new(snapshot: @snapshot, favorites: [], blocked: [])
  end

  # ── §1 and §5: existing recipes only ────────────────────────────────────────

  test "the system prompt forbids inventing recipes and requires searching" do
    assert_match(/web_search/, @prompt.system)
    assert_match(/already-published/i, @prompt.system)
    assert_match(/never.*assemble a plausible-looking URL/mi, @prompt.system)
  end

  test "the system prompt asks for three to five recipes" do
    assert_match(/3–5|3-5/, @prompt.system)
  end

  test "the system prompt states the exact-name echo rule for both fields" do
    assert_match(/character for character/i, @prompt.system)
    assert_match(/uses_items/, @prompt.system)
    assert_match(/use_instead/, @prompt.system)
  end

  test "the system prompt constrains substitutions to the pantry" do
    assert_match(/missing_items/, @prompt.system)
    assert_match(/pantry actually holds/i, @prompt.system)
  end

  test "the system prompt states the content boundary" do
    # §5 — "never the source recipe's instructions or ingredient list."
    assert_match(/one-to-two-sentence|one or two sentence/i, @prompt.system)
    assert_match(/Do not reproduce the source's instructions/i, @prompt.system)
  end

  test "the system prompt specifies the JSON schema and every field it names" do
    %w[ title source_url source_name summary uses_items missing_items substitutions ].each do |field|
      assert_match(/#{field}/, @prompt.system, "the schema should name #{field}")
    end
  end

  test "the system prompt prefers a real recipe with gaps over a contrived perfect match" do
    assert_match(/Exact pantry coverage is explicitly not required/i, @prompt.system)
  end

  test "the system prompt is frozen across requests so it stays cacheable" do
    other = RecipeSearch::Prompt.new(snapshot: InventorySnapshot.new([]), notes: "different", favorites: [], blocked: [])

    assert_equal @prompt.system, other.system
  end

  # ── the user message: everything that varies ────────────────────────────────

  test "the user message lists every pantry item by its exact name" do
    message = @prompt.user_message

    @snapshot.names.each { |name| assert_match(/#{Regexp.escape(name)}/, message) }
  end

  test "quantities and units are rendered without trailing zeroes" do
    assert_match(/milk \(1 gallon\)/, @prompt.user_message)
    assert_match(/olive oil \(750 ml\)/, @prompt.user_message)
  end

  test "expiry is expressed in days so the model need not guess at today" do
    # §5 prefers "items nearing expiry"; milk expires in 2 days in the fixtures.
    assert_match(/milk .* expires in 2 days/, @prompt.user_message)
  end

  test "an already-expired item says so" do
    # greek yogurt is two days past in the fixtures.
    assert_match(/greek yogurt .* expired 2 days ago/, @prompt.user_message)
  end

  test "an item expiring today says today" do
    pantry_items(:rice).update!(expires_on: Date.current)

    assert_match(/rice .* expires today/, RecipeSearch::Prompt.new(snapshot: InventorySnapshot.current).user_message)
  end

  test "an item with no expiry gets no expiry note" do
    assert_match(/^- rice \(2 kg\)$/, @prompt.user_message)
  end

  test "notes are included when given and absent when not" do
    assert_no_match(/The cook also said/, @prompt.user_message)

    with_notes = RecipeSearch::Prompt.new(snapshot: @snapshot, notes: "30 minutes max", favorites: [], blocked: [])
    assert_match(/The cook also said: 30 minutes max/, with_notes.user_message)
  end

  test "blank notes are treated as no notes" do
    assert_no_match(/The cook also said/, RecipeSearch::Prompt.new(snapshot: @snapshot, notes: "  ").user_message)
  end

  # ── §5's preference lists ───────────────────────────────────────────────────

  test "favorites and the blocklist default to the two one-line queries on recipes" do
    prompt = RecipeSearch::Prompt.new(snapshot: @snapshot)

    assert_equal [ recipes(:shakshuka) ], prompt.favorites.to_a
    assert_equal [ recipes(:tuna_casserole) ], prompt.blocked.to_a
  end

  test "each preference list is sent as title and source url" do
    message = RecipeSearch::Prompt.new(snapshot: @snapshot).user_message

    assert_match(/make again.*#{Regexp.escape(recipes(:shakshuka).canonical_title)}.*#{Regexp.escape(recipes(:shakshuka).source_url)}/m, message)
    assert_match(/Do not suggest.*#{Regexp.escape(recipes(:tuna_casserole).canonical_title)}.*#{Regexp.escape(recipes(:tuna_casserole).source_url)}/m, message)
  end

  test "an unrated recipe appears in neither list" do
    message = RecipeSearch::Prompt.new(snapshot: @snapshot).user_message

    assert_no_match(/#{Regexp.escape(recipes(:overnight_oats).source_url)}/, message)
  end

  test "empty preference lists produce no sections at all" do
    message = @prompt.user_message

    assert_no_match(/make again/i, message)
    assert_no_match(/Do not suggest/i, message)
  end

  # ── the corrective retry ────────────────────────────────────────────────────

  test "the correction quotes the error and forbids a second search" do
    correction = @prompt.correction_message("the response was not valid JSON").squish

    assert_match(/could not be parsed: the response was not valid JSON/, correction)
    assert_match(/do not search again/, correction)
    assert_match(/verbatim/, correction)
  end
end
