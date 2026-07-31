# §4.3 — the thumbs. "Because the verdict lives on the recipe rather than the
# suggestion row, re-asking on a resurfaced favorite is safe by construction:
# there's no duplicate opinion to create, the tap simply updates the one verdict in
# place, and latest wins."
#
# Skipping is not a request. The doc says skipping "leaves the verdict untouched",
# and the honest way to leave something untouched is to send nothing — so the modal's
# Skip button closes the dialog client-side and no action here answers for it.
class VerdictsController < ApplicationController
  def update
    @recipe = Recipe.find(params[:recipe_id])
    @recipe.update!(make_again: make_again)

    respond_to do |format|
      # A verdict re-renders the whole active list rather than one card: a favorite
      # puts a ★ on every run that includes the recipe (§4.3) and a thumbs-down takes
      # its card out of all of them, and "which runs" is exactly the query the list
      # already is.
      format.turbo_stream { @suggestion_runs = SuggestionRun.on_screen }
      format.html { redirect_to root_path }
    end
  end

  private
    def make_again
      ActiveModel::Type::Boolean.new.cast(params.require(:make_again)).present?
    end
end
