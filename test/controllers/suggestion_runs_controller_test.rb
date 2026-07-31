require "test_helper"

# §4.2 step 1 and §5's per-day limit, which the doc puts here on purpose: this is
# the only layer that can refuse a request in a way a person reads.
class SuggestionRunsControllerTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier

  setup do
    sign_in_as users(:one)
  end

  test "requires authentication" do
    sign_out

    post suggestion_runs_path, params: { suggestion_run: { prompt_notes: "" } }

    assert_redirected_to new_session_path
  end

  # ── creating a run ──────────────────────────────────────────────────────────

  test "creating a run leaves it queued, enqueues the job and streams the pending card" do
    assert_difference -> { SuggestionRun.count }, 1 do
      assert_enqueued_with job: SuggestRecipesJob do
        post suggestion_runs_path, params: { suggestion_run: { prompt_notes: "" } }, as: :turbo_stream
      end
    end

    run = SuggestionRun.order(:id).last

    assert_predicate run, :queued?
    assert_nil run.prompt_notes

    assert_response :success
    assert_select "turbo-stream[action=prepend][target=suggestion_runs_list]" do
      assert_select "div##{dom_id(run)}", /Queued/
    end
    assert_select "turbo-stream[action=replace][target=new_suggestion_run]"
  end

  test "the note rides along on the run" do
    post suggestion_runs_path, params: { suggestion_run: { prompt_notes: "30 minutes max, no dairy" } },
         as: :turbo_stream

    assert_equal "30 minutes max, no dairy", SuggestionRun.order(:id).last.prompt_notes
  end

  # ── §5's per-day limit ──────────────────────────────────────────────────────

  test "the daily limit refuses without creating a run or spending a call" do
    (SuggestionRun::DAILY_LIMIT - SuggestionRun.today.count).times { SuggestionRun.create! }

    assert_no_difference -> { SuggestionRun.count } do
      assert_no_enqueued_jobs only: SuggestRecipesJob do
        post suggestion_runs_path, params: { suggestion_run: { prompt_notes: "" } }, as: :turbo_stream
      end
    end

    assert_response :too_many_requests
    assert_select "turbo-stream[action=replace][target=new_suggestion_run]", /daily cap/
  end

  test "a refused request hands the note back rather than losing it" do
    (SuggestionRun::DAILY_LIMIT - SuggestionRun.today.count).times { SuggestionRun.create! }

    post suggestion_runs_path, params: { suggestion_run: { prompt_notes: "no dairy" } }, as: :turbo_stream

    assert_select "turbo-stream[action=replace][target=new_suggestion_run]" do
      assert_select "input[value=?]", "no dairy"
    end
  end

  # ── §4.2 step 4's retry ─────────────────────────────────────────────────────

  test "a retry starts a new run carrying the note and archives the one it replaces" do
    failed = SuggestionRun.create!(prompt_notes: "no dairy")
    failed.fail!("The search took too long. Try again?")

    assert_difference -> { SuggestionRun.count }, 1 do
      post suggestion_runs_path,
           params: { suggestion_run: { prompt_notes: failed.prompt_notes }, retry_of: failed.id },
           as: :turbo_stream
    end

    assert_predicate failed.reload, :archived?
    assert_predicate failed, :failed?   # archived, not rewound — the record still says what happened

    retried = SuggestionRun.order(:id).last
    assert_predicate retried, :queued?
    assert_equal "no dairy", retried.prompt_notes
  end

  test "a retry of a run that is already gone still starts one" do
    assert_difference -> { SuggestionRun.count }, 1 do
      post suggestion_runs_path, params: { suggestion_run: { prompt_notes: "" }, retry_of: "0" },
           as: :turbo_stream
    end

    assert_response :success
  end

  # ── history (§5) ────────────────────────────────────────────────────────────

  test "history lists every run, archived ones included" do
    get suggestion_runs_path

    assert_response :success
    assert_select "div##{dom_id(suggestion_runs(:history))}", /Archived/
    assert_select "div##{dom_id(suggestion_runs(:beef_night))}"
  end

  test "history shows the cards a thumbs-down hides from the active view" do
    blocked = recipe_suggestions(:history_tuna_casserole)

    get suggestion_runs_path

    assert_select "div##{dom_id(blocked)}", /Not for you/
  end

  test "history offers no retry and no cooking" do
    suggestion_runs(:pending).fail!("nope")

    get suggestion_runs_path

    assert_select "button", text: "Try again", count: 0
    assert_select "a", text: "I made this", count: 0

    # …and the same page on the inventory screen does offer both, so the assertions
    # above are about the history flag rather than about markup that never renders.
    get root_path

    assert_select "button", text: "Try again", count: 1
    assert_select "a", text: "I made this", minimum: 1
  end
end
