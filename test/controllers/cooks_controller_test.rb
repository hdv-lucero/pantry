require "test_helper"

# §4.3 — the "I made this" modal and what confirming it sets off.
class CooksControllerTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier

  setup do
    @suggestion = recipe_suggestions(:beef_night_gyudon)   # uses ground beef, rice
    @beef = pantry_items(:ground_beef)
    @rice = pantry_items(:rice)

    sign_in_as users(:one)
  end

  test "requires authentication" do
    sign_out

    get new_recipe_suggestion_cook_path(@suggestion)

    assert_redirected_to new_session_path
  end

  # ── the modal ───────────────────────────────────────────────────────────────

  test "the modal is one frame carrying a dialog with a line per in-stock item used" do
    get new_recipe_suggestion_cook_path(@suggestion), headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_select "turbo-frame#modal", count: 1 do
      assert_select "dialog" do
        assert_select "input[name=?][value=?]", "deductions[#{@beef.id}][amount]", "1"
        assert_select "input[name=?][value=?]", "deductions[#{@rice.id}][amount]", "2"
        assert_select "input[type=checkbox][checked=checked]", count: 2
      end
    end
  end

  test "the modal names what the suggestion used and the pantry no longer has" do
    get new_recipe_suggestion_cook_path(recipe_suggestions(:history_gyudon)),
        headers: { "Turbo-Frame" => "modal" }

    assert_select "dialog", /Not in your pantry any more: bok choi/
  end

  # ── confirming ──────────────────────────────────────────────────────────────

  test "confirming deducts, records the cooking, and streams the modal on to the thumbs" do
    post recipe_suggestion_cook_path(@suggestion), as: :turbo_stream, params: {
      deductions: { @beef.id.to_s => { apply: "1", amount: "1" },
                    @rice.id.to_s => { apply: "1", amount: "0.5" } }
    }

    assert_response :success
    assert_equal 0, @beef.reload.quantity
    assert_equal BigDecimal("1.5"), @rice.reload.quantity
    assert_predicate @suggestion.reload, :cooked?

    assert_select "turbo-stream[action=update][target=modal]", /Would you make it again/
    assert_select "turbo-stream[action=replace][target=?]", dom_id(@beef)
    assert_select "turbo-stream[action=replace][target=?]", dom_id(@rice)
    assert_select "turbo-stream[action=replace][target=suggestion_runs_list]"
  end

  test "an unchecked line is streamed back untouched because it was never deducted" do
    post recipe_suggestion_cook_path(@suggestion), as: :turbo_stream, params: {
      deductions: { @beef.id.to_s => { amount: "1" }, @rice.id.to_s => { apply: "1", amount: "2" } }
    }

    assert_equal 1, @beef.reload.quantity
    assert_select "turbo-stream[action=replace][target=?]", dom_id(@beef), count: 0
    assert_select "turbo-stream[action=replace][target=?]", dom_id(@rice)
  end

  # §4.3's cascade, from the response's point of view: the run archived itself in the
  # pantry's commit callbacks, so the list this renders no longer contains it.
  test "a cook that empties the pantry drops the newly stale run out of the streamed list" do
    post recipe_suggestion_cook_path(@suggestion), as: :turbo_stream

    assert_predicate suggestion_runs(:beef_night).reload, :archived?

    assert_select "turbo-stream[action=replace][target=suggestion_runs_list]" do
      assert_select "div##{dom_id(suggestion_runs(:beef_night))}", false
      assert_select "div##{dom_id(suggestion_runs(:dessert))}"
    end
  end

  # The other side of the cascade: a cook that empties nothing leaves every run's
  # coverage where it was, so the card stays on screen — marked, and no longer
  # offering to be cooked again.
  test "a partial cook keeps its run and marks the card" do
    post recipe_suggestion_cook_path(@suggestion), as: :turbo_stream, params: {
      deductions: { @beef.id.to_s => { apply: "1", amount: "0.5" },
                    @rice.id.to_s => { apply: "1", amount: "0.5" } }
    }

    assert_not_predicate suggestion_runs(:beef_night).reload, :archived?

    assert_select "turbo-stream[action=replace][target=suggestion_runs_list]" do
      assert_select "div##{dom_id(@suggestion)}", /You made this/
      assert_select "div##{dom_id(@suggestion)} a", text: "I made this", count: 0
    end
  end
end
