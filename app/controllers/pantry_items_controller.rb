class PantryItemsController < ApplicationController
  before_action :set_pantry_item, only: %i[ edit update destroy ]

  helper_method :expiring_soon, :units_in_use

  # §4.1's inventory and §4.2's suggestions share this screen — see
  # `suggestion_runs/_suggestions` for why they are not two.
  def index
    @grouped_items = PantryItem.grouped_by_location
    @suggestion_runs = SuggestionRun.on_screen
  end

  def create
    @pantry_item = PantryItem.new(new_item_attributes)

    if @pantry_item.save
      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to pantry_items_path }
      end
    else
      render_quick_add_errors
    end
  end

  def edit
  end

  def update
    if @pantry_item.update(pantry_item_params)
      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to pantry_items_path }
      end
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    @pantry_item.destroy!

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to pantry_items_path, status: :see_other }
    end
  end

  private
    def set_pantry_item
      @pantry_item = PantryItem.find(params[:id])
    end

    def pantry_item_params
      params.expect(pantry_item: [ :name, :quantity, :unit, :location, :category, :expires_on ])
    end

    # §4.1 — the quick-add text input is parsed first, then the form's explicit
    # fallback fields win wherever the user filled one in. Merging this way (rather
    # than assigning in sequence) keeps the outcome independent of parameter order.
    def new_item_attributes
      attributes = params.expect(pantry_item: [ :quick_add, :name, :quantity, :unit, :location, :category, :expires_on ])
      parsed = PantryItem::QuickAdd.new(attributes[:quick_add]).to_h

      parsed.merge(attributes.except(:quick_add).to_h.compact_blank.symbolize_keys)
    end

    # A failed quick add swaps just that group's form back in carrying its errors;
    # the other two groups and every existing row are left untouched.
    def render_quick_add_errors
      render turbo_stream: turbo_stream.replace(
        helpers.quick_add_id(@pantry_item.location),
        partial: "pantry_items/quick_add",
        locals: { pantry_item: @pantry_item }
      ), status: :unprocessable_content
    end

    def expiring_soon
      @expiring_soon ||= PantryItem.expiring_soon
    end

    def units_in_use
      @units_in_use ||= PantryItem.units_in_use
    end
end
