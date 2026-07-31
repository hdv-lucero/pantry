# §4.2 step 1 — "Controller creates a `SuggestionRun` (status `queued`), enqueues
# `SuggestRecipesJob`, and responds with a Turbo Stream that renders the run's card
# in a `pending` state with a spinner."
class SuggestionRunsController < ApplicationController
  # §5 — "runs are never deleted", so history is every run there has ever been,
  # newest first, archived or not. Not just the archived ones: a thumbs-downed card
  # is taken out of the active view while its run is still active (§4.3), and
  # "remains browsable in history" has to mean somewhere it can actually be found.
  def index
    @suggestion_runs = SuggestionRun.recent.preload(recipe_suggestions: :recipe)
  end

  def create
    # §5 cost control — "a per-day run limit enforced in the controller". This is the
    # only place that can refuse in a way a person sees; SuggestRecipesJob checks the
    # same allowance again before spending on a run that got past here.
    return render_daily_limit_reached if SuggestionRun.daily_limit_reached?

    @suggestion_run = SuggestionRun.create!(prompt_notes: prompt_notes)

    # A retry (§4.2 step 4) is a new run rather than a rewind of the failed one, so
    # it spends from the daily allowance the way every other run does — re-queueing
    # in place would count nothing and make the cap free to walk around. The run it
    # replaces is archived, not deleted: it stays in history as the record of what
    # went wrong, and stops taking up room on a screen it can no longer answer.
    superseded_run&.archive!

    SuggestRecipesJob.perform_later(@suggestion_run)

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to root_path }
    end
  end

  private
    def prompt_notes
      params.expect(suggestion_run: [ :prompt_notes ])[:prompt_notes].presence
    end

    def superseded_run
      SuggestionRun.active.find_by(id: params[:retry_of])
    end

    # Mirrors the quick-add error path (§4.1): swap the form back in carrying the
    # refusal, and leave everything else on the screen alone.
    def render_daily_limit_reached
      render turbo_stream: turbo_stream.replace(
        helpers.new_suggestion_run_id,
        partial: "suggestion_runs/new_run",
        locals: { prompt_notes: prompt_notes,
                  error: "That's #{SuggestionRun::DAILY_LIMIT} suggestion runs today — the daily cap. Try again tomorrow." }
      ), status: :too_many_requests
    end
end
