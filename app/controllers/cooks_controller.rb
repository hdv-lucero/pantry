# §4.3 — "Each suggestion card has an 'I made this' button — the event that ties the
# whole system together." :new is the modal, :create is the confirmation.
class CooksController < ApplicationController
  before_action :set_recipe_suggestion

  # Rendered into the layout's modal frame. turbo-rails swaps in its own minimal
  # layout for a frame request, so the placeholder frame in the application layout
  # is not in this response to collide with the one below.
  def new
    @cook = RecipeSuggestion::Cook.new(@recipe_suggestion)
  end

  def create
    @cook = RecipeSuggestion::Cook.new(@recipe_suggestion, deduction_params).apply!

    respond_to do |format|
      format.turbo_stream { @suggestion_runs = SuggestionRun.on_screen }
      format.html { redirect_to root_path }
    end
  end

  private
    def set_recipe_suggestion
      @recipe_suggestion = RecipeSuggestion.find(params[:recipe_suggestion_id])
    end

    # `{ "<pantry_item_id>" => { apply:, amount: } }` — the ids are data, so the
    # permitted shape can only be "a nested hash". Nothing downstream trusts it:
    # RecipeSuggestion::Cook builds its lines from the pantry and looks these up by
    # id, so a key that is not one of this suggestion's in-stock items is ignored,
    # and the values are cast and clamped rather than assigned.
    def deduction_params
      params.permit(deductions: {}).to_h[:deductions]
    end
end
