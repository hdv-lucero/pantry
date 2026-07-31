module SuggestionRunsHelper
  # Stable Turbo Stream targets, the same way PantryItemsHelper names the
  # inventory's. The list id is deliberately *not* SuggestionRun::BROADCAST_STREAM
  # — that string names a cable stream, this one names a div, and letting them
  # collide would make "suggestion_runs" mean two things a reader has to tell apart.
  def suggestion_runs_list_id
    "suggestion_runs_list"
  end

  def new_suggestion_run_id
    "new_suggestion_run"
  end

  # §4.3 — the modal frame lives in the layout, so every "I made this" link on
  # every card targets the same one.
  def modal_frame_id
    "modal"
  end

  def run_timestamp(suggestion_run)
    "#{time_ago_in_words(suggestion_run.created_at)} ago"
  end
end
