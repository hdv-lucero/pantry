class RecipeSuggestion < ApplicationRecord
  belongs_to :suggestion_run
  belongs_to :recipe

  # §3 — JSON-in-text, always a list. `type: Array` makes a wrong shape fail on
  # save here rather than confuse the coverage math a week later.
  serialize :uses_items, coder: JSON, type: Array
  serialize :missing_items, coder: JSON, type: Array
  serialize :substitutions, coder: JSON, type: Array

  validates :title, presence: true

  # §4.2 — cards are ordered by the position the job assigned them (fewest missing
  # items first); ties fall back to insertion order.
  scope :ordered, -> { order(:position, :id) }
  scope :cooked, -> { where.not(cooked_at: nil) }

  def cooked?
    cooked_at.present?
  end
end
