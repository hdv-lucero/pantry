require "test_helper"

# §4.3 — the quantity math behind "I made this", and the cascade it sets off.
class RecipeSuggestion::CookTest < ActiveSupport::TestCase
  setup do
    @suggestion = recipe_suggestions(:beef_night_gyudon)   # uses ground beef, rice
    @beef = pantry_items(:ground_beef)
    @rice = pantry_items(:rice)
  end

  # ── the lines the modal renders ─────────────────────────────────────────────

  test "a line per in-stock row the suggestion names, proposing the whole quantity" do
    cook = RecipeSuggestion::Cook.new(@suggestion)

    assert_equal [ @beef, @rice ], cook.lines.map(&:pantry_item)
    assert_equal [ @beef.quantity, @rice.quantity ], cook.lines.map(&:amount)
    assert cook.lines.all?(&:apply?)
  end

  test "a name with no in-stock row is named rather than silently dropped" do
    cook = RecipeSuggestion::Cook.new(recipe_suggestions(:history_gyudon))   # ground beef, bok choi

    assert_equal [ @beef ], cook.lines.map(&:pantry_item)
    assert_equal [ "bok choi" ], cook.unavailable_names
  end

  test "a row you have none of is not offered" do
    @rice.update!(quantity: 0)

    cook = RecipeSuggestion::Cook.new(@suggestion)

    assert_equal [ @beef ], cook.lines.map(&:pantry_item)
    assert_equal [ "rice" ], cook.unavailable_names
  end

  # ── applying ────────────────────────────────────────────────────────────────

  test "confirming deducts every checked line and records the cooking" do
    freeze_time do
      RecipeSuggestion::Cook.new(@suggestion, deductions(@beef => 1, @rice => "0.5")).apply!

      assert_equal 0, @beef.reload.quantity
      assert_equal BigDecimal("1.5"), @rice.reload.quantity
      assert_equal Time.current, @suggestion.reload.cooked_at
    end
  end

  test "an unchecked line is left alone" do
    RecipeSuggestion::Cook.new(@suggestion, {
      @beef.id.to_s => { "amount" => "1" },                        # no apply key: unchecked
      @rice.id.to_s => { "apply" => "1", "amount" => "2" }
    }).apply!

    assert_equal 1, @beef.reload.quantity
    assert_equal 0, @rice.reload.quantity
  end

  test "confirming with nothing submitted takes the proposal as it stood" do
    RecipeSuggestion::Cook.new(@suggestion).apply!

    assert_equal 0, @beef.reload.quantity
    assert_equal 0, @rice.reload.quantity
  end

  # Every submittable string has a reading, so there is no error state for a modal
  # that is reporting something the user has already done.
  test "amounts are clamped and junk deducts nothing" do
    RecipeSuggestion::Cook.new(@suggestion, deductions(@beef => "99", @rice => "not a number")).apply!

    assert_equal 0, @beef.reload.quantity
    assert_equal 2, @rice.reload.quantity
  end

  test "a negative amount cannot be used to restock" do
    RecipeSuggestion::Cook.new(@suggestion, deductions(@beef => "-5")).apply!

    assert_equal 1, @beef.reload.quantity
  end

  test "an id that is not one of the suggestion's items is ignored" do
    milk = pantry_items(:milk)

    RecipeSuggestion::Cook.new(@suggestion, deductions(milk => "1")).apply!

    assert_equal 1, milk.reload.quantity
  end

  # ── the cascade (§4.3) ──────────────────────────────────────────────────────

  test "zeroing the pantry archives the runs that drop below coverage and spares the rest" do
    RecipeSuggestion::Cook.new(@suggestion).apply!

    # beef_night leans on 4 items and has 2 left — under the threshold, so it goes.
    assert_predicate suggestion_runs(:beef_night).reload, :archived?
    # dessert is left with 2 of 3, which is exactly a third missing and not more.
    assert_not_predicate suggestion_runs(:dessert).reload, :archived?
    assert_not_predicate suggestion_runs(:breakfast).reload, :archived?
  end

  private
    def deductions(amounts)
      amounts.to_h { |item, amount| [ item.id.to_s, { "apply" => "1", "amount" => amount.to_s } ] }
    end
end
