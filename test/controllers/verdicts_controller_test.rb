require "test_helper"

# §4.3's thumbs — "the single canonical verdict for that recipe", and the two
# things a tap changes on screen: the ★ badge and whether the card is there at all.
class VerdictsControllerTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier

  setup do
    @gyudon = recipes(:gyudon)   # no verdict yet, and on two runs
    sign_in_as users(:one)
  end

  test "requires authentication" do
    sign_out

    patch recipe_verdict_path(@gyudon), params: { make_again: true }

    assert_redirected_to new_session_path
  end

  test "a thumbs up makes it a favorite and badges every run that includes it" do
    patch recipe_verdict_path(@gyudon), params: { make_again: true }, as: :turbo_stream

    assert_response :success
    assert_predicate @gyudon.reload, :favorite?

    assert_select "turbo-stream[action=replace][target=suggestion_runs_list]" do
      assert_select "div##{dom_id(suggestion_runs(:beef_night))}", /includes one of your favorites/
    end
  end

  # §4.3 — "the card is archived out of the active view (its siblings in the run stay
  # live)". Both halves matter: one card leaves, the run does not.
  test "a thumbs down takes the card out of the active view and leaves its siblings" do
    patch recipe_verdict_path(@gyudon), params: { make_again: false }, as: :turbo_stream

    assert_predicate @gyudon.reload, :blocked?

    assert_select "turbo-stream[action=replace][target=suggestion_runs_list]" do
      assert_select "div##{dom_id(suggestion_runs(:beef_night))}"
      assert_select "div##{dom_id(recipe_suggestions(:beef_night_gyudon))}", false
      assert_select "div##{dom_id(recipe_suggestions(:beef_night_shakshuka))}"
    end
  end

  test "a blocked card is gone from the inventory screen too, not just from the response" do
    patch recipe_verdict_path(@gyudon), params: { make_again: false }, as: :turbo_stream

    get root_path

    assert_select "div##{dom_id(recipe_suggestions(:beef_night_gyudon))}", false
    assert_select "div##{dom_id(recipe_suggestions(:beef_night_shakshuka))}"
  end

  test "answering closes the modal" do
    patch recipe_verdict_path(@gyudon), params: { make_again: true }, as: :turbo_stream

    assert_select "turbo-stream[action=update][target=modal]"
  end

  # §3 — "there's no duplicate opinion to create, the tap simply updates the one
  # verdict in place, and latest wins."
  test "re-asking a favorite demotes it in place" do
    favorite = recipes(:shakshuka)

    assert_no_difference -> { Recipe.count } do
      patch recipe_verdict_path(favorite), params: { make_again: false }, as: :turbo_stream
    end

    assert_predicate favorite.reload, :blocked?
  end
end
