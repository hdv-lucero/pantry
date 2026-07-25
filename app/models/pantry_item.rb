class PantryItem < ApplicationRecord
  # §4.1 — items expiring within this window get a badge and the "use soon" section.
  EXPIRING_SOON_WINDOW = 3.days

  # §4.1 — one page-refresh stream for the whole inventory rather than the
  # per-record default `broadcasts_refreshes` sets up. The inventory index is the
  # only screen these records appear on, so a second tab needs exactly one
  # subscription, and creates reach it too. The acting tab is filtered out by
  # request id, which is why the controller still answers with a Turbo Stream.
  INVENTORY_STREAM = "pantry_items"

  broadcasts_refreshes_to ->(_item) { INVENTORY_STREAM }

  # §5 — stock going away is the only thing that can make a suggestion run stale,
  # so the coverage check hangs off exactly the two events the doc names: an item
  # deleted, or a quantity that hits zero. Adding stock or raising a quantity can
  # only raise coverage, so neither bothers to look.
  #
  # One registration rather than an `after_update_commit` and an
  # `after_destroy_commit`: same-name commit callbacks deduplicate, so a pair would
  # silently keep only the second.
  after_commit :archive_stale_suggestion_runs, on: %i[ update destroy ], if: :stock_left_the_pantry?

  enum :location, { pantry: 0, fridge: 1, freezer: 2 }
  enum :category, { produce: 0, dairy: 1, protein: 2, grains: 3, condiments: 4, other: 5 }

  # §3 — no ingredients master table; free-text names plus light normalization is
  # the right amount of engineering, and it keeps the LLM prompt trivially
  # constructible. Units get the same treatment minus singularizing, so "pcs"
  # survives and the quick-add datalist stays tidy.
  normalizes :name, with: ->(name) { name.squish.downcase.singularize }
  normalizes :unit, with: ->(unit) { unit.squish.downcase.presence }

  validates :name, presence: true
  validates :quantity, numericality: { greater_than_or_equal_to: 0 }

  scope :ordered, -> { order(:name) }
  scope :expiring_soon, -> {
    where(expires_on: ..EXPIRING_SOON_WINDOW.from_now.to_date).order(:expires_on, :name)
  }
  # §5 — a zero-quantity row is still a row you keep (you'll buy more milk), but
  # it is not something a recipe can be made with.
  scope :in_stock, -> { where("quantity > 0") }

  # The vocabulary suggestion coverage is measured against (§5). Distinct, because
  # two rows of the same thing in different locations are one available ingredient.
  def self.in_stock_names
    in_stock.distinct.pluck(:name)
  end

  # Feeds the quick-add <datalist> (§4.1) — free-text units stay free text, but
  # the ones already in use are one keystroke away.
  def self.units_in_use
    where.not(unit: nil).distinct.order(:unit).pluck(:unit)
  end

  # Every location key is always present, in enum order, so the inventory screen
  # can render its three Turbo Frames without checking for gaps.
  def self.grouped_by_location
    grouped = ordered.group_by(&:location)
    locations.keys.index_with { |location| grouped.fetch(location, []) }
  end

  def expiring_soon?
    expires_on.present? && expires_on <= EXPIRING_SOON_WINDOW.from_now.to_date
  end

  def in_stock?
    quantity.present? && quantity.positive?
  end

  private
    def stock_left_the_pantry?
      destroyed? || (saved_change_to_quantity? && !in_stock?)
    end

    def archive_stale_suggestion_runs
      SuggestionRun.archive_stale!
    end
end
