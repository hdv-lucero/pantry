class Recipe < ApplicationRecord
  has_many :recipe_suggestions, dependent: :destroy
  has_many :suggestion_runs, through: :recipe_suggestions

  # §3 — the normalized source URL *is* the recipe's identity. Running it through
  # `normalizes` rather than a before_save means finder conditions are normalized
  # too, so `find_or_create_by(source_url: whatever_the_model_returned)` lands on
  # the existing row without the caller having to normalize first.
  normalizes :source_url, with: ->(url) { normalize_url(url) }

  validates :source_url, presence: true, uniqueness: true

  # §5 — the two lists fed into every prompt, each the one-line query the doc
  # promises. Only an explicit tap sets `make_again`, so a recipe with no verdict
  # is in neither list.
  scope :favorites, -> { where(make_again: true) }
  scope :blocked, -> { where(make_again: false) }

  # Strips query and fragment so tracking-parameter variants of one page don't
  # split identity (§3). Host is case-insensitive so it gets downcased; the path
  # is not, so it doesn't. A trailing slash is dropped as the same page.
  #
  # Anything that isn't an http(s) URL with a host normalizes to nil, which the
  # presence validation then rejects — the fuller URL sanity checks §5 asks for
  # happen at parse time, before a Recipe is ever built.
  def self.normalize_url(url)
    uri = URI.parse(url.to_s.strip)
    return nil unless uri.is_a?(URI::HTTP) && uri.host.present?

    uri.query = nil
    uri.fragment = nil
    uri.host = uri.host.downcase
    uri.path = uri.path.chomp("/")
    uri.to_s
  rescue URI::InvalidURIError
    nil
  end

  # §5 — parsing upserts every returned result, so a recipe that recurs across runs
  # keeps one row, one id, and one verdict. Not `ActiveRecord.upsert`: the doc's
  # upsert path is `find_or_create_by` on the normalized URL, which lets the
  # normalization above do the matching.
  #
  # The block runs on create only. `canonical_title` and `source_name` are what the
  # first run to see the recipe called it; a later run's phrasing is per-run
  # presentation and belongs on its RecipeSuggestion (§3).
  def self.upsert_by_source_url(source_url, canonical_title: nil, source_name: nil)
    find_or_create_by!(source_url: source_url) do |recipe|
      recipe.canonical_title = canonical_title
      recipe.source_name = source_name
    end
  end

  # §4.3 — the verdict is tri-state: true, false, or never asked.
  def favorite?
    make_again == true
  end

  def blocked?
    make_again == false
  end
end
